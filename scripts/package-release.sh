#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法：bash scripts/package-release.sh 1.0.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：版本号必须为 x.y.z。" >&2
    exit 1
fi
RELEASE_BUILD_DIR="$PWD/.build/release"
RELEASE_OUTPUT_DIR="$PWD/dist"
RELEASE_APP="$RELEASE_BUILD_DIR/Build/Products/Release/Hamster Pet.app"
RELEASE_NAME="Hamster-Pet-$VERSION-universal"
mkdir -p "$RELEASE_OUTPUT_DIR"
RELEASE_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hamster-release.XXXXXX")"
trap 'rm -rf "$RELEASE_STAGING_DIR"' EXIT

xcodebuild -quiet -project hamster-mac.xcodeproj -scheme hamster-mac \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$RELEASE_BUILD_DIR" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
    CODE_SIGN_IDENTITY=- build

codesign --verify --deep --strict "$RELEASE_APP"
lipo -verify_arch arm64 x86_64 "$RELEASE_APP/Contents/MacOS/Hamster Pet"
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$RELEASE_APP/Contents/Info.plist" | grep -qx true
test -f "$RELEASE_APP/Contents/Resources/AppIcon.icns"

ditto "$RELEASE_APP" "$RELEASE_STAGING_DIR/Hamster Pet.app"
ln -s /Applications "$RELEASE_STAGING_DIR/Applications"
cat > "$RELEASE_STAGING_DIR/安装说明.txt" <<'EOF'
Hamster Pet · macOS 14 及以上（Apple 芯片 / Intel）

将 Hamster Pet.app 拖入 Applications，然后从“应用程序”打开。
应用会显示仓鼠窗口和菜单栏爪印，不占据 Dock；关闭窗口后可从菜单栏重新显示。

本版本使用临时签名，尚未完成 Apple Developer ID 签名与公证。
若 macOS 阻止首次打开：先尝试打开一次，再到“系统设置 → 隐私与安全性”
找到 Hamster Pet 的提示，选择“仍要打开”，按系统提示确认。
无需关闭系统安全保护。只应为你信任并从项目 Releases 下载的应用确认打开。

项目：https://github.com/cjhgit/hamster-pet-mac
EOF
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$RELEASE_OUTPUT_DIR/$RELEASE_NAME.zip"
hdiutil create -volname "Hamster Pet" -srcfolder "$RELEASE_STAGING_DIR" \
    -ov -format UDZO "$RELEASE_OUTPUT_DIR/$RELEASE_NAME.dmg"
(
    cd "$RELEASE_OUTPUT_DIR"
    shasum -a 256 "$RELEASE_NAME.dmg" "$RELEASE_NAME.zip" > "$RELEASE_NAME-SHA256SUMS.txt"
)
echo "发布包已生成：$RELEASE_OUTPUT_DIR/$RELEASE_NAME.{dmg,zip}"
