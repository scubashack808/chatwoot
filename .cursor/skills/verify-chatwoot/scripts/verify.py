#!/usr/bin/env python3
"""Serial, synthetic-only pilot for the already-provisioned native dummy copy."""
import argparse
import base64
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
# The same Mac under both names: macOS renames itself MacBook-Air-2 when another device on the
# network already answers to MacBook-Air (observed 2026-10-27).
HOSTS = ('MacBook-Air.local', 'MacBook-Air-2.local')
DEFAULT_PROFILE = 'Profile 14'
# Profile 7 (A-Team) holds the business logins and is the harness's own working profile.
REFUSED_PROFILES = ('Profile 7',)
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
MAIL_LIST_LIMIT = 500
MAIL_WAIT_SECONDS = 45
UNPROCESSABLE = 422
FORWARD_MARKER = '---------- Forwarded message ---------'
FORWARD_SUBJECT_PREFIX = 'Fwd: '
FORWARD_RECIPIENTS = {'F1_to': ['forward-to-1@chatwoot-dummy.test', 'forward-to-2@chatwoot-dummy.test'],
                      'F1_cc': ['forward-cc@chatwoot-dummy.test'],
                      'F2_to': ['forward-to-3@chatwoot-dummy.test'],
                      'F3_to': ['forward-to-4@chatwoot-dummy.test']}
FORWARD_REPLIER = 'forward-to-1@chatwoot-dummy.test'
FORWARD_REPLY_TEXT = 'Synthetic reply to a forward.'
INVALID_FORWARD_ADDRESS = 'not-an-email'
AGENT_LOGIN = 'agent@chatwoot-dummy.test'
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
    require(socket.gethostname() in HOSTS, 'This pilot is authorized only on ' + ' or '.join(HOSTS))
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

def browser_run(directory, config, run_id, mode='journey', script='mail_flow.py'):
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
        with (directory / ('browser-' + mode + '.log')).open('w') as log, (SCRIPT_DIR / script).open() as source:
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
        config = {'target_id': args.target_id, 'profile': args.profile, 'directory': str(directory),
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

def forward_runner(*args):
    output = command([sys.executable, MANAGER, 'exec', '--', 'bundle', '_2.5.16_', 'exec',
                      'rails', 'runner', SCRIPT_DIR / 'forward_fixture.rb', *args])
    lines = [line[len('VERIFY_FORWARD='):] for line in output.splitlines() if line.startswith('VERIFY_FORWARD=')]
    require(len(lines) == 1, 'Forward fixture runner did not return its single receipt')
    return json.loads(lines[0])

def mail_ids():
    return {m['ID'] for m in json.loads(get(f'{MAIL}/api/v1/messages?limit={MAIL_LIST_LIMIT}'))['messages']}

def mail_message(mail_id):
    message = json.loads(get(f'{MAIL}/api/v1/message/{mail_id}'))
    message['Headers'] = json.loads(get(f'{MAIL}/api/v1/message/{mail_id}/headers'))
    return message

def wait_for_mail(before, markers):
    """New captured mail carrying each marker, keyed by marker."""
    deadline = time.monotonic() + MAIL_WAIT_SECONDS
    found = {}
    while time.monotonic() < deadline:
        for mail_id in mail_ids() - before - {m['ID'] for m in found.values()}:
            message = mail_message(mail_id)
            for marker in markers:
                if marker in message.get('Text', '') or marker in message.get('HTML', ''):
                    found.setdefault(marker, message)
        if all(marker in found for marker in markers):
            return found
        time.sleep(POLL_SECONDS)
    raise RuntimeError('Forward mail not captured for: ' + ', '.join(m for m in markers if m not in found))

def addresses(entries):
    return sorted(entry['Address'] for entry in entries or [])

def captured_files(message):
    files = {}
    for part in (message.get('Attachments') or []) + (message.get('Inline') or []):
        data = get(f"{MAIL}/api/v1/message/{message['ID']}/part/{part['PartID']}")
        files[part['FileName']] = {'byte_size': len(data), 'checksum': base64.b64encode(hashlib.md5(data).digest()).decode()}
    return files

def check(results, name, condition, detail=None):
    results[name] = {'pass': bool(condition), 'detail': detail}

def judge_delivery(results, name, message, fixture, to, cc, subject, source_attachments, source_html_marker=None, marker=None):
    headers = {key.lower() for key in message['Headers']}
    check(results, name + ' subject', message['Subject'] == subject, message['Subject'])
    check(results, name + ' from', message['From']['Address'] == fixture['sender_email'], message['From']['Address'])
    check(results, name + ' recipients', addresses(message['To']) == sorted(to) and addresses(message['Cc']) == sorted(cc)
          and not message.get('Bcc'), {'to': addresses(message['To']), 'cc': addresses(message['Cc'])})
    every = addresses(message['To']) + addresses(message['Cc']) + addresses(message.get('Bcc'))
    check(results, name + ' customer not addressed', fixture['vendor_email'] not in every, every)
    check(results, name + ' new thread', 'in-reply-to' not in headers and 'references' not in headers, sorted(headers))
    body = message.get('HTML', '')
    check(results, name + ' body', marker in body and FORWARD_MARKER in body and
          (source_html_marker is None or source_html_marker in body), {'length': len(body)})
    expected = {a['filename']: {'byte_size': a['byte_size'], 'checksum': a['checksum']} for a in source_attachments}
    actual = captured_files(message)
    check(results, name + ' attachments', actual == expected, {'expected': expected, 'actual': actual})

def judge_stored(results, name, stored, source, to, cc, subject):
    check(results, name + ' persisted once', len(stored) == 1, [m['id'] for m in stored])
    if len(stored) != 1:
        return None
    message = stored[0]
    check(results, name + ' persisted forward', message['message_type'] == 'outgoing' and not message['private']
          and message['forwarded_message_id'] == source['id'] and message['to_emails'] == to
          and (message['cc_emails'] or []) == cc and message['subject'] == subject and message['html_has_forward_marker'],
          {k: message[k] for k in ('id', 'status', 'forwarded_message_id', 'to_emails', 'cc_emails', 'subject')})
    check(results, name + ' blobs reused', sorted(a['blob_id'] for a in message['attachments'])
          == sorted(a['blob_id'] for a in source['attachments']), message['attachments'])
    return message

def forward_run(args):
    candidate(args.expected_sha)
    lock_path = ROOT / 'tmp/dummy/verify-chatwoot.lock'
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another cooperating verification run owns the dummy site')
        initial = doctor(args.expected_sha)
        require(initial['ok'], f'Doctor refused; start the dummy on the candidate first: {initial.get("error")}')
        run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        directory = EVIDENCE / ('forward-' + run_id)
        directory.mkdir(parents=True, mode=PRIVATE_MODE)
        tag = run_id.lower()
        markers = {key: f'Verify Forward {tag} {key}' for key in ('F1', 'F2', 'F3')}
        receipt = {'run_id': run_id, 'markers': markers, 'ok': False, 'candidate': args.expected_sha,
                   'source_head': command(['git', 'rev-parse', 'HEAD'], cwd=SOURCE).strip(), 'evidence': str(directory),
                   'claim': 'native synthetic email-forward journey: UI, captured delivery, persistence and inbound threading',
                   'limits': ['local SMTP capture, no live mail', 'IMAP reply fed to the mailbox in-process (IMAP disabled)',
                              'synthetic forward conversation, forwards and captures retained; no reset or deletion']}
        save(directory, 'initial-doctor.json', initial)
        files = list(SCRIPT_DIR.parent.rglob('*.md')) + list(SCRIPT_DIR.glob('*.py')) + list(SCRIPT_DIR.glob('*.rb'))
        save(directory, 'skill-hashes.json', {str(p.relative_to(SCRIPT_DIR.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
        results = {}
        try:
            fixture = forward_runner('seed', tag)
            save(directory, 'forward-fixture.json', fixture)
            config = {'target_id': args.target_id, 'profile': 'Profile 14', 'directory': str(directory), 'root': str(ROOT),
                      'forward_fixture': fixture, 'markers': markers, 'recipients': FORWARD_RECIPIENTS}
            before = mail_ids()
            receipt['phase'] = 'browser-forward'
            save(directory, 'receipt.json', receipt)
            browser_run(directory, config, run_id, mode='forward', script='forward_flow.py')
            ui = json.loads((directory / 'forward-browser-forward.json').read_text())
            gating = ui['gating']
            check(results, 'F5 menu gating', gating['incoming_offers_forward'] and gating['outgoing_offers_forward']
                  and not gating['private_note_offers_forward'], gating)
            check(results, 'F4 validation refused', ui['F1'].get('empty_to_refused') and ui['F1'].get('invalid_to_refused'), ui['F1'])
            for key in ('F1', 'F2', 'F3'):
                check(results, key + ' rendered in thread', ui[key].get('rendered_subject') and ui[key].get('rendered_forward_block'), ui[key])
            check(results, 'F1 source body visible in thread', ui['F1'].get('rendered_source_body'), ui['F1'])
            captured = wait_for_mail(before, list(markers.values()))
            save(directory, 'forward-captured.json', captured)
            # Seeding delivers its own agent reply and notifications asynchronously; count only mail
            # addressed to a forward recipient or to the refused address.
            watched = {address for addresses in FORWARD_RECIPIENTS.values() for address in addresses} | {INVALID_FORWARD_ADDRESS}
            forward_mail = [mail_id for mail_id in sorted(mail_ids() - before)
                            if watched & set(addresses((message := mail_message(mail_id))['To']) + addresses(message['Cc']))]
            check(results, 'F4 nothing extra sent', len(forward_mail) == len(markers), forward_mail)
            html, reply, plain = fixture['html_source'], fixture['outgoing_reply'], fixture['plain_source']
            judge_delivery(results, 'F1', captured[markers['F1']], fixture, FORWARD_RECIPIENTS['F1_to'], FORWARD_RECIPIENTS['F1_cc'],
                           FORWARD_SUBJECT_PREFIX + html['subject'], html['attachments'], fixture['html_marker'], markers['F1'])
            judge_delivery(results, 'F2', captured[markers['F2']], fixture, FORWARD_RECIPIENTS['F2_to'], [],
                           FORWARD_SUBJECT_PREFIX + 'Synthetic invoice 42', [], marker=markers['F2'])
            f2_body = captured[markers['F2']].get('HTML', '')
            check(results, "F2 forwarded agent reply attributed to the inbox", f"&lt;{fixture['sender_email']}&gt;" in f2_body
                  and AGENT_LOGIN not in f2_body, {'length': len(f2_body)})
            judge_delivery(results, 'F3', captured[markers['F3']], fixture, FORWARD_RECIPIENTS['F3_to'], [],
                           FORWARD_SUBJECT_PREFIX + plain['subject'], [], marker=markers['F3'])
            stored = forward_runner('inspect', tag, *markers.values())
            save(directory, 'forward-persisted.json', stored)
            f1 = judge_stored(results, 'F1', stored['markers'][markers['F1']], html, FORWARD_RECIPIENTS['F1_to'],
                              FORWARD_RECIPIENTS['F1_cc'], FORWARD_SUBJECT_PREFIX + html['subject'])
            judge_stored(results, 'F2', stored['markers'][markers['F2']], reply, FORWARD_RECIPIENTS['F2_to'], [],
                         FORWARD_SUBJECT_PREFIX + 'Synthetic invoice 42')
            f3 = judge_stored(results, 'F3', stored['markers'][markers['F3']], plain, FORWARD_RECIPIENTS['F3_to'], [],
                              FORWARD_SUBJECT_PREFIX + plain['subject'])
            require(f1 and f3, 'Forwards were not persisted; later scenarios need them')

            receipt['phase'] = 'retry'
            save(directory, 'receipt.json', receipt)
            failed = forward_runner('fail', tag, str(f3['id']))
            save(directory, 'forward-failed.json', failed)
            check(results, 'F6 marked failed', failed['status'] == 'failed', failed['status'])
            before_retry = mail_ids()
            browser_run(directory, dict(config, failed_forward_id=f3['id']), run_id, mode='retry', script='forward_flow.py')
            retry_ui = json.loads((directory / 'forward-browser-retry.json').read_text())
            check(results, 'F5 failed message offers no forward', retry_ui['failed_offers_forward'] is False, retry_ui)
            forward_addresses = {address for addresses in FORWARD_RECIPIENTS.values() for address in addresses}
            composer = retry_ui.get('composer_recipients') or []
            check(results, 'F10 reply composer not addressed to forward recipients', bool(composer) and
                  not any(address.strip() in forward_addresses for row in composer for address in row['value'].split(',')), composer)
            retried = wait_for_mail(before_retry, [markers['F3']])[markers['F3']]
            save(directory, 'forward-retry-captured.json', retried)
            check(results, 'F6 retry recipients', addresses(retried['To']) == FORWARD_RECIPIENTS['F3_to'] and not retried['Cc'],
                  addresses(retried['To']))
            after_retry = forward_runner('inspect', tag, markers['F3'])['markers'][markers['F3']]
            check(results, 'F6 retried forward kept its forward', len(after_retry) == 1 and after_retry[0]['external_error'] is None
                  and after_retry[0]['to_emails'] == FORWARD_RECIPIENTS['F3_to'] and after_retry[0]['forwarded_message_id'] == plain['id'],
                  after_retry)

            receipt['phase'] = 'server-checks'
            save(directory, 'receipt.json', receipt)
            reply_result = forward_runner('reply', tag, str(f1['id']))
            save(directory, 'forward-reply.json', reply_result)
            check(results, 'F7 reply goes to the inbox address', reply_result['reply_address'] == fixture['sender_email'], reply_result)
            check(results, 'F7 ActionMailbox threading does not claim it', reply_result['action_mailbox_conversation_id'] is None, reply_result)
            check(results, 'F7 reply opens a new conversation',
                  reply_result['after']['conversations'] == reply_result['before']['conversations'] + 1
                  and reply_result['after']['source_messages'] == reply_result['before']['source_messages']
                  and reply_result['reply_conversation_id'] not in (None, reply_result['source_conversation_id'])
                  and reply_result['reply_contact_email'] == FORWARD_REPLIER
                  and FORWARD_REPLY_TEXT in (reply_result['reply_content'] or ''), reply_result)
            rerender = forward_runner('rerender', tag, str(f1['id']))
            save(directory, 'forward-rerender.json', rerender)
            sent = captured[markers['F1']]
            squash = lambda text: re.sub(r'\s+', '', text or '')
            check(results, 'F8 Sent copy matches delivery', rerender['subject'] == sent['Subject']
                  and sorted(rerender['to']) == addresses(sent['To']) and sorted(rerender['cc'] or []) == addresses(sent['Cc'])
                  and rerender['message_id'] == sent['MessageID'] and not rerender['in_reply_to'] and not rerender['references']
                  and squash(rerender['html']) == squash(sent['HTML']),
                  {k: rerender[k] for k in ('subject', 'to', 'cc', 'message_id', 'in_reply_to', 'references')})
            before_scope = mail_ids()
            scope = forward_runner('scope', tag)
            save(directory, 'forward-scope.json', scope)
            time.sleep(POLL_SECONDS)
            check(results, 'F9 foreign source refused', scope['status'] == UNPROCESSABLE and scope['messages_created'] == 0
                  and "Couldn't find Message" in (scope.get('error') or '')
                  and mail_ids() == before_scope, scope)
            receipt['ok'] = all(result['pass'] for result in results.values())
        except BaseException as error:
            receipt['error'] = str(error)
        finally:
            receipt['phase'] = 'finished'
            receipt['scenarios'] = results
            receipt['failed'] = [name for name, result in results.items() if not result['pass']]
            receipt['ok'] = receipt['ok'] and not receipt['failed']
            save(directory, 'receipt.json', receipt)
        print(json.dumps(receipt, indent=2))
        return 0 if receipt['ok'] else FAILURE_EXIT

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'pilot', 'forward'])
    parser.add_argument('--expected-sha', default=BASE_SHA)
    parser.add_argument('--target-id')
    parser.add_argument('--restart-existing', action='store_true')
    parser.add_argument('--profile', default=DEFAULT_PROFILE,
                        help='governed Brave profile directory holding the dummy tab (default: CC01, Profile 14)')
    args = parser.parse_args()
    require(re.fullmatch(r'Profile [0-9]+', args.profile) and args.profile not in REFUSED_PROFILES,
            'Profile must be a governed profile directory such as "Profile 14", never ' + ', '.join(REFUSED_PROFILES))
    if args.action == 'doctor':
        result = doctor(args.expected_sha)
        print(json.dumps(result, indent=2))
        return 0 if result['ok'] else FAILURE_EXIT
    require(bool(args.target_id), args.action + ' requires an exactly discovered --target-id')
    return forward_run(args) if args.action == 'forward' else pilot(args)

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
