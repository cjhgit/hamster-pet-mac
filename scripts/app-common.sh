#!/bin/bash
# Shared by run.sh and install.sh; compatible with macOS's bundled Bash.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Hamster Pet"
APP_PATH="$PROJECT_DIR/.build/Build/Products/Release/$APP_NAME.app"

build_app() {
    echo "正在构建 Release 应用……"
    xcodebuild -quiet \
        -project "$PROJECT_DIR/hamster-mac.xcodeproj" \
        -scheme "hamster-mac" \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$PROJECT_DIR/.build" \
        CODE_SIGN_IDENTITY=- build
    if [[ ! -x "$APP_PATH/Contents/MacOS/$APP_NAME" ]]; then
        echo "错误：未找到构建产物 $APP_PATH" >&2
        return 1
    fi
    codesign --verify --deep --strict "$APP_PATH"
}

stop_app() {
    local pids status pid attempt alive
    if pids="$(pgrep -x "$APP_NAME|hamster-mac")"; then
        echo "正在结束旧进程……"
    else
        status=$?
        [[ "$status" -eq 1 ]] && return 0
        echo "错误：无法查询旧进程。" >&2
        return "$status"
    fi
    # pgrep returns numeric PIDs, one per line; never match the invoking shell.
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || {
            if kill -0 "$pid" 2>/dev/null; then
                echo "错误：无法结束进程 $pid。" >&2
                return 1
            fi
        }
    done
    for ((attempt = 0; attempt < 50; attempt++)); do
        alive=0
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        [[ "$alive" -eq 0 ]] && return 0
        sleep 0.1
    done
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid"
        fi
    done
}
