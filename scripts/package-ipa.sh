#!/usr/bin/env bash
# Package an unsigned .xcarchive into an .ipa for re-signing (e.g. with Signulous).
#
# Usage: scripts/package-ipa.sh <path/to/Aigo.xcarchive> <path/to/Aigo-unsigned.ipa>
#
# Produces <out.ipa> and <out.ipa>.sha256. macOS only (uses PlistBuddy, lipo, ditto).
# Written for the stock macOS /bin/bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

APP_NAME="${APP_NAME:-Aigo}"
WIDGET_NAME="${WIDGET_NAME:-AigoWidgets}"
PLISTBUDDY=/usr/libexec/PlistBuddy

die() { echo "error: $*" >&2; exit 1; }

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <xcarchive> <out.ipa>" >&2
  exit 2
fi

ARCHIVE="$1"
OUT="$2"

[ -x "$PLISTBUDDY" ] || die "PlistBuddy not found; this script must run on macOS"
[ -d "$ARCHIVE" ] || die "archive not found: $ARCHIVE"

plist_get() { "$PLISTBUDDY" -c "Print :$1" "$2" 2>/dev/null || true; }

app="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [ ! -d "$app" ]; then
  echo "Archive contents:" >&2
  find "$ARCHIVE" -maxdepth 4 >&2 || true
  die "$APP_NAME.app not found under $ARCHIVE/Products/Applications (is SKIP_INSTALL=NO set on the app target?)"
fi

appex="$app/PlugIns/$WIDGET_NAME.appex"
[ -d "$appex" ] || die "widget extension missing: expected $appex (is $WIDGET_NAME embedded in $APP_NAME?)"

# Check that a bundle's main executable exists and contains arm64.
check_exec() {
  local bundle="$1" exe_name exe archs
  exe_name="$(plist_get CFBundleExecutable "$bundle/Info.plist")"
  [ -n "$exe_name" ] || die "CFBundleExecutable missing in $bundle/Info.plist"
  exe="$bundle/$exe_name"
  [ -f "$exe" ] || die "executable not found: $exe"
  file "$exe"
  archs="$(lipo -archs "$exe" 2>/dev/null || lipo -info "$exe")"
  case "$archs" in
    *arm64*) echo "  architectures: $archs" ;;
    *) die "$exe is not an arm64 executable (got: $archs)" ;;
  esac
}

print_info() {
  local label="$1" plist="$2"
  echo "$label"
  echo "  CFBundleIdentifier:         $(plist_get CFBundleIdentifier "$plist")"
  echo "  CFBundleShortVersionString: $(plist_get CFBundleShortVersionString "$plist")"
  echo "  CFBundleVersion:            $(plist_get CFBundleVersion "$plist")"
  echo "  MinimumOSVersion:           $(plist_get MinimumOSVersion "$plist")"
}

echo "== App"
print_info "$APP_NAME.app" "$app/Info.plist"
check_exec "$app"
echo "== Widget extension"
print_info "$WIDGET_NAME.appex" "$appex/Info.plist"
check_exec "$appex"

# Resolve the output path to an absolute one before changing directories.
out_dir="$(dirname "$OUT")"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
out_name="$(basename "$OUT")"
out_abs="$out_dir/$out_name"
rm -f "$out_abs" "$out_abs.sha256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Payload"
ditto "$app" "$work/Payload/$APP_NAME.app"
find "$work/Payload" -name '.DS_Store' -delete

# zip -y keeps symlinks as symlinks (frameworks rely on them); unix modes are kept,
# so the executables stay executable after re-signing.
(cd "$work" && zip -qry "$out_abs" Payload)
unzip -tq "$out_abs" >/dev/null || die "zip integrity check failed for $out_abs"

(cd "$out_dir" && shasum -a 256 "$out_name" > "$out_name.sha256")

echo "== Output"
ls -l "$out_abs"
cat "$out_abs.sha256"
