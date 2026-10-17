#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/app-common.sh"

build_app
stop_app
open -n "$APP_PATH" --args "$@"
echo "已启动：$APP_PATH"
