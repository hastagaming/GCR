#!/usr/bin/env bash
# GCR (Gitara Community Repository) plugin checker and builder.
#
#   ./build-plugins.sh check [plugin ...]   static validation, never runs plugin code
#   ./build-plugins.sh build [plugin ...]   validate, run every build.sh, write dist/<plugin>
#   ./build-plugins.sh verify-dist          validate an existing dist/ tree
#
# Environment: GCR_PLUGINS_DIR (default ./plugins), GCR_DIST_DIR (default ./dist)
# Needs GNU bash, grep, find, stat and timeout (any Ubuntu runner has them).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${GCR_PLUGINS_DIR:-$ROOT/plugins}"
DIST_DIR="${GCR_DIST_DIR:-$ROOT/dist}"

ID_PATTERN='^[a-z0-9][a-z0-9-]{0,47}$'
VERSION_PATTERN='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
SUPPORT_ITEM_PATTERN='^-[[:space:]]+(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$'
REPO_PATTERN='^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'
MAX_FILE_BYTES=1048576
MAX_TOTAL_BYTES=10485760

SYSTEM_PATTERN='(proot|libproot|LD_PRELOAD|LD_LIBRARY_PATH|ptrace|/proc/[^[:space:]]*/(mem|maps|environ)|/proc/self/exe|/data/(data|user|app)/|nativeLibraryDir|chroot|nsenter|unshare|/dev/(mem|kmem|block)|magisk|/system/bin/(su|am|pm|cmd)\b|\bsu[[:space:]]+-c\b|\bpm[[:space:]]+install\b|\bam[[:space:]]+start\b|\bmount[[:space:]])'
RCE_PATTERN='((curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|a|z|da)?sh\b|(curl|wget)[^|]*\|[[:space:]]*(python3?|node|perl|ruby)\b|base64[[:space:]]+(-d|--decode)[^|]*\|[[:space:]]*(ba|a|z)?sh\b|\beval[[:space:]]|sh[[:space:]]+-c[[:space:]]+"?\$\((curl|wget))'
SECRET_PATTERN='\$\{\{[[:space:]]*secrets[.[]'
BUILD_NET_PATTERN='(\b(curl|wget|nc|ncat|netcat|ssh|scp|sftp|ftp|telnet)\b|git[[:space:]]+(clone|fetch|pull|push)|\b(pip3?|npm|yarn|apk|apt|apt-get|gem|cargo)[[:space:]]+(install|add)\b)'
OBFUSCATION_PATTERN='[A-Za-z0-9+/=]{200,}'
SVG_PATTERN='(<script|<foreignObject|<iframe|<embed|<object|javascript:|\bon(load|error|click|mouse[a-z]*|focus[a-z]*|begin|end|repeat|abort|activate)[[:space:]]*=|<!ENTITY|<!DOCTYPE[^>]*\[|href[[:space:]]*=[[:space:]]*["'"'"']?(https?:|//|data:|file:))'

FAILED=0
REASON_LIST="|"

reject() { # reject <plugin> <reason> <detail>
  local plugin="$1" reason="$2" detail="${3//$'\n'/ }"
  FAILED=$((FAILED + 1))
  if [[ "$REASON_LIST" != *"|$reason|"* ]]; then REASON_LIST="${REASON_LIST}${reason}|"; fi
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::error title=REJECTED: ${reason}::${plugin}: ${detail}"
  else
    echo "REJECTED [${reason}] ${plugin}: ${detail}"
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

scan() { # scan <plugin> <file> <label> <reason> <regex>
  if grep -Eqi -- "$5" "$2" 2>/dev/null; then
    reject "$1" "$4" "$3 matches a blocked pattern"
  fi
}

check_version() { # <tree> <plugin>
  local file="$1/VERSION" value
  [[ -s "$file" ]] || return 0
  if [[ "$(wc -l < "$file")" -gt 1 ]]; then
    reject "$2" "invalid version" "VERSION must contain a single line"
    return 0
  fi
  value="$(tr -d '\r\n[:space:]' < "$file")"
  [[ "$value" =~ $VERSION_PATTERN ]] || reject "$2" "invalid version" "VERSION must look like 1.2.3 or 1.2.3-rc.1"
}

check_version_support() { # <tree> <plugin>
  local file="$1/VERSION_SUPPORT" id="$2" state=0 count=0 line trimmed
  [[ -s "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(trim "${line%$'\r'}")"
    [[ -z "$trimmed" ]] && continue
    case "$state" in
      0)
        if [[ "$trimmed" == "Gitara version [" ]]; then
          state=1
        else
          reject "$id" "invalid version support" "VERSION_SUPPORT must start with: Gitara version ["
          return 0
        fi
        ;;
      1)
        if [[ "$trimmed" == "]" ]]; then
          state=2
        elif [[ "$trimmed" =~ $SUPPORT_ITEM_PATTERN ]]; then
          count=$((count + 1))
        else
          reject "$id" "invalid version support" "unexpected line in VERSION_SUPPORT: $trimmed"
          return 0
        fi
        ;;
      2)
        reject "$id" "invalid version support" "nothing may follow the closing ] in VERSION_SUPPORT"
        return 0
        ;;
    esac
  done < "$file"
  if (( state != 2 )); then
    reject "$id" "invalid version support" "VERSION_SUPPORT is missing the closing ]"
  elif (( count == 0 )); then
    reject "$id" "invalid version support" "VERSION_SUPPORT must list at least one Gitara version"
  fi
}

check_including() { # <tree> <plugin> <check-existence: 1|0>
  local tree="$1" id="$2" exists="$3" file name dep line value has_repo
  [[ -d "$tree/including" ]] || return 0
  for file in "$tree"/including/*; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file")"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,47}\.yml$ ]]; then
      reject "$id" "invalid dependency" "including/$name must be named <plugin>.yml"
      continue
    fi
    dep="${name%.yml}"
    if [[ "$dep" == "$id" ]]; then
      reject "$id" "invalid dependency" "a plugin cannot depend on itself"
      continue
    fi
    has_repo=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="$(trim "${line%$'\r'}")"
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" =~ ^version:[[:space:]]*(.+)$ ]]; then
        value="$(trim "${BASH_REMATCH[1]}")"
        [[ "$value" =~ $VERSION_PATTERN ]] || reject "$id" "invalid dependency" "including/$name has an invalid version"
      elif [[ "$line" =~ ^repo:[[:space:]]*(.+)$ ]]; then
        has_repo=1
        value="$(trim "${BASH_REMATCH[1]}")"
        [[ "$value" =~ $REPO_PATTERN ]] || reject "$id" "invalid dependency" "including/$name needs an https:// repo"
      else
        reject "$id" "invalid dependency" "including/$name allows only 'version:' and 'repo:' lines"
      fi
    done < "$file"
    if [[ "$exists" == "1" && $has_repo -eq 0 && ! -d "$PLUGINS_DIR/$dep" ]]; then
      reject "$id" "missing dependency" "$dep is not in this repository and no repo: was given"
    fi
  done
}

check_files() { # <tree> <plugin>
  local tree="$1" id="$2" file rel ext size total=0 magic
  while IFS= read -r -d '' file; do
    rel="${file#"$tree"/}"
    if [[ ! "$rel" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      reject "$id" "forbidden file name" "$rel uses characters other than letters, digits and . _ - /"
      continue
    fi
    size="$(stat -c %s "$file")"
    total=$((total + size))
    if (( size > MAX_FILE_BYTES )); then
      reject "$id" "file too large" "$rel is larger than 1 MB"
    fi
    if [[ "$rel" != *.* ]]; then
      reject "$id" "forbidden file type" "$rel has no file extension"
      continue
    fi
    ext="${rel##*.}"
    ext="${ext,,}"
    case "$rel" in
      assets/*)
        case "$ext" in
          png)
            magic="$(head -c 8 "$file" | od -An -tx1 | tr -d ' \n')"
            [[ "$magic" == "89504e470d0a1a0a" ]] || reject "$id" "invalid image" "$rel is not a real PNG file"
            ;;
          svg|xml)
            scan "$id" "$file" "$rel" "unsafe image" "$SVG_PATTERN"
            scan "$id" "$file" "$rel" "obfuscated content" "$OBFUSCATION_PATTERN"
            ;;
          *) reject "$id" "forbidden file type" "$rel (assets may only contain xml, svg and png)" ;;
        esac
        ;;
      main/*)
        [[ "$ext" == "yml" || "$ext" == "yaml" ]] || reject "$id" "forbidden file type" "$rel (main may only contain yml and yaml)"
        ;;
      including/*)
        [[ "$ext" == "yml" ]] || reject "$id" "forbidden file type" "$rel (including may only contain yml)"
        ;;
    esac
  done < <(find "$tree/assets" "$tree/main" "$tree/including" -type f -print0 2>/dev/null)
  if (( total > MAX_TOTAL_BYTES )); then
    reject "$id" "plugin too large" "the plugin is larger than 10 MB"
  fi
}

check_content() { # <tree> <plugin> <scan-build-sh: 1|0>
  local tree="$1" id="$2" with_build="$3" file rel
  while IFS= read -r -d '' file; do
    rel="${file#"$tree"/}"
    scan "$id" "$file" "$rel" "system injection gitara box" "$SYSTEM_PATTERN"
    scan "$id" "$file" "$rel" "remote code execution" "$RCE_PATTERN"
    scan "$id" "$file" "$rel" "secret access attempt" "$SECRET_PATTERN"
    scan "$id" "$file" "$rel" "obfuscated content" "$OBFUSCATION_PATTERN"
  done < <(find "$tree/main" "$tree/including" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)
  if [[ "$with_build" == "1" && -f "$tree/build.sh" ]]; then
    scan "$id" "$tree/build.sh" "build.sh" "system injection gitara box" "$SYSTEM_PATTERN"
    scan "$id" "$tree/build.sh" "build.sh" "remote code execution" "$RCE_PATTERN"
    scan "$id" "$tree/build.sh" "build.sh" "network access in build script" "$BUILD_NET_PATTERN"
    scan "$id" "$tree/build.sh" "build.sh" "obfuscated content" "$OBFUSCATION_PATTERN"
  fi
}

check_links() { # <tree> <plugin>
  if [[ -n "$(find "$1" -type l -print -quit)" ]]; then
    reject "$2" "symbolic link" "symbolic links are not allowed"
  fi
}

check_source() { # <plugin>
  local id="$1" dir="$PLUGINS_DIR/$1" entry name f
  if [[ ! -d "$dir" ]]; then
    reject "$id" "missing required folder" "plugins/$id does not exist"
    return 0
  fi
  [[ "$id" =~ $ID_PATTERN ]] || reject "$id" "invalid plugin name" "use lowercase letters, digits and dashes (max 48 characters)"
  for f in VERSION VERSION_SUPPORT LICENSE README.md build.sh; do
    if [[ ! -f "$dir/$f" ]]; then
      reject "$id" "missing required file" "$f is required"
    elif [[ ! -s "$dir/$f" ]]; then
      reject "$id" "missing required file" "$f is empty"
    fi
  done
  if [[ ! -d "$dir/main" ]]; then
    reject "$id" "missing required folder" "main/ is required"
  elif [[ -z "$(find "$dir/main" -type f -print -quit)" ]]; then
    reject "$id" "missing required folder" "main/ must contain at least one file"
  fi
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    case "$name" in
      VERSION|VERSION_SUPPORT|LICENSE|README.md|build.sh|assets|main|including) ;;
      *) reject "$id" "unexpected file or folder" "$name is not part of the plugin layout" ;;
    esac
  done
  check_links "$dir" "$id"
  check_version "$dir" "$id"
  check_version_support "$dir" "$id"
  check_including "$dir" "$id" 1
  check_files "$dir" "$id"
  check_content "$dir" "$id" 1
}

check_output() { # <tree> <plugin>
  local tree="$1" id="$2" entry name f
  for f in VERSION VERSION_SUPPORT LICENSE README.md; do
    [[ -s "$tree/$f" ]] || reject "$id" "missing required file" "$f is missing from the build output"
  done
  if [[ ! -d "$tree/main" || -z "$(find "$tree/main" -type f -print -quit 2>/dev/null)" ]]; then
    reject "$id" "build failed" "the build output has no main/ content"
  fi
  for entry in "$tree"/* "$tree"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    case "$name" in
      VERSION|VERSION_SUPPORT|LICENSE|README.md|assets|main|including) ;;
      *) reject "$id" "unexpected file or folder" "$name must not be in the build output" ;;
    esac
  done
  check_links "$tree" "$id"
  check_version "$tree" "$id"
  check_version_support "$tree" "$id"
  check_including "$tree" "$id" 0
  check_files "$tree" "$id"
  check_content "$tree" "$id" 0
}

build_plugin() { # <plugin>
  local id="$1" dir="$PLUGINS_DIR/$1" out work version log
  work="$(mktemp -d)"
  out="$work/out"
  mkdir -p "$out" "$work/home" "$work/tmp"
  version="$(tr -d '\r\n[:space:]' < "$dir/VERSION")"
  version="${version#v}"
  log="$work/build.log"
  if ! (cd "$dir" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LANG=C.UTF-8 \
        GCR_PLUGIN_ID="$id" GCR_PLUGIN_VERSION="$version" GCR_OUT="$out" \
        timeout 120 bash ./build.sh > "$log" 2>&1); then
    reject "$id" "build failed" "build.sh exited with an error: $(tail -n 5 "$log" | tr '\n' ' ')"
    rm -rf "$work"
    return 0
  fi
  cp "$dir/VERSION" "$dir/VERSION_SUPPORT" "$dir/LICENSE" "$dir/README.md" "$out/"
  local before="$FAILED"
  check_output "$out" "$id"
  if (( FAILED == before )); then
    rm -rf "${DIST_DIR:?}/$id"
    mkdir -p "$DIST_DIR"
    chmod -R u+rwX,go+rX "$out"
    mv "$out" "$DIST_DIR/$id"
    echo "built $id $version"
  fi
  rm -rf "$work"
}

collect_plugins() {
  local entry name
  PLUGIN_IDS=()
  [[ -d "$PLUGINS_DIR" ]] || return 0
  for entry in "$PLUGINS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ -d "$entry" ]]; then
      PLUGIN_IDS+=("$name")
    elif [[ "$name" != "README.md" ]]; then
      reject "plugins" "unexpected file or folder" "$name must not be placed directly in plugins/"
    fi
  done
}

write_index() {
  local entry id
  mkdir -p "$DIST_DIR"
  : > "$DIST_DIR/INDEX.txt"
  for entry in "$DIST_DIR"/*/; do
    [[ -d "$entry" ]] || continue
    id="$(basename "$entry")"
    printf '%s %s\n' "$id" "$(tr -d '\r\n[:space:]' < "$entry/VERSION")" >> "$DIST_DIR/INDEX.txt"
  done
}

finish() {
  if (( FAILED > 0 )); then
    local reasons="${REASON_LIST#|}"
    reasons="${reasons%|}"
    echo
    echo "REJECTED: ${reasons//|/, }"
    exit 1
  fi
  echo "$1"
}

mode="${1:-}"
shift || true

case "$mode" in
  check|build)
    if [[ $# -gt 0 ]]; then
      plugins=("$@")
    else
      collect_plugins
      plugins=(${PLUGIN_IDS[@]+"${PLUGIN_IDS[@]}"})
    fi
    count=0
    for id in ${plugins[@]+"${plugins[@]}"}; do
      [[ -n "$id" ]] || continue
      count=$((count + 1))
      check_source "$id"
    done
    if [[ "$mode" == "build" && $FAILED -eq 0 ]]; then
      for id in ${plugins[@]+"${plugins[@]}"}; do
        [[ -n "$id" ]] || continue
        build_plugin "$id"
      done
      if (( FAILED == 0 )); then write_index; fi
    fi
    finish "OK: $count plugin(s) passed"
    ;;
  verify-dist)
    count=0
    if [[ -d "$DIST_DIR" ]]; then
      for entry in "$DIST_DIR"/*; do
        [[ -d "$entry" ]] || continue
        count=$((count + 1))
        check_output "$entry" "$(basename "$entry")"
      done
    fi
    finish "OK: $count built plugin(s) verified"
    ;;
  *)
    echo "usage: $0 check|build [plugin ...] | verify-dist" >&2
    exit 2
    ;;
esac