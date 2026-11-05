#!/usr/bin/env bash
# Sanity-check an unsigned Aigo IPA before it is published.
#
# Usage: scripts/verify-ipa.sh <Aigo-unsigned.ipa>
#
# Checks bundle ids, Live Activity support, the "aigo" URL scheme, the WidgetKit
# extension point and arm64 executables. Exits non-zero if any check fails.
# macOS only (uses PlistBuddy and lipo). Written for /bin/bash 3.2.
set -euo pipefail

APP_NAME="${APP_NAME:-Aigo}"
WIDGET_NAME="${WIDGET_NAME:-AigoWidgets}"
APP_ID="${APP_ID:-dev.aigo.app}"
WIDGET_ID="${WIDGET_ID:-dev.aigo.app.widgets}"
URL_SCHEME="${URL_SCHEME:-aigo}"
WIDGET_POINT="com.apple.widgetkit-extension"
PLISTBUDDY=/usr/libexec/PlistBuddy

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <ipa>" >&2
  exit 2
fi
IPA="$1"
[ -f "$IPA" ] || { echo "error: IPA not found: $IPA" >&2; exit 1; }
[ -x "$PLISTBUDDY" ] || { echo "error: PlistBuddy not found; run on macOS" >&2; exit 1; }

failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
warn() { echo "WARN  $*"; }

plist_get() { "$PLISTBUDDY" -c "Print :$1" "$2" 2>/dev/null || true; }

expect_eq() { # label actual expected
  if [ "$2" = "$3" ]; then pass "$1 = $2"; else fail "$1: expected '$3', got '${2:-<missing>}'"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$IPA" -d "$work"

app="$work/Payload/$APP_NAME.app"
appex="$app/PlugIns/$WIDGET_NAME.appex"
app_plist="$app/Info.plist"
appex_plist="$appex/Info.plist"

app_count="$(find "$work/Payload" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
expect_eq "app bundles in Payload/" "$app_count" "1"

if [ ! -f "$app_plist" ]; then
  fail "Payload/$APP_NAME.app/Info.plist missing"
  echo "$failures check(s) failed"
  exit 1
fi

# --- App ---------------------------------------------------------------------
expect_eq "app CFBundleIdentifier" "$(plist_get CFBundleIdentifier "$app_plist")" "$APP_ID"
expect_eq "app NSSupportsLiveActivities" "$(plist_get NSSupportsLiveActivities "$app_plist")" "true"

found_scheme=no
i=0
while plist_get "CFBundleURLTypes:$i" "$app_plist" | grep -q .; do
  j=0
  while scheme="$(plist_get "CFBundleURLTypes:$i:CFBundleURLSchemes:$j" "$app_plist")"; [ -n "$scheme" ]; do
    [ "$scheme" = "$URL_SCHEME" ] && found_scheme=yes
    j=$((j + 1))
  done
  i=$((i + 1))
done
if [ "$found_scheme" = yes ]; then pass "URL scheme '$URL_SCHEME' registered"; else fail "URL scheme '$URL_SCHEME' not in CFBundleURLTypes"; fi

families="$("$PLISTBUDDY" -c "Print :UIDeviceFamily" "$app_plist" 2>/dev/null | tr -d '{}()' | tr -s ' \n' ' ' || true)"
case " $families " in
  *" 1 "*) pass "UIDeviceFamily includes iPhone (1)" ;;
  *) fail "UIDeviceFamily does not include iPhone (got: ${families:-<missing>})" ;;
esac

min_os="$(plist_get MinimumOSVersion "$app_plist")"
echo "INFO  app MinimumOSVersion = ${min_os:-<missing>}"

# --- Widget extension ----------------------------------------------------------
if [ -f "$appex_plist" ]; then
  pass "PlugIns/$WIDGET_NAME.appex present"
  expect_eq "widget CFBundleIdentifier" "$(plist_get CFBundleIdentifier "$appex_plist")" "$WIDGET_ID"
  expect_eq "widget NSExtensionPointIdentifier" \
    "$(plist_get NSExtension:NSExtensionPointIdentifier "$appex_plist")" "$WIDGET_POINT"

  app_ver="$(plist_get CFBundleShortVersionString "$app_plist")/$(plist_get CFBundleVersion "$app_plist")"
  appex_ver="$(plist_get CFBundleShortVersionString "$appex_plist")/$(plist_get CFBundleVersion "$appex_plist")"
  if [ "$app_ver" = "$appex_ver" ]; then
    pass "app and widget versions match ($app_ver)"
  else
    warn "app version $app_ver differs from widget version $appex_ver"
  fi
else
  fail "PlugIns/$WIDGET_NAME.appex missing"
fi

# --- Executables ----------------------------------------------------------------
check_exec() { # label bundle
  local exe_name exe archs
  exe_name="$(plist_get CFBundleExecutable "$2/Info.plist")"
  exe="$2/$exe_name"
  if [ -z "$exe_name" ] || [ ! -f "$exe" ]; then
    fail "$1 executable missing (${exe_name:-no CFBundleExecutable})"
    return
  fi
  archs="$(lipo -archs "$exe" 2>/dev/null || true)"
  case "$archs" in
    *arm64*) pass "$1 executable is arm64 ($archs)" ;;
    *) fail "$1 executable is not arm64 (got: ${archs:-unknown})" ;;
  esac
  if [ -x "$exe" ]; then pass "$1 executable has the executable bit"; else fail "$1 executable lost its executable bit"; fi
}
check_exec "app" "$app"
[ -d "$appex" ] && check_exec "widget" "$appex"

if [ -f "$app/embedded.mobileprovision" ]; then
  warn "embedded.mobileprovision present (expected none in an unsigned build)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
