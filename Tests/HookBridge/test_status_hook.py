import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/codex-status-hook.py'


class StatusHookTests(unittest.TestCase):
    def test_events_are_atomic_metadata_only_and_silent(self):
        with tempfile.TemporaryDirectory() as temp:
            status = Path(temp) / 'status'
            payload = {'session_id': 'session-1', 'turn_id': 'turn-1', 'cwd': temp,
                       'prompt': 'synthetic-private-prompt', 'last_assistant_message': 'synthetic-private-output'}
            for event in ('UserPromptSubmit', 'Stop', 'Interrupt'):
                payload['turn_id'] = 'turn-' + event
                payload['hook_event_name'] = event
                result = subprocess.run([sys.executable, str(SCRIPT), '--status-directory', str(status), '--endpoint-file', str(Path(temp) / 'missing-endpoint.json')], input=json.dumps(payload), text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, '')
                files = list(status.glob('*.json'))
                self.assertEqual(len(files), 1)
                self.assertEqual(files[0].name, hashlib.sha256(b'session-1').hexdigest() + '.json')
                record = json.loads(files[0].read_text())
                self.assertEqual(set(record), {'version', 'sessionID', 'turnID', 'cwd', 'event', 'updatedAt'})
                self.assertEqual(record['event'], event)
                self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
                self.assertNotIn('synthetic-private', files[0].read_text())

    def test_invalid_payload_and_subagent_do_not_write(self):
        with tempfile.TemporaryDirectory() as temp:
            status = Path(temp) / 'status'
            base = {'session_id': 'session', 'turn_id': 'turn', 'cwd': temp, 'hook_event_name': 'Stop'}
            inputs = ['broken', '[]', '{}', json.dumps(dict(base, agent_id='child')),
                      json.dumps(dict(base, cwd='relative')), json.dumps(dict(base, turn_id='')),
                      json.dumps(dict(base, hook_event_name='PreToolUse'))]
            for payload in inputs:
                result = subprocess.run([sys.executable, str(SCRIPT), '--status-directory', str(status), '--endpoint-file', str(Path(temp) / 'missing-endpoint.json')], input=payload, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertFalse(status.exists())

    def test_install_preserves_other_hooks_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / 'Codex Tasks.app'
            script = app / 'Contents/Resources/codex-status-hook.py'
            script.parent.mkdir(parents=True)
            script.write_text('# fixture')
            destination = root / 'hooks.json'
            existing = {'hooks': {'Stop': [{'matcher': 'existing', 'hooks': [{'type': 'command', 'command': 'other-notifier'}]}], 'SessionStart': [{'hooks': [{'type': 'command', 'command': 'existing-start'}]}]}, 'custom': {'keep': True}}
            destination.write_text(json.dumps(existing))
            installer = SCRIPT.with_name('install-codex-hooks.py')
            command = [sys.executable, str(installer), '--app', str(app), '--hooks-file', str(destination)]
            subprocess.run(command, capture_output=True, check=True)
            first = destination.read_text()
            subprocess.run(command, capture_output=True, check=True)
            self.assertEqual(destination.read_text(), first)
            config = json.loads(first)
            self.assertEqual(config['custom'], existing['custom'])
            self.assertEqual(config['hooks']['SessionStart'], existing['hooks']['SessionStart'])
            self.assertEqual(config['hooks']['Stop'][0], existing['hooks']['Stop'][0])
            self.assertEqual(len(config['hooks']['Stop']), 2)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            native = app / 'Contents/Helpers/CodexStatusHook'
            native.parent.mkdir(parents=True)
            native.write_text('fixture')
            subprocess.run(command, capture_output=True, check=True)
            upgraded = json.loads(destination.read_text())
            self.assertEqual(len(upgraded['hooks']['Stop']), 2)
            self.assertIn('Contents/Helpers/CodexStatusHook', upgraded['hooks']['Stop'][-1]['hooks'][0]['command'])


    def test_config_is_explicit_and_does_not_install(self):
        with tempfile.TemporaryDirectory() as temp:
            status = Path(temp) / 'status'
            result = subprocess.run([sys.executable, str(SCRIPT), '--status-directory', str(status), '--print-config'], capture_output=True, text=True, check=True)
            config = json.loads(result.stdout)
            self.assertEqual(set(config['hooks']), {'UserPromptSubmit', 'Stop', 'Interrupt'})
            self.assertFalse(status.exists())
            self.assertTrue(all(group['hooks'][0]['async'] for groups in config['hooks'].values() for group in groups))


if __name__ == '__main__':
    unittest.main()
