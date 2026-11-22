#!/bin/sh
# Xcode "Run Script" build phase (after "Compile Sources", Release): uploads this build's dSYMs
# to Watchtower with `wtctl debug-files upload`. Needs Build Settings
# DEBUG_INFORMATION_FORMAT = "DWARF with dSYM File" and ENABLE_USER_SCRIPT_SANDBOXING = NO.
#
#   Input Files:  ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}
#   Shell:        /bin/sh "${SRCROOT}/scripts/upload-dsyms.sh"
#
# Credentials come from the environment (a CI secret or an xcconfig that is not committed), never
# from this file: WT_API (API base URL), WT_API_KEY, WT_PROJECT (prj_...). Optional: WTCTL (path to
# wtctl, default `wtctl`), WT_RELEASE (default MARKETING_VERSION+CURRENT_PROJECT_VERSION).
# Outside Xcode: `scripts/upload-dsyms.sh path/to/App.app.dSYM`.
set -eu
if [ -z "${WT_API:-}" ] || [ -z "${WT_API_KEY:-}" ] || [ -z "${WT_PROJECT:-}" ]; then
  echo "warning: Watchtower: WT_API, WT_API_KEY and WT_PROJECT are not all set; dSYMs not uploaded" >&2
  exit 0 # a missing credential must not fail a developer build
fi
if [ "${CONFIGURATION:-Release}" = "Debug" ] && [ -z "${WT_UPLOAD_DEBUG:-}" ]; then exit 0; fi
release=${WT_RELEASE:-${MARKETING_VERSION:-0}+${CURRENT_PROJECT_VERSION:-0}}
src=${1:-${DWARF_DSYM_FOLDER_PATH:-.}/${DWARF_DSYM_FILE_NAME:-}}
[ -d "$src" ] || { echo "warning: Watchtower: no dSYM at $src" >&2; exit 0; }

# wtctl takes thin Mach-O files: split any universal binary per architecture first.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
find "$src" -path '*/Contents/Resources/DWARF/*' -type f | while read -r f; do
  archs=$(lipo -archs "$f" 2>/dev/null || echo "")
  case "$archs" in
    *" "*) for a in $archs; do mkdir -p "$tmp/$a"; lipo -thin "$a" "$f" -output "$tmp/$a/$(basename "$f")"; done ;;
    *) mkdir -p "$tmp/single"; cp "$f" "$tmp/single/$(basename "$f")" ;;
  esac
done
${WTCTL:-wtctl} debug-files upload "$tmp" --api "$WT_API" --key "$WT_API_KEY" --project "$WT_PROJECT" --release "$release"
