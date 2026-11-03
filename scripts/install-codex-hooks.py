#!/usr/bin/env python3
"""Merge only Codex Tasks lifecycle handlers; Codex retains its own trust review."""
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile


def install(app, destination):
    script = app.resolve() / 'Contents/Resources/codex-status-hook.py'
    if not script.is_file():
        raise ValueError('Build Codex Tasks.app before installing hooks')
    config = json.loads(destination.read_text()) if destination.exists() else {}
    if not isinstance(config, dict) or not isinstance(config.get('hooks', {}), dict):
        raise ValueError('Existing hooks configuration is not an object; original file preserved')
    hooks = config.setdefault('hooks', {})
    source_script = Path(__file__).resolve().with_name('codex-status-hook.py')
    owned_scripts = {str(script), str(source_script)}
    native = app.resolve() / 'Contents/Helpers/CodexStatusHook'
    command = shlex.join([str(native)]) if native.is_file() else shlex.join(['/usr/bin/python3', str(script)])
    owned_scripts.add(str(native))
    for event in ('UserPromptSubmit', 'Stop', 'Interrupt'):
        groups = hooks.get(event, [])
        if not isinstance(groups, list) or any(not isinstance(g, dict) or not isinstance(g.get('hooks'), list) for g in groups):
            raise ValueError('Existing event configuration is invalid; original file preserved')
        merged = []
        for group in groups:
            remaining = []
            for handler in group['hooks']:
                owned = False
                if isinstance(handler, dict) and handler.get('type') == 'command':
                    try:
                        words = shlex.split(handler.get('command', ''))
                        owned = bool(words) and (words[0] in owned_scripts or (len(words) >= 2 and words[1] in owned_scripts))
                    except (ValueError, TypeError):
                        pass
                if not owned:
                    remaining.append(handler)
            if remaining:
                merged.append(dict(group, hooks=remaining))
        merged.append({'hooks': [{'type': 'command', 'command': command, 'timeout': 3, 'async': True}]})
        hooks[event] = merged
    payload = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    if destination.exists() and destination.read_text() == payload:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent, prefix='.tasks-hooks-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(__file__).resolve().parents[1] / 'outputs/Codex Tasks.app')
    parser.add_argument('--hooks-file', type=Path, default=Path.home() / '.codex/hooks.json')
    args = parser.parse_args()
    install(args.app, args.hooks_file)
    print('Codex Tasks: three async lifecycle handlers merged; review their trust in Codex /hooks.')


if __name__ == '__main__':
    main()
