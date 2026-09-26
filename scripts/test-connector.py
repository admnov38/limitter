#!/usr/bin/env python3
"""Exercise installation, capture, passthrough and restore in isolated temporary folders."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/Limitter').resolve()
with tempfile.TemporaryDirectory(prefix='limitter-connector-') as temporary:
    root = pathlib.Path(temporary)
    settings_dir = root / 'claude settings'
    data_dir = root / "Limitter's data"
    settings_dir.mkdir()
    settings_path = settings_dir / 'settings.json'
    original = {'theme': 'dark', 'statusLine': {'type': 'command', 'command': "printf 'original status'", 'padding': 2}}
    settings_path.write_text(json.dumps(original))
    environment = dict(os.environ, CLAUDE_CONFIG_DIR=str(settings_dir), LIMITTER_DATA_DIR=str(data_dir))

    def run(*arguments, **kwargs):
        return subprocess.run([str(binary), *arguments], env=environment, check=True, capture_output=True, text=True, **kwargs)

    run('--install-claude-connector')
    installed = json.loads(settings_path.read_text())
    assert installed['theme'] == 'dark'
    assert installed['statusLine']['padding'] == 2
    assert installed['statusLine']['refreshInterval'] == 30
    assert list(data_dir.glob('claude-settings-backup-*.json'))
    run('--install-claude-connector')  # Reinstallation must not lose the original command.
    payload = {'rate_limits': {'five_hour': {'used_percentage': 27, 'resets_at': 1999999999}},
               'cwd': '/private/work', 'session_id': 'private-session', 'model': {'display_name': 'Claude'}}
    captured = subprocess.run(['/bin/sh', '-c', installed['statusLine']['command']], input=json.dumps(payload),
                              env=environment, check=True, capture_output=True, text=True)
    assert captured.stdout == 'original status', captured.stdout
    stored = json.loads((data_dir / 'claude-usage.json').read_text())
    assert set(stored) == {'rate_limits', 'captured_at', 'received_at', 'window_captured_at', 'window_errors'}
    assert stored['rate_limits']['five_hour']['used_percentage'] == 27
    assert (data_dir / 'claude-usage.json').stat().st_mode & 0o777 == 0o600
    previous_time = stored['window_captured_at']['five_hour']
    # Startup, null, and partial updates must preserve the other window's timestamp and value.
    run('--capture-claude', input=json.dumps({'rate_limits': {'five_hour': None, 'seven_day': {'used_percentage': 19, 'resets_at': 1999999999}}}))
    run('--capture-claude', input=json.dumps({'rate_limits': {}, 'session_id': 'discard-me'}))
    partial = json.loads((data_dir / 'claude-usage.json').read_text())
    assert partial['rate_limits']['five_hour']['used_percentage'] == 27
    assert partial['window_captured_at']['five_hour'] == previous_time
    assert partial['rate_limits']['seven_day']['used_percentage'] == 19
    assert 'session_id' not in partial
    # Multiple terminals can send windows concurrently. The merge is serialized by the bridge.
    processes = []
    for key, percent in [('five_hour', 34), ('seven_day', 21)]:
        process = subprocess.Popen([str(binary), '--capture-claude'], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        process.stdin.write(json.dumps({'rate_limits': {key: {'used_percentage': percent, 'resets_at': 1999999999}}}))
        process.stdin.close()
        processes.append(process)
    for process in processes:
        assert process.wait(timeout=10) == 0
    merged = json.loads((data_dir / 'claude-usage.json').read_text())
    assert merged['rate_limits']['five_hour']['used_percentage'] == 34
    assert merged['rate_limits']['seven_day']['used_percentage'] == 21
    run('--capture-claude', input=json.dumps({'rate_limits': {'five_hour': {'used_percentage': 106, 'resets_at': 1999999999}}}))
    health = run('--diagnose-claude').stdout
    assert '106% used' in health and 'SYNC ERROR' not in health, health
    edited = json.loads(settings_path.read_text())
    edited['newSetting'] = True
    settings_path.write_text(json.dumps(edited))
    run('--remove-claude-connector')
    restored = json.loads(settings_path.read_text())
    assert restored['statusLine'] == original['statusLine']
    assert restored['newSetting'] is True
    # Refuse malformed settings rather than replacing them.
    settings_path.write_text('{invalid')
    result = subprocess.run([str(binary), '--install-claude-connector'], env=environment, capture_output=True)
    assert result.returncode != 0
    assert settings_path.read_text() == '{invalid'
print('Connector integration checks passed.')
