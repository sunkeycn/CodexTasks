#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIRECTORY="$TASK_ROOT/outputs/Codex Tasks.app"
if [[ ! -x "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench" ]]; then
  RELAUNCH=0 "$TASK_ROOT/scripts/build-app.sh"
fi
swift "$TASK_ROOT/scripts/manage-app.swift" stop "$APP_DIRECTORY"
swift "$TASK_ROOT/scripts/manage-app.swift" retire-legacy "$APP_DIRECTORY"
open -n "$APP_DIRECTORY" --args "$@"
swift "$TASK_ROOT/scripts/manage-app.swift" verify "$APP_DIRECTORY"
