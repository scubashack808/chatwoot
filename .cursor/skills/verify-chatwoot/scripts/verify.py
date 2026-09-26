#!/usr/bin/env python3
"""Serial, synthetic-only pilot for the already-provisioned native dummy copy."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import signal
import stat
import subprocess
import sys
import time
import urllib.request

BASE_SHA = 'd76b96565762a2b491fa444e9870ee216d9f63ca'
SCRIPT_DIR = Path(__file__).resolve().parent
SOURCE = SCRIPT_DIR.parents[3]
ROOT = Path.home() / 'Cursor/chatwoot-dummy'
MANAGER = ROOT / '.codex/dummy/manage.py'
SOCKET = ROOT / 'tmp/dummy/overmind.sock'
BROWSER = Path.home() / '.local/bin/browser-harness'
EVIDENCE = SOURCE / 'tmp/verify-chatwoot'
HOST = 'MacBook-Air.local'
SITE = 'http://127.0.0.1:3001'
MAIL = 'http://127.0.0.1:8025'
PORTS = {'redis': 6380, 'smtp': 1025, 'mail': 8025, 'backend': 3001, 'vite': 3038}
SHARED_PORTS = (5432, 6379)
COMMAND_TIMEOUT = 120
HTTP_TIMEOUT = 10
STARTUP_TIMEOUT = 90
BROWSER_TIMEOUT = 300
POLL_SECONDS = 1
FAILURE_EXIT = 2
PRIVATE_MODE = 0o700
PROTECTED_MODE = 0o077
SHA_LENGTH = 40
ZERO_SHA = '0' * SHA_LENGTH
ERROR_TAIL_CHARS = 1800
PROCESS_TIMESTAMP_RESOLUTION = 1
RUNTIME_FILES = ('Procfile.worktree', '.env', '.codex/dummy/manage.py', '.codex/dummy/local_http.rb',
                 '.codex/dummy/redis.conf', '.codex/dummy/sidekiq.yml')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('Local service redirected; refusing to follow')

def get(url):
    if not (url.startswith(SITE + '/') or url.startswith(MAIL + '/')):
        raise ValueError('Only the fixed loopback endpoints are permitted')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(url, timeout=HTTP_TIMEOUT) as response:
        return response.read()

def command(args, timeout=COMMAND_TIMEOUT, cwd=ROOT):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} exited {result.returncode}: {result.stderr[-ERROR_TAIL_CHARS:]}')
    return result.stdout

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def environment():
    path = ROOT / '.env'
    require(not path.is_symlink(), 'Refusing symlinked credentials')
    require(path.stat().st_mode & PROTECTED_MODE == 0, '.env must be private')
    values = dict(line.split('=', 1) for line in path.read_text().splitlines()
                  if line and not line.startswith('#'))
    expected = {'DUMMY_ROOT': str(ROOT), 'FRONTEND_URL': SITE,
                'DUMMY_EMAIL': 'agent@chatwoot-dummy.test',
                'POSTGRES_HOST': '127.0.0.1', 'POSTGRES_USERNAME': 'chatwoot_dummy',
                'PORT': '3001', 'VITE_RUBY_PORT': '3038', 'DUMMY_REDIS_PORT': '6380',
                'SMTP_ADDRESS': '127.0.0.1', 'SMTP_PORT': '1025',
                'DUMMY_MAIL_PORT': '8025', 'RAILS_ENV': 'development'}
    for key, value in expected.items():
        require(values.get(key) == value, f'Unexpected local configuration: {key}')
    require(bool(values.get('DUMMY_PASSWORD')), 'Synthetic password missing')
    return values

def candidate(expected_sha):
    require(socket.gethostname() == HOST, 'This pilot is authorized only on MacBook-Air.local')
    require(ROOT.resolve() == ROOT and MANAGER.is_file(), 'Provisioned native dummy copy missing')
    require(re.fullmatch(r'[0-9a-f]{40}', expected_sha), 'Expected SHA must be a full commit SHA')
    actual = command(['git', 'rev-parse', 'HEAD']).strip()
    require(actual == expected_sha, f'Candidate mismatch: expected {expected_sha}, found {actual}')
    command(['git', 'diff', '--quiet', 'HEAD'])
    untracked = command(['git', 'ls-files', '--others', '--exclude-standard', '--',
                         'app', 'config', 'lib', 'enterprise', 'db', 'public']).strip()
    require(not untracked, 'Untracked application source must be admitted separately')
    runtime_common = command(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir']).strip()
    source_common = command(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=SOURCE).strip()
    require(runtime_common == source_common, 'Skill and runtime must belong to the same repository')
    environment()
    return actual

def listeners(port):
    result = subprocess.run(['/usr/sbin/lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-Fpn'],
                            capture_output=True, text=True, timeout=HTTP_TIMEOUT)
    require(result.returncode in (0, 1), 'Listener discovery failed')
    records, current = [], None
    for line in result.stdout.splitlines():
        if line.startswith('p'):
            current = {'pid': int(line[1:]), 'addresses': []}
            records.append(current)
        elif line.startswith('n') and current:
            current['addresses'].append(line[1:])
    return records

def process_parents():
    output = command(['/bin/ps', '-axo', 'pid=,ppid='])
    return {int(parts[0]): int(parts[1]) for line in output.splitlines() if len(parts := line.split()) == 2}

def is_descendant(pid, ancestor, parents):
    seen = set()
    while pid and pid not in seen:
        if pid == ancestor:
            return True
        seen.add(pid)
        pid = parents.get(pid, 0)
    return False

def supervisor_identity():
    require(SOCKET.lstat().st_uid == os.getuid(), 'Supervisor socket has a different owner')
    rows = command(['/usr/sbin/lsof', '-nP', '-U', '-Fpn'])
    current, matches = None, set()
    for row in rows.splitlines():
        if row.startswith('p'):
            current = int(row[1:])
        elif row == 'n' + str(SOCKET):
            matches.add(current)
    require(len(matches) == 1, 'Expected exactly one process owning the supervisor socket')
    pid = matches.pop()
    cwd = command(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'])
    require('n' + str(ROOT) in cwd.splitlines(), 'Supervisor working directory differs')
    cmd = command(['/bin/ps', '-p', str(pid), '-o', 'command=']).strip()
    require('overmind start' in cmd and str(SOCKET) in cmd, 'Supervisor command identity differs')
    require(command(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip() == str(os.getuid()), 'Supervisor user differs')
    return pid

def worker_identity(wrapper_pid, parents):
    matches = []
    for pid in parents:
        if is_descendant(pid, wrapper_pid, parents):
            cmd = command(['/bin/ps', '-p', str(pid), '-o', 'command=']).strip()
            if re.match(r'^sidekiq [0-9]', cmd):
                cwd = command(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'])
                require('n' + str(ROOT) in cwd.splitlines(), 'Worker directory differs')
                require(command(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip() == str(os.getuid()), 'Worker user differs')
                matches.append({'pid': pid, 'command': cmd})
    require(len(matches) == 1, 'Expected one Sidekiq descendant of the reported worker')
    return matches[0]

def owned_services(require_ready=True):
    require(SOCKET.exists() and stat.S_ISSOCK(SOCKET.lstat().st_mode), 'Dummy supervisor is down')
    supervisor_pid = supervisor_identity()
    status = command(['/opt/homebrew/bin/overmind', 'status', '-s', SOCKET])
    wrappers = {name: int(pid) for name, pid in re.findall(r'^(redis|mail|backend|vite|worker)\s+(\d+)\s+', status, re.M)}
    parents = process_parents()
    if require_ready:
        for service in ('redis', 'mail', 'backend', 'vite', 'worker'):
            require(re.search(rf'^{service}\s+\d+\s+running$', status, re.M), f'{service} is not running')
    inventory = {}
    for name, port in PORTS.items():
        records = listeners(port)
        if not records and not require_ready:
            continue
        require(len(records) == 1, f'Expected exactly one {name} listener')
        record = records[0]
        service = 'mail' if name == 'smtp' else name
        require(service in wrappers and is_descendant(record['pid'], wrappers[service], parents),
                f'{name} listener is not a descendant of its supervised service')
        require(record['addresses'] == [f'127.0.0.1:{port}'], f'{name} is not loopback-only')
        cwd = command(['/usr/sbin/lsof', '-a', '-p', str(record['pid']), '-d', 'cwd', '-Fn'])
        allowed = {f'n{ROOT}'}
        if name == 'redis':
            allowed.add(f'n{ROOT}/tmp/dummy/state')
        require(bool(set(cwd.splitlines()) & allowed), f'{name} belongs to a different directory')
        uid = command(['/bin/ps', '-p', str(record['pid']), '-o', 'uid=']).strip()
        require(uid == str(os.getuid()), f'{name} belongs to a different user')
        record['command'] = command(['/bin/ps', '-p', str(record['pid']), '-o', 'command=']).strip()
        prefixes = {'redis': 'redis-server ', 'smtp': 'mailpit ', 'mail': 'mailpit ', 'backend': 'puma ', 'vite': 'node '}
        require(record['command'].startswith(prefixes[name]), f'{name} command differs from the admitted runtime')
        if name == 'vite':
            require('node_modules/vite/bin/vite.js' in record['command'], 'Unexpected Node listener')
        record['started_at'] = command(['/bin/ps', '-p', str(record['pid']), '-o', 'lstart=']).strip()
        inventory[name] = record
    if require_ready:
        files = command(['git', 'ls-files', '-z', '--', 'app', 'config', 'lib', 'enterprise', 'db',
                         'Gemfile', 'Gemfile.lock', 'package.json', 'pnpm-lock.yaml']).split('\0')
        newest = max((ROOT / p).stat().st_mtime for p in files + list(RUNTIME_FILES) if p)
        for name in ('backend', 'vite'):
            started = dt.datetime.strptime(inventory[name]['started_at'], '%a %b %d %H:%M:%S %Y').timestamp()
            require(started + PROCESS_TIMESTAMP_RESOLUTION >= newest,
                    'Application/configuration changed since startup; restart the owned dummy services')
    if require_ready:
        inventory['worker'] = worker_identity(wrappers['worker'], parents)
    inventory['supervisor'] = {'pid': supervisor_pid, 'wrappers': wrappers}
    return inventory

def fixture(marker=None):
    args = [sys.executable, MANAGER, 'exec', '--', 'bundle', '_2.5.16_', 'exec',
            'rails', 'runner', SCRIPT_DIR / 'inspect_fixture.rb']
    if marker:
        args.append(marker)
    output = command(args)
    lines = [line[len('VERIFY_FIXTURE='):] for line in output.splitlines() if line.startswith('VERIFY_FIXTURE=')]
    require(len(lines) == 1, 'Fixture inspector did not return its single read-only receipt')
    return json.loads(lines[0])

def doctor(expected_sha=BASE_SHA):
    report = {'ok': False, 'expected_sha': expected_sha, 'runtime': str(ROOT), 'check': 'candidate'}
    try:
        report['actual_sha'] = candidate(expected_sha)
        report['check'] = 'owned-services'
        report['services'] = owned_services()
        report['check'] = 'http'
        require(b'Chatwoot Dummy' in get(SITE + '/app/login'), 'Unexpected application HTML')
        json.loads(get(MAIL + '/api/v1/messages'))
        report['check'] = 'fixture-and-auth'
        report['fixture'] = fixture()
        report.update(ok=True, check='ready')
    except Exception as error:
        report['error'] = str(error)
    return report

def save(directory, name, value):
    (directory / name).write_text(json.dumps(value, indent=2) + '\n')

def manage(action, directory):
    result = subprocess.run([sys.executable, str(MANAGER), action], cwd=ROOT,
                            text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
    with (directory / 'lifecycle.log').open('a') as log:
        log.write(f'\n$ manage.py {action}\n{result.stdout}{result.stderr}\nexit={result.returncode}\n')
    require(result.returncode == 0, f'Dummy {action} failed; inspect lifecycle.log')

def wait_ready():
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while time.monotonic() < deadline:
        try:
            if b'Chatwoot Dummy' in get(SITE + '/app/login'):
                return
        except Exception:
            pass
        time.sleep(POLL_SECONDS)
    raise RuntimeError('Rails readiness timed out')

def browser_environment(config_path, run_id):
    # Supported caller identity, not a browser/runtime/profile override.
    return dict(os.environ, BH_TELEMETRY='0', BU_CALLER='verify-chatwoot-' + run_id,
                VERIFY_CHATWOOT_CONFIG=str(config_path))

def browser_run(directory, config, run_id, mode='journey'):
    config = dict(config, mode=mode)
    config_path = directory / ('browser-config-' + mode + '.json')
    save(directory, config_path.name, config)
    env = browser_environment(config_path, run_id)
    status = subprocess.run([str(BROWSER), 'telemetry', 'status'], env=env,
                            capture_output=True, text=True, timeout=HTTP_TIMEOUT)
    require(status.returncode == 0, 'Could not verify browser telemetry state')
    privacy = json.loads(status.stdout)
    require(privacy.get('enabled') is False and privacy.get('disabled_by_env') is True,
            'Browser telemetry must be disabled for this process')
    save(directory, 'browser-privacy.json', {'enabled': False, 'disabled_by_env': True})
    try:
        with (directory / ('browser-' + mode + '.log')).open('w') as log, (SCRIPT_DIR / 'mail_flow.py').open() as source:
            try:
                result = subprocess.run([str(BROWSER)], stdin=source, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, text=True, timeout=BROWSER_TIMEOUT)
            except subprocess.TimeoutExpired:
                save(directory, 'browser-timeout.json', {'outcome': 'unknown', 'caller': env['BU_CALLER'],
                     'instruction': 'Reconcile the exact marker and target before any repeat; no automatic resend.'})
                raise RuntimeError('Browser timed out; action outcome unknown; log retained')
        require(result.returncode == 0, 'Browser journey refused/failed; inspect browser logs before retrying')
    finally:
        # The same task-owned caller is releasable even if the first client was killed.
        released = subprocess.run([str(BROWSER)], input='print(release_caller())\n', env=env,
                                  capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
        (directory / 'browser-release.log').write_text(released.stdout + released.stderr)
        require(released.returncode == 0, 'Browser release unconfirmed; do not drive again before reconciliation')


def pilot(args):
    candidate(args.expected_sha)
    lock_path = ROOT / 'tmp/dummy/verify-chatwoot.lock'
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another cooperating verification run owns the dummy site')
        was_running = SOCKET.exists()
        if was_running:
            require(args.restart_existing, 'Site already running; --restart-existing explicitly permits the test restart')
            initial = doctor(args.expected_sha)
            require(initial['ok'], f'Initial Doctor refused: {initial.get("error")}')
        else:
            require(not any(listeners(port) for port in PORTS.values()), 'Unowned listener blocks startup')
            initial = {'ok': False, 'check': 'initially-stopped'}
        run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        directory = EVIDENCE / run_id
        directory.mkdir(parents=True, mode=PRIVATE_MODE)
        marker = 'Verify Chatwoot ' + run_id.lower()
        receipt = {'run_id': run_id, 'marker': marker, 'ok': False, 'was_running': was_running,
                   'source_head': command(['git', 'rev-parse', 'HEAD'], cwd=SOURCE).strip(),
                   'candidate': args.expected_sha, 'evidence': str(directory),
                   'claim': 'native synthetic login and outbound UI-reply pilot',
                   'limits': ['seeded inbound, no IMAP round trip', 'no native phone or regression-suite claim',
                              'local provisioned runtime required; no arbitrary-agent isolation',
                              'synthetic sent message and captured email retained; no reset or deletion']}
        shared_before = {str(port): listeners(port) for port in SHARED_PORTS}
        save(directory, 'initial-doctor.json', initial)
        files = list(SCRIPT_DIR.parent.rglob('*.md')) + list(SCRIPT_DIR.glob('*.py')) + list(SCRIPT_DIR.glob('*.rb'))
        save(directory, 'skill-hashes.json', {str(p.relative_to(SCRIPT_DIR.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
        started = False
        lifecycle_touched = False
        config = {'target_id': args.target_id, 'profile': 'Profile 14', 'directory': str(directory),
                  'root': str(ROOT), 'marker': marker, 'fixture': initial.get('fixture') or {}}
        receipt['phase'] = 'browser-preflight'
        save(directory, 'receipt.json', receipt)
        try:
            browser_run(directory, config, run_id, mode='preflight')
            approved = json.loads((directory / 'browser-preflight-result.json').read_text())
            require(approved.get('ok') is True, 'Browser preflight did not prove draft safety')
            config['approved_tab'] = approved['discovered_target']
            receipt['phase'] = 'starting'
            save(directory, 'receipt.json', receipt)
            lifecycle_touched = True
            if was_running:
                manage('stop', directory)
            down = doctor(args.expected_sha)
            save(directory, 'doctor-stopped.json', down)
            require(not down['ok'] and down['check'] == 'owned-services', 'Stopped-site negative control did not fail at ownership')
            started = True  # Cleanup also covers a partial startup failure.
            manage('start', directory)
            wait_ready()
            healthy = doctor(args.expected_sha)
            save(directory, 'doctor-ready.json', healthy)
            require(healthy['ok'], f'Doctor refused: {healthy.get("error")}')
            wrong = doctor(ZERO_SHA)
            save(directory, 'doctor-wrong-candidate.json', wrong)
            require(not wrong['ok'] and wrong['check'] == 'candidate' and 'Candidate mismatch' in wrong.get('error', ''),
                    'Wrong-candidate negative control did not reject the candidate')
            config['fixture'] = healthy['fixture']
            receipt['phase'] = 'browser-journey'
            save(directory, 'receipt.json', receipt)
            browser_run(directory, config, run_id)
            browser_result = json.loads((directory / 'browser-result.json').read_text())
            require(browser_result.get('ok') is True, 'Browser did not confirm the journey')
            stored = fixture(marker)
            save(directory, 'persisted-message.json', stored)
            matches = stored.get('messages', [])
            require(len(matches) == 1 and matches[0]['message_type'] == 'outgoing' and not matches[0]['private']
                    and matches[0]['status'] == 'sent' and matches[0]['content'] == marker
                    and matches[0]['conversation_id'] == healthy['fixture']['conversation_id'],
                    'The exact sent public message is not persisted')
            receipt['ok'] = True
        except BaseException as error:
            receipt['error'] = str(error)
        finally:
            receipt['phase'] = 'cleanup'
            try:
                save(directory, 'receipt.json', receipt)
            except OSError as error:
                receipt.update(ok=False, evidence_error=str(error))
            artifacts_before_cleanup = [p.name for p in directory.iterdir() if p.is_file()]
            try:
                if started and SOCKET.exists():
                    owned_services(require_ready=False)  # Includes owned partial/failed startups.
                    manage('stop', directory)
                receipt['stopped_after_run'] = not SOCKET.exists() and not any(listeners(p) for p in PORTS.values())
                if lifecycle_touched:
                    require(receipt['stopped_after_run'], 'Pilot shutdown was not confirmed')
                else:
                    receipt['initial_state_retained'] = SOCKET.exists() == was_running
                receipt['shared_services_unchanged'] = shared_before == {str(p): listeners(p) for p in SHARED_PORTS}
                require(receipt['shared_services_unchanged'], 'Shared-service listener identity changed')
            except Exception as error:
                receipt['ok'] = False
                receipt['cleanup_error'] = str(error)
            finally:
                if lifecycle_touched and was_running and not SOCKET.exists() and not any(listeners(p) for p in PORTS.values()):
                    try:
                        receipt['phase'] = 'restoring'
                        save(directory, 'receipt.json', receipt)
                        manage('start', directory)
                        wait_ready()
                        restored = doctor(args.expected_sha)
                        save(directory, 'restored-doctor.json', restored)
                        require(restored['ok'], 'Restored instance failed Doctor')
                        receipt['restored_running'] = True
                    except BaseException as error:
                        receipt['ok'] = False
                        receipt['restore_error'] = str(error)
                        try:
                            if SOCKET.exists():
                                owned_services(require_ready=False)
                                manage('stop', directory)
                            receipt['failed_restore_stopped'] = not SOCKET.exists() and not any(listeners(p) for p in PORTS.values())
                        except BaseException as cleanup_error:
                            receipt['restore_cleanup_error'] = str(cleanup_error)
                receipt['phase'] = 'finished'
                save(directory, 'receipt.json', receipt)
        required = ('actions.jsonl', '05-sent.png', 'captured-email.json', 'browser-result.json', 'persisted-message.json')
        receipt['evidence_survived_cleanup'] = all((directory / name).is_file() for name in artifacts_before_cleanup)
        receipt['proof_artifacts_complete'] = all((directory / name).is_file() for name in required)
        receipt['ok'] = receipt['ok'] and receipt['evidence_survived_cleanup'] and receipt['proof_artifacts_complete']
        save(directory, 'receipt.json', receipt)
        print(json.dumps(receipt, indent=2))
        return 0 if receipt['ok'] else FAILURE_EXIT

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'pilot'])
    parser.add_argument('--expected-sha', default=BASE_SHA)
    parser.add_argument('--target-id')
    parser.add_argument('--restart-existing', action='store_true')
    args = parser.parse_args()
    if args.action == 'doctor':
        result = doctor(args.expected_sha)
        print(json.dumps(result, indent=2))
        return 0 if result['ok'] else FAILURE_EXIT
    require(bool(args.target_id), 'pilot requires an exactly discovered --target-id')
    return pilot(args)

def interrupt(signum, frame):
    raise InterruptedError('Interrupted by ' + signal.Signals(signum).name)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        sys.exit(FAILURE_EXIT)
