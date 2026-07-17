#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="XMterm"
BUNDLE_ID="com.xmterm.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
STAGING_BUNDLE="$DIST_DIR/.$APP_NAME.app.staging.$$"
STAGING_CONTENTS="$STAGING_BUNDLE/Contents"
STAGING_MACOS="$STAGING_CONTENTS/MacOS"
STAGING_RESOURCES="$STAGING_CONTENTS/Resources"
STAGING_BINARY="$STAGING_MACOS/$APP_NAME"
STAGING_INFO_PLIST="$STAGING_CONTENTS/Info.plist"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    usage
    exit 2
    ;;
esac

SWIFT_EXECUTABLE="$(command -v swift || true)"
if [[ -z "$SWIFT_EXECUTABLE" ]]; then
  echo "error: swift was not found on PATH" >&2
  exit 1
fi

running_project_pids() {
  local pid
  local executable

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$executable" == "$APP_BINARY" ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)
}

signal_project_processes() {
  local signal="$1"
  local pid
  local executable

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$executable" == "$APP_BINARY" ]]; then
      /bin/kill "-$signal" "$pid" 2>/dev/null || true
    fi
  done < <(running_project_pids)
}

stop_running_project_app() {
  local attempt

  if [[ -z "$(running_project_pids)" ]]; then
    return
  fi

  signal_project_processes TERM
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    if [[ -z "$(running_project_pids)" ]]; then
      return
    fi
    /bin/sleep 0.1
  done

  signal_project_processes KILL
}

cleanup_staging_bundle() {
  /bin/rm -rf "$STAGING_BUNDLE"
}

stage_app_bundle() {
  local build_bin_dir
  local build_binary
  local swiftterm_bundle
  local swiftterm_license

  "$SWIFT_EXECUTABLE" build --package-path "$ROOT_DIR" --product "$APP_NAME"
  build_bin_dir="$("$SWIFT_EXECUTABLE" build --package-path "$ROOT_DIR" --show-bin-path)"
  build_binary="$build_bin_dir/$APP_NAME"

  if [[ ! -x "$build_binary" ]]; then
    echo "error: SwiftPM did not produce executable $build_binary" >&2
    exit 1
  fi

  /bin/mkdir -p "$DIST_DIR"
  cleanup_staging_bundle
  /bin/mkdir -p "$STAGING_MACOS" "$STAGING_RESOURCES/ThirdPartyLicenses"
  /bin/cp "$build_binary" "$STAGING_BINARY"
  /bin/chmod 755 "$STAGING_BINARY"

  swiftterm_bundle="$build_bin_dir/SwiftTerm_SwiftTerm.bundle"
  if [[ ! -d "$swiftterm_bundle" ]]; then
    echo "error: SwiftTerm resource bundle was not produced at $swiftterm_bundle" >&2
    exit 1
  fi
  # Phase 1 uses SwiftTerm's CoreGraphics renderer. Keep its unused Metal shader resource in the
  # standard sealed app resource location; enabling Metal later requires a packaging-aware
  # Bundle.module lookup instead of placing unsealed content at the app bundle root.
  /bin/cp -R "$swiftterm_bundle" "$STAGING_RESOURCES/SwiftTerm_SwiftTerm.bundle"

  swiftterm_license="$ROOT_DIR/.build/checkouts/SwiftTerm/LICENSE"
  if [[ ! -f "$swiftterm_license" ]]; then
    echo "error: SwiftTerm license was not found at $swiftterm_license" >&2
    exit 1
  fi
  /bin/cp "$swiftterm_license" \
    "$STAGING_RESOURCES/ThirdPartyLicenses/SwiftTerm-LICENSE.txt"

  /bin/cat >"$STAGING_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/plutil -lint "$STAGING_INFO_PLIST" >/dev/null
  /usr/bin/codesign --force --deep --sign - "$STAGING_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$STAGING_BUNDLE"
  /bin/rm -rf "$APP_BUNDLE"
  /bin/mv "$STAGING_BUNDLE" "$APP_BUNDLE"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_project_app() {
  local attempt

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if [[ -n "$(running_project_pids)" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done

  return 1
}

trap cleanup_staging_bundle EXIT

stop_running_project_app
stage_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    LLDB_EXECUTABLE="$(command -v lldb || true)"
    if [[ -z "$LLDB_EXECUTABLE" ]]; then
      echo "error: lldb was not found on PATH" >&2
      exit 1
    fi
    "$LLDB_EXECUTABLE" -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    if ! wait_for_project_app; then
      echo "error: $APP_NAME did not remain running from $APP_BINARY" >&2
      exit 1
    fi
    echo "$APP_NAME is running from $APP_BINARY"
    ;;
esac
