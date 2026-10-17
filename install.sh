#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/app-common.sh"

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [[ "$INSTALL_DIR" != /* ]]; then
    INSTALL_DIR="$PWD/$INSTALL_DIR"
fi
DESTINATION="$INSTALL_DIR/$APP_NAME.app"

build_app
# Stage the complete app bundle before replacing an installed version.
# A custom destination also makes installation testable without system writes.
mkdir -p "$INSTALL_DIR"
if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "错误：没有 $INSTALL_DIR 的写入权限，请使用有权限的账户运行，或设置 INSTALL_DIR。" >&2
    exit 1
fi
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    if [[ -L "$DESTINATION" || ! -d "$DESTINATION" ]]; then
        echo "错误：安装位置不是普通应用目录：$DESTINATION" >&2
        exit 1
    fi
    source_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")"
    if [[ "$source_id" != "$installed_id" ]]; then
        echo "错误：目标位置存在其他应用，已停止覆盖：$DESTINATION" >&2
        exit 1
    fi
fi
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.$APP_NAME-install.XXXXXX")"
cleanup() {
    # Restore the previous installation if replacement fails after moving it.
    if [[ -d "$STAGING_DIR/previous.app" && ! -e "$DESTINATION" ]]; then
        mv "$STAGING_DIR/previous.app" "$DESTINATION"
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$STAGING_DIR/$APP_NAME.app"
stop_app
if [[ -d "$DESTINATION" ]]; then
    mv "$DESTINATION" "$STAGING_DIR/previous.app"
fi
mv "$STAGING_DIR/$APP_NAME.app" "$DESTINATION"
echo "已安装：$DESTINATION"
echo "启动命令：open \"$DESTINATION\""
