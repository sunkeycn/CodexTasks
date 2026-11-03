#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
swift build --product CodexTasksHook
BINARY_DIRECTORY="$(swift build --show-bin-path)"
python3 - "$BINARY_DIRECTORY/CodexTasksHook" "$TASK_ROOT/outputs/lite-hooks-acceptance.json" <<'PY'
from pathlib import Path
import json, subprocess, sys, tempfile, uuid
checks = {}
with tempfile.TemporaryDirectory(prefix="codex-tasks-helper-") as temp:
    events = Path(temp) / "events with spaces and 'quotes"
    session = str(uuid.uuid4())
    args = [sys.argv[1], '--events-directory', str(events), '--codex-tasks-hook']
    def run(payload):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return subprocess.run(args, input=data, capture_output=True, timeout=5)
    common = {'session_id':session, 'turn_id':'synthetic-turn'}
    result = run(dict(common, hook_event_name='UserPromptSubmit', prompt='private body\n关联任务【T#12】', cwd='/private-folder'))
    event = json.loads((events / (session + '.json')).read_bytes())
    checks['native-helper-success-without-output'] = result.returncode == 0 and not result.stdout and not result.stderr
    checks['native-helper-records-running-and-task'] = event['status'] == 'running' and event['taskNumber'] == 12
    checks['native-helper-metadata-only'] = 'private' not in json.dumps(event) and set(event) <= {'sessionID','status','updatedAt','turnID','taskNumber','commandAt'}
    result = run(dict(common, hook_event_name='Stop'))
    event = json.loads((events / (session + '.json')).read_bytes())
    checks['native-helper-records-completion'] = result.returncode == 0 and event['status'] == 'completed'
    checks['native-helper-private-event-permissions'] = (events / (session + '.json')).stat().st_mode & 0o777 == 0o600
    result = run(b'{malformed')
    checks['native-helper-invalid-json-does-not-block-codex'] = result.returncode == 0 and not result.stdout and not result.stderr
    result = run(b'x' * 1048577)
    checks['native-helper-bounded-input-fails-open'] = result.returncode == 0 and not result.stdout and not result.stderr
    result = run(dict(common, hook_event_name='UserPromptSubmit', agent_id='synthetic-agent'))
    checks['native-helper-ignores-subagents'] = json.loads((events / (session + '.json')).read_bytes()) == event
report = {'passed':all(checks.values()), 'count':len(checks), 'checks':checks}
Path(sys.argv[2]).write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
for key, passed in checks.items():
    print(('PASS ' if passed else 'FAIL ') + key)
sys.exit(0 if report['passed'] else 1)
PY
