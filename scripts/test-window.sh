#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIRECTORY="$TASK_ROOT/outputs/Codex Tasks.app"
if [[ ! -x "$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench" ]]; then RELAUNCH=0 "$TASK_ROOT/scripts/build-app.sh"; fi
SMOKE_DATA="$(mktemp -d "$TASK_ROOT/work/window-test.XXXXXX")"
"$APP_DIRECTORY/Contents/MacOS/FloatingWorkbench" --data-directory "$SMOKE_DATA" --smoke-test-output "$TASK_ROOT/outputs/原生窗口验收.json" --screenshot-output "$TASK_ROOT/outputs/工作台预览.png"
python3 - "$TASK_ROOT/outputs/原生窗口验收.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if report.get('passed') else 1)
PY
