#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p outputs
swift run LiteAcceptance --report "$TASK_ROOT/outputs/lite-core-acceptance.json"
