#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p outputs
swift build --product CodexStatusHook
swift run WorkbenchAcceptance --report "$TASK_ROOT/outputs/核心验收结果.json"

python3 -m unittest discover -s Tests/HookBridge -v

swift run CICDAcceptance --report "$TASK_ROOT/outputs/CI-CD验收结果.json"

swift run FlowUIAcceptance
