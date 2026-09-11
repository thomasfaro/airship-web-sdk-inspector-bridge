#!/usr/bin/env bash
# Build "Start Airship bridge.app" in ~/Applications and register it as the
# handler for airship-bridge:// links.
#
# The bundle is what lets the bridge page start its own server, and what lets the
# background service reach a folder in Downloads. It is compiled here rather than
# shipped, which has a happy side effect: a bundle built on this machine carries
# no download quarantine, so Gatekeeper has nothing to say about it.
#
#   --quiet   speak only when something is created or fails
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Start Airship bridge.app"
APP_DIR="$HOME/Applications"
APP_PATH="$APP_DIR/$APP_NAME"
SOURCE="$ROOT/scripts/url-handler.applescript"
ICON_PNG="$ROOT/bridge/icon512.png"
BUNDLE_ID="com.airship.websdkinspector.bridge.launcher"
SCHEME="airship-bridge"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
QUIET=0

if [[ "${1:-}" == "--quiet" ]]; then
  QUIET=1
fi

say() {
  [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  say "airship-bridge:// links are a macOS thing; nothing to do here."
  exit 0
fi
if ! command -v osacompile >/dev/null 2>&1; then
  echo "osacompile is missing, so airship-bridge:// links cannot be registered." >&2
  exit 1
fi

# The folder path is baked into the bundle, so a moved bridge folder needs a
# rebuild. So does an edited template.
recorded_root=""
if [[ -f "$APP_PATH/Contents/Resources/bridge-root" ]]; then
  recorded_root="$(cat "$APP_PATH/Contents/Resources/bridge-root")"
fi
if [[ -d "$APP_PATH" ]] &&
  [[ "$recorded_root" == "$ROOT" ]] &&
  [[ -f "$APP_PATH/Contents/Resources/Scripts/main.scpt" ]] &&
  [[ ! "$SOURCE" -nt "$APP_PATH/Contents/Resources/Scripts/main.scpt" ]]; then
  say "Already registered: $APP_PATH"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed "s|__ROOT__|${ROOT}|g" "$SOURCE" >"$tmp/handler.applescript"

mkdir -p "$APP_DIR"
# Launch Services keeps a record per path and does not notice when the bundle
# behind it is replaced: it then accepts the links and launches nothing at all.
# So withdraw the old record before touching the folder.
if [[ -d "$APP_PATH" && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP_PATH" || true
fi
rm -rf "$APP_PATH"
if ! osacompile -o "$APP_PATH" "$tmp/handler.applescript" >"$tmp/osacompile.log" 2>&1; then
  cat "$tmp/osacompile.log" >&2
  echo "Could not build the launcher bundle." >&2
  exit 1
fi

plist="$APP_PATH/Contents/Info.plist"
# PlistBuddy complains loudly when Set finds nothing, which is the normal path
# for keys osacompile did not write.
buddy() { /usr/libexec/PlistBuddy -c "$1" "$plist" >/dev/null 2>&1; }

buddy "Set :CFBundleIdentifier ${BUNDLE_ID}" || buddy "Add :CFBundleIdentifier string ${BUNDLE_ID}"
buddy "Set :CFBundleName Start Airship bridge" || buddy "Add :CFBundleName string Start Airship bridge"
# LSUIElement would keep it out of the Dock, and would also stop it ever
# receiving the URL event, which is the entire point of the bundle. It shows for
# the second it takes to fire the launcher, and that reads as feedback.
buddy "Add :CFBundleURLTypes array"
buddy "Add :CFBundleURLTypes:0 dict"
buddy "Add :CFBundleURLTypes:0:CFBundleURLName string Airship Web SDK Inspector bridge"
buddy "Add :CFBundleURLTypes:0:CFBundleURLSchemes array"
buddy "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ${SCHEME}"

# osacompile points CFBundleIconFile at applet.icns, so replacing that file is
# enough. The icon the page uses is a PNG, and iconutil wants a full iconset.
if [[ -f "$ICON_PNG" ]] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  iconset="$tmp/bridge.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$iconset/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_PNG" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$iconset" -o "$tmp/applet.icns" >/dev/null 2>&1; then
    cp "$tmp/applet.icns" "$APP_PATH/Contents/Resources/applet.icns"
  fi
fi

printf '%s\n' "$ROOT" >"$APP_PATH/Contents/Resources/bridge-root"

# osacompile signs what it builds, and every edit above breaks that seal — macOS
# then refuses to launch the bundle at all, silently. So re-seal it, last, once
# nothing else will change. codesign ships with macOS; no developer tools needed.
if ! codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || ! codesign --verify "$APP_PATH" >/dev/null 2>&1; then
  rm -rf "$APP_PATH"
  echo "Could not sign the launcher bundle, so macOS would refuse to run it." >&2
  exit 1
fi

# Register now rather than waiting for Launch Services to notice by itself.
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_PATH" || true
fi

printf '%s\n' "Registered \"Start Airship bridge\" in your Applications folder."
say ""
say "It answers ${SCHEME}:// links, which is how the bridge page starts the server"
say "when it finds it stopped, and you can keep it in the Dock to start the bridge"
say "without a terminal window."
