# GCR: Gitara Community Repository

The official plugin repository for [Gitara](https://github.com/hastagaming/Gitara). Plugins extend Gitara's workflows with reusable actions, workflow templates and one-tap commands that run in the Gitara Box.

Gitara downloads the built plugins from the `dist` branch of this repository. You can add other plugin repositories in Gitara and pick which one is the default.

## Plugin layout

Every plugin is a folder under `plugins/`. The folder name is the plugin id: lowercase letters, digits and dashes, at most 48 characters.

```
plugins/my-plugin/
├── assets/            optional  images, only .png .svg .xml
├── main/              required  the plugin itself, only .yml .yaml
├── including/         optional  required when you depend on other plugins
├── VERSION            required
├── VERSION_SUPPORT    required
├── LICENSE            required
├── README.md          required  shown in Gitara when a user opens the plugin
└── build.sh           required  run by GCR's Actions, see below
```

| Folder | Required | Allowed files |
| --- | --- | --- |
| `assets/` | no | `.png`, `.svg`, `.xml` only |
| `main/` | yes | `.yml`, `.yaml` only |
| `including/` | only when you depend on other plugins | `.yml` only |

The plugin root may contain nothing else. Symbolic links are not allowed. File names may use letters, digits, `.`, `_` and `-`. A file is at most 1 MB and a plugin at most 10 MB.

### `VERSION`

One line with the plugin version, for example `1.2.0` or `1.3.0-rc.1`.

### `VERSION_SUPPORT`

The Gitara versions this plugin supports, and only those. Use exactly this format:

```
Gitara version [
   - v1.0.0
]
```

That is only an example. List the Gitara versions you actually tested, one per line, starting with `v`. A plugin whose list does not contain the installed Gitara version stays inactive until it is updated. Nothing is assumed by default.

### `LICENSE` and `README.md`

`LICENSE` holds your license text. `README.md` is shown to the user when they open your plugin in Gitara, so describe what it does and how to use it. The first `# Heading` becomes the plugin's display name.

### `including/<plugin-id>.yml`

One file per dependency, named after the plugin you need:

```yaml
version: 1.2.0
repo: https://github.com/someone/their-repo
```

Both keys are optional. `version` is the minimum version. Without `repo` the dependency must be in this repository. Gitara installs dependencies first.

### `main/`

```
main/
├── actions/<name>/action.yml     composite actions, used as  uses: plugin:<plugin-id>/<name>
├── templates/<file>.yml          workflow templates shown in Gitara's "New workflow" list
└── commands/<id>.yml             one-tap commands that run in the Gitara Box
```

A command file:

```yaml
name: Install JDK 17
description: Installs OpenJDK 17 with apk
shell: sh
timeout-minutes: 30
run: |
  apk add --no-cache openjdk17
  java -version
```

An action file follows the same format as repository actions in Gitara (`inputs`, `outputs`, `runs.using: composite`).

Plugin actions and commands cannot read `${{ secrets.* }}`. A user has to pass a secret explicitly with `with:`.

### `build.sh`

Run by this repository's Actions after a merge. It runs in the plugin folder with a clean environment and must write the final plugin tree to `$GCR_OUT`. The variables `GCR_PLUGIN_ID`, `GCR_PLUGIN_VERSION` and `GCR_OUT` are set. It must work offline. The standard script is:

```sh
#!/bin/sh
set -eu
cp -R main "$GCR_OUT/main"
if [ -d assets ]; then cp -R assets "$GCR_OUT/assets"; fi
if [ -d including ]; then cp -R including "$GCR_OUT/including"; fi
exit 0
```

`VERSION`, `VERSION_SUPPORT`, `LICENSE` and `README.md` are copied from your folder after the build, so a build script cannot change them. The build output is checked again with the same rules before it is published.

## Contributing a plugin

1. Fork this repository.
2. Create `plugins/<your-plugin>/` with the layout above.
3. Check it locally: `bash build-plugins.sh check <your-plugin>`. It needs GNU bash, grep and find (in the Gitara Box: `apk add bash grep findutils coreutils`).
4. Test it in Gitara: clone your fork in Gitara, open it, then **Actions → Plugins → Installed → Test a plugin from this repository**.
5. Open a pull request. Automated checks run first and show the reason in the check output when something is rejected.
6. A maintainer reviews the plugin. When it is accepted and merged it joins the official GCR and appears for everyone after the next build.

### Rejection reasons

| Reason | Meaning |
| --- | --- |
| `system injection gitara box` | Tries to attack, escape or tamper with the Gitara Box or the app (proot, `LD_PRELOAD`, `/proc/*/mem`, `/data/data`, chroot, mount, and similar) |
| `remote code execution` | Downloads and runs code (`curl ... \| sh`, `base64 -d \| sh`, `eval`) |
| `secret access attempt` | References `${{ secrets.* }}` |
| `network access in build script` | `build.sh` uses the network or installs packages |
| `obfuscated content` | Long encoded blobs |
| `unsafe image` / `invalid image` | An SVG or XML with scripts, event handlers, external links or entities, or a PNG that is not a real PNG |
| `forbidden file type` / `forbidden file name` | A file type or name outside the allowed list |
| `missing required file` / `missing required folder` | Part of the layout is missing |
| `unexpected file or folder` | Something that is not part of the layout |
| `invalid version` / `invalid version support` | `VERSION` or `VERSION_SUPPORT` is malformed |
| `invalid dependency` / `missing dependency` | A broken file in `including/` or a dependency that does not exist |
| `symbolic link` | Symbolic links are not allowed |
| `plugin too large` / `file too large` | Over the size limits |
| `build failed` | `build.sh` failed or produced no `main/` |

The automated checks catch common problems. They are not a security guarantee, which is why every plugin is also reviewed by a person.

## Becoming an official repository

Anyone can publish their own plugin repository with the same layout and add it in Gitara. Repositories listed in the official block of Gitara's README are shown as **Official** in the app. To request that, open a pull request on Gitara's README.
