"""Non-destructive checks against the actual CLI entry point and signed bundle."""
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess

binary = str(Path(__file__).resolve().parents[1] / 'build/DriveSweep.app/Contents/MacOS/DriveSweep')
prefix = ['rtk', 'proxy'] if shutil.which('rtk') else []

def run(*args, code=0):
    result = subprocess.run([*prefix, binary, '--cli', *args], capture_output=True, text=True, timeout=15)
    assert result.returncode == code, (args, result.returncode, result.stderr, result.stdout)
    return result.stdout

assert '3.1.1' in run('--version')
assert 'confirm-custom' in run('--help')
before = json.loads(run('config', 'show', '--json'))
for args in [('config', 'set', 'volumeRules', '{}', '--json'),
             ('config', 'set', 'periodicCleaningInterval', 'NaN', '--json'),
             ('clean', '/', '--all', '--yes', '--json'),
             ('resources', '--samples', '0', '--json'),
             ('rules', 'list', '--automatic', 'true', '--json')]:
    assert json.loads(run(*args, code=2))['success'] is False
assert json.loads(run('config', 'show', '--json')) == before
assert json.loads(run('clean', '/', '--yes', '--json', code=3))['success'] is False
assert isinstance(json.loads(run('list', '--json'))['volumes'], list)
samples = [json.loads(line) for line in run('resources', '--samples', '2', '--interval', '.25', '--json').splitlines()]
assert len(samples) == 2 and samples[0]['cpuPercent'] is None and samples[1]['cpuPercent'] is not None
assert samples[1]['physicalBytes'] > 0
process = subprocess.Popen([*prefix, binary, '--cli', 'resources', '--watch', '--json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
first = json.loads(process.stdout.readline())
native_pid = first['processes'][0]['pid']
os.kill(native_pid, signal.SIGINT)
stdout, stderr = process.communicate(timeout=5)
assert process.returncode == 130, (process.returncode, stderr)
for line in stdout.splitlines():
    json.loads(line)
# Never launch an automatic runner against user preferences that authorize
# real cleaning. Exercise this branch only with mount auto off and no periodic
# UUID consent; an already-open app may legitimately own the runner.
safe_daemon = not before['automaticCleaning'] and not any(r.get('allowPeriodic', False) for r in before['volumeRules'].values())
daemon_result = 'not run: existing automation consent'
if safe_daemon:
    daemon = subprocess.Popen([*prefix, binary, '--cli', 'daemon', '--json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    first = json.loads(daemon.stdout.readline())
    if first.get('exitCode') == 4:
        daemon.communicate(timeout=5)
        assert daemon.returncode == 4
        daemon_result = 'occupied runner rejected'
    else:
        native_pid = first['processes'][0]['pid']
        try:
            assert json.loads(run('daemon', '--json', code=4))['exitCode'] == 4
        finally:
            os.kill(native_pid, signal.SIGINT)
            daemon.communicate(timeout=10)
        assert daemon.returncode == 130
        daemon_result = 'exclusive foreground daemon and SIGINT verified'
    assert json.loads(run('config', 'show', '--json')) == before
print('PASS: actual CLI JSON, rejected targets/flags, unchanged preferences and SIGINT; ' + daemon_result)
