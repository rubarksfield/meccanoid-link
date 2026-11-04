#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/xcode"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/MeccanoidLink.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/MeccanoidLink"
PROCESS_HELPER="$ROOT_DIR/script/app_process.py"
MODE=run
DEMO=0

usage() {
  echo "Usage: $0 [--verify|--debug|--logs|--telemetry|--build-only] [--demo]"
  echo "Optional MECCANOID_DEVELOPMENT_TEAM selects your local Apple signing team."
}

for argument in "$@"; do
  case "$argument" in
    --demo) DEMO=1 ;;
    --verify|--debug|--logs|--telemetry|--build-only)
      if [[ "$MODE" != run ]]; then
        usage >&2
        exit 2
      fi
      MODE="$argument"
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

cd "$ROOT_DIR"
/usr/bin/python3 "$PROCESS_HELPER" stop "$APP_BINARY"

SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n "${MECCANOID_DEVELOPMENT_TEAM:-}" ]]; then
  SIGNING=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$MECCANOID_DEVELOPMENT_TEAM")
fi

xcodebuild \
  -project "$ROOT_DIR/MeccanoidLink.xcodeproj" \
  -scheme MeccanoidLink \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING[@]}" \
  build

if [[ "$MODE" == --build-only ]]; then
  echo "Built: $APP_BUNDLE"
  exit 0
fi

if [[ "$DEMO" == 1 ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --demo
else
  /usr/bin/open -n "$APP_BUNDLE"
fi

verify_process() {
  local attempt
  for attempt in {1..20}; do
    if /usr/bin/python3 "$PROCESS_HELPER" find "$APP_BINARY" >/dev/null; then
      echo "Running: $APP_BUNDLE"
      return 0
    fi
    sleep 0.25
  done
  echo "Build succeeded, but the app process was not found at its expected path." >&2
  return 1
}

case "$MODE" in
  run) ;;
  --verify) verify_process ;;
  --debug)
    verify_process
    APP_PID="$(/usr/bin/python3 "$PROCESS_HELPER" find "$APP_BINARY" | head -n 1)"
    xcrun lldb -p "$APP_PID"
    ;;
  --logs)
    /usr/bin/log stream --info --style compact --predicate 'process == "MeccanoidLink"'
    ;;
  --telemetry)
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.rubarksfield.meccanoidlink"'
    ;;
esac
