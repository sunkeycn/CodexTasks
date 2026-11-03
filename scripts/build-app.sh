#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
BUILD_CONFIGURATION="${CONFIGURATION:-release}"
swift build -c "$BUILD_CONFIGURATION" --product FloatingWorkbench
BINARY_DIRECTORY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/floating-workbench-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
APP_DIRECTORY="$STAGING_DIRECTORY/Codex Tasks.app"
mkdir -p "$APP_DIRECTORY/Contents/MacOS" "$APP_DIRECTORY/Contents/Resources"
cp "$BINARY_DIRECTORY/FloatingWorkbench" "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$BUILD_CONFIGURATION" --triple arm64-apple-macosx13.0 --product FloatingWorkbench
  swift build -c "$BUILD_CONFIGURATION" --triple x86_64-apple-macosx13.0 --product FloatingWorkbench
  lipo -create "$TASK_ROOT/.build/arm64-apple-macosx/$BUILD_CONFIGURATION/FloatingWorkbench" "$TASK_ROOT/.build/x86_64-apple-macosx/$BUILD_CONFIGURATION/FloatingWorkbench" -output "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench"
fi
mkdir -p "$TASK_ROOT/work"
swift "$TASK_ROOT/scripts/make-icon.swift" "$TASK_ROOT/work/AppIcon.iconset"
iconutil -c icns "$TASK_ROOT/work/AppIcon.iconset" -o "$APP_DIRECTORY/Contents/Resources/AppIcon.icns"
cat > "$APP_DIRECTORY/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FloatingWorkbench</string>
<key>CFBundleIdentifier</key><string>ai.sunkey.floatingworkbench</string>
<key>CFBundleName</key><string>Codex Tasks</string>
<key>CFBundleDisplayName</key><string>Codex Tasks</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.1</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign in an isolated staging directory: Documents File Provider can reattach
# FinderInfo to a bundle immediately after it has been cleaned.
codesign --force --sign - "$APP_DIRECTORY"
codesign --verify --deep --strict "$APP_DIRECTORY"
# Validate both the bundle and ZIP before stopping the running app.
/usr/bin/ditto -c -k --keepParent --norsrc "$APP_DIRECTORY" "$STAGING_DIRECTORY/Codex-Tasks-macOS.zip"
/usr/bin/ditto -x -k "$STAGING_DIRECTORY/Codex-Tasks-macOS.zip" "$STAGING_DIRECTORY/verified"
codesign --verify --deep --strict "$STAGING_DIRECTORY/verified/Codex Tasks.app"
if [[ "${RELAUNCH:-1}" == "1" ]]; then
  swift "$TASK_ROOT/scripts/manage-app.swift" stop "$APP_DIRECTORY"
fi
python3 - "$APP_DIRECTORY" "$TASK_ROOT/outputs" <<'PYPACK'
from pathlib import Path
import shutil, sys
source = Path(sys.argv[1])
output = Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
destination = output / source.name
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, copy_function=shutil.copy)
shutil.copyfile(source.parent / 'Codex-Tasks-macOS.zip', output / 'Codex-Tasks-macOS.zip')
PYPACK
codesign --verify --deep --strict "$TASK_ROOT/outputs/Codex Tasks.app"
if [[ "${RELAUNCH:-1}" == "1" ]]; then
  swift "$TASK_ROOT/scripts/manage-app.swift" retire-legacy "$TASK_ROOT/outputs/Codex Tasks.app"
  open -n "$TASK_ROOT/outputs/Codex Tasks.app"
  swift "$TASK_ROOT/scripts/manage-app.swift" verify "$TASK_ROOT/outputs/Codex Tasks.app"
fi
printf '%s\n' "$TASK_ROOT/outputs/Codex Tasks.app"
