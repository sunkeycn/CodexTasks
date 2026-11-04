#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIRECTORY="$TASK_ROOT/outputs/Codex Tasks.app"
if [[ ! -x "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench" ]]; then
  UNIVERSAL=1 "$TASK_ROOT/scripts/build-app.sh"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIRECTORY/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid app version: $VERSION" >&2; exit 1; }
RELEASE_DIRECTORY="$TASK_ROOT/outputs/release-v$VERSION"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/codex-tasks-dmg.XXXXXX")"
MOUNT_DIRECTORY="$STAGING_DIRECTORY/mounted"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    hdiutil detach "$MOUNT_DIRECTORY" -quiet || true
  fi
  rm -rf "$STAGING_DIRECTORY"
}
trap cleanup EXIT
codesign --verify --deep --strict "$APP_DIRECTORY"
lipo "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench" -verify_arch arm64 x86_64
lipo "$APP_DIRECTORY/Contents/Helpers/CodexTasksHook" -verify_arch arm64 x86_64
mkdir -p "$STAGING_DIRECTORY/content" "$MOUNT_DIRECTORY"
/usr/bin/ditto --norsrc "$APP_DIRECTORY" "$STAGING_DIRECTORY/content/Codex Tasks.app"
ln -s /Applications "$STAGING_DIRECTORY/content/Applications"
cat > "$STAGING_DIRECTORY/content/安装说明.txt" <<'INSTALL'
Codex Tasks — macOS 13+ · Apple Silicon / Intel

1. 将 Codex Tasks.app 拖入 Applications（应用程序）。
2. 弹出磁盘映像，从「应用程序」启动 Codex Tasks。
3. 菜单栏图标 → 设置，确认自己的 Codex 数据目录。

更新前请先从菜单栏退出旧版，替换应用后再启动。任务数据不会清空。

当前版本使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名及公证。
仅在确认来源与校验值后，按 macOS 提示在「系统设置 → 隐私与安全性」
查看「仍要打开」。无需关闭系统的安全保护。

使用说明：https://github.com/sunkeycn/CodexTasks
本地数据：~/Library/Application Support/CodexTasks/Lite/
INSTALL
DMG_NAME="Codex-Tasks-$VERSION-macOS-universal.dmg"
ZIP_NAME="Codex-Tasks-$VERSION-macOS-universal.zip"
hdiutil create -volname "Codex Tasks $VERSION" -srcfolder "$STAGING_DIRECTORY/content" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -nospotlight "$STAGING_DIRECTORY/$DMG_NAME"
hdiutil verify "$STAGING_DIRECTORY/$DMG_NAME"
hdiutil attach "$STAGING_DIRECTORY/$DMG_NAME" -mountpoint "$MOUNT_DIRECTORY" -readonly -nobrowse -quiet
MOUNTED=1
codesign --verify --deep --strict "$MOUNT_DIRECTORY/Codex Tasks.app"
lipo "$MOUNT_DIRECTORY/Codex Tasks.app/Contents/MacOS/FloatingWorkbench" -verify_arch arm64 x86_64
lipo "$MOUNT_DIRECTORY/Codex Tasks.app/Contents/Helpers/CodexTasksHook" -verify_arch arm64 x86_64
[[ "$(readlink "$MOUNT_DIRECTORY/Applications")" == /Applications ]]
python3 - "$APP_DIRECTORY" "$MOUNT_DIRECTORY/Codex Tasks.app" <<'PY'
from pathlib import Path
import hashlib, plistlib, sys
source, mounted = map(Path, sys.argv[1:])
def manifest(root):
    return {str(p.relative_to(root)): ('link', str(p.readlink())) if p.is_symlink()
            else ('file', hashlib.sha256(p.read_bytes()).hexdigest())
            for p in root.rglob('*') if p.is_file() or p.is_symlink()}
assert manifest(source) == manifest(mounted), 'DMG app differs from verified source bundle'
info = plistlib.loads((mounted / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'ai.sunkey.floatingworkbench'
assert info['LSMinimumSystemVersion'] == '13.0'
print('DMG app matches the verified universal bundle; macOS 13.0 minimum confirmed.')
PY
hdiutil detach "$MOUNT_DIRECTORY" -quiet
MOUNTED=0
# Generate the ZIP from the same verified bundle, so attachments always match.
/usr/bin/ditto -c -k --keepParent --norsrc "$APP_DIRECTORY" "$STAGING_DIRECTORY/$ZIP_NAME"
/usr/bin/ditto -x -k "$STAGING_DIRECTORY/$ZIP_NAME" "$STAGING_DIRECTORY/zip-verified"
codesign --verify --deep --strict "$STAGING_DIRECTORY/zip-verified/Codex Tasks.app"
mkdir -p "$RELEASE_DIRECTORY"
cp "$STAGING_DIRECTORY/$DMG_NAME" "$RELEASE_DIRECTORY/$DMG_NAME"
cp "$STAGING_DIRECTORY/$ZIP_NAME" "$RELEASE_DIRECTORY/$ZIP_NAME"
(cd "$RELEASE_DIRECTORY" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt)
printf '%s\n' "$RELEASE_DIRECTORY/$DMG_NAME" "$RELEASE_DIRECTORY/$ZIP_NAME" "$RELEASE_DIRECTORY/SHA256SUMS.txt"
