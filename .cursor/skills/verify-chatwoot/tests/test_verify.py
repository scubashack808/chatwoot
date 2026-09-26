#!/usr/bin/env python3
"""Pure tests: no real browser, service, network, database or credential access."""
import ast
import contextlib
import io
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import verify

FLOW_TREE = ast.parse((verify.SCRIPT_DIR / 'mail_flow.py').read_text())
DRAFT_NODES = [node for node in FLOW_TREE.body if
               (isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id in ('SITE', 'LOGIN_EMAIL', 'LOGIN_URL') for target in node.targets)) or
               (isinstance(node, ast.FunctionDef) and node.name in ('reject_draft_state', 'guard_existing_drafts'))]
HEADER_VALUES = {'FROM': 'support@chatwoot-dummy.test', 'TO': 'customer@chatwoot-dummy.test', 'CC': '', 'BCC': ''}
AGENT_EMAIL = 'agent@chatwoot-dummy.test'
BLOCKING_DRAFT_CASES = [{'headers': {'BCC': HEADER_VALUES['TO']}}, {'headers': {'CC': HEADER_VALUES['FROM']}}]

def address_draft_states(cases):
    clear = dict.fromkeys(('stored_drafts', 'editor_draft', 'attachments', 'unexpected_inputs'), False)
    driver = MagicMock(return_value=json.dumps(clear))
    env = {'json': json, 'js': driver, 'record': MagicMock()}
    exec(compile(ast.Module(body=DRAFT_NODES, type_ignores=[]), 'mail_flow.py', 'exec'), env)
    env['guard_existing_drafts']()
    component = verify.SOURCE / 'app/javascript/dashboard/components/widgets/conversation/ReplyEmailHead.vue'
    template = component.read_text().split('<template>', 1)[1].rsplit('</template>', 1)[0]
    reply_box = (component.parent / 'ReplyBox.vue').read_text()
    assert 'class="reply-box"' in reply_box and 'showReplyHead && isDefaultEditorMode' in reply_box
    locale = json.loads((verify.SOURCE / 'app/javascript/dashboard/i18n/locale/en/conversation.json').read_text())
    node = r'''
const {JSDOM} = require('jsdom');
const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const results = input.cases.map(test => {
  const headers = test.without_headers ? '' : input.template;
  const html = test.composer === false ? '' : '<div class="reply-box"><div class="reply-box__top">' + headers + '</div></div>';
  const dom = new JSDOM(html, {url: test.url || input.origin + '/app/accounts/1/conversations/3'});
  const {document, localStorage, location} = dom.window;
  Object.defineProperty(dom.window.HTMLElement.prototype, 'innerText', {get() {return this.textContent;}});
  dom.window.HTMLElement.prototype.checkVisibility = function() {return this.dataset.hidden !== 'true';};
  // Resolve labels from the actual Vue template and pinned English locale.
  for (const label of document.querySelectorAll('.input-group-label')) {
    const key = label.textContent.split("'")[1];
    label.textContent = key.split('.').reduce((value, part) => value[part], input.locale);
  }
  // WootInput renders an input; retain the real mount and label classes.
  for (const component of document.querySelectorAll('woot-input')) {
    const field = document.createElement('input');
    field.type = component.getAttribute('type');
    component.replaceWith(field);
  }
  const values = Object.assign({}, input.values, test.headers || {});
  for (const group of document.querySelectorAll('.input-group')) {
    const label = group.querySelector('.input-group-label').textContent.trim().toUpperCase();
    if ((test.omit_headers || []).includes(label)) {group.remove(); continue;}
    const field = group.querySelector('input,select');
    if (field.tagName === 'SELECT') field.replaceChildren(new dom.window.Option(values[label], values[label]));
    field.value = values[label];
    if ((test.hidden_headers || []).includes(label)) field.dataset.hidden = 'true';
  }
  document.body.insertAdjacentHTML('beforeend', test.extra_html || '');
  const state = JSON.parse(eval(input.expression));
  dom.window.close();
  return state;
});
process.stdout.write(JSON.stringify(results));
'''
    result = subprocess.run(['node', '-e', node], cwd=verify.ROOT,
                            input=json.dumps({'template': template, 'locale': locale, 'expression': driver.call_args[0][0], 'origin': verify.SITE, 'values': HEADER_VALUES, 'cases': cases}),
                            capture_output=True, text=True, timeout=verify.HTTP_TIMEOUT, check=True)
    return json.loads(result.stdout)

def rejected_browser_state(state, mode='journey'):
    tab = {'targetId': 'owned-test', 'title': 'Chatwoot Dummy', 'url': verify.SITE + '/app/login', 'profile': 'Profile 14', 'ownership': 'unowned'}
    main = next(node for node in FLOW_TREE.body if isinstance(node, ast.Try))
    with tempfile.TemporaryDirectory() as temp:
        env = {'json': json, 're': re, 'CONFIG': {'target_id': 'owned-test', 'mode': mode}, 'DASHBOARD': 'unused', 'CONVERSATION': 'unused', 'OUT': Path(temp), 'result': {'ok': False}, 'adopted': False, 'PreflightComplete': type('PreflightComplete', (Exception,), {}), 'discover_tabs': MagicMock(return_value=[tab]), 'adopt_tab': MagicMock(), 'record': MagicMock(), 'js': MagicMock(return_value=json.dumps(state)), 'snapshot': MagicMock(), 'release_caller': MagicMock()}
        env.update({name: MagicMock() for name in ('cdp', 'click_control', 'fill_login', 'fill_input', 'press_key')})
        exec(compile(ast.Module(body=DRAFT_NODES + [main], type_ignores=[]), 'mail_flow.py', 'exec'), env)
    return env

class DoctorTests(unittest.TestCase):
    def test_wrong_candidate_precedes_services(self):
        with patch.object(verify, 'candidate', side_effect=RuntimeError('Candidate mismatch')), patch.object(verify, 'owned_services') as services:
            result = verify.doctor(verify.ZERO_SHA)
        self.assertFalse(result['ok']); self.assertEqual(result['check'], 'candidate'); services.assert_not_called()

    def test_stopped_site_precedes_http_and_database(self):
        with patch.object(verify, 'candidate', return_value=verify.BASE_SHA), patch.object(verify, 'owned_services', side_effect=RuntimeError('down')), patch.object(verify, 'get') as http, patch.object(verify, 'fixture') as fixture:
            result = verify.doctor()
        self.assertFalse(result['ok']); self.assertEqual(result['check'], 'owned-services')
        http.assert_not_called(); fixture.assert_not_called()

    def test_fixture_refusal_cannot_pass(self):
        with patch.object(verify, 'candidate', return_value=verify.BASE_SHA), patch.object(verify, 'owned_services', return_value={}), patch.object(verify, 'get', side_effect=[b'Chatwoot Dummy', b'{}']), patch.object(verify, 'fixture', side_effect=RuntimeError('unsafe fixture')):
            result = verify.doctor()
        self.assertFalse(result['ok']); self.assertEqual(result['check'], 'fixture-and-auth')

    def test_all_ready_gates_pass(self):
        with patch.object(verify, 'candidate', return_value=verify.BASE_SHA), patch.object(verify, 'owned_services', return_value={}), patch.object(verify, 'get', side_effect=[b'Chatwoot Dummy', b'{}']), patch.object(verify, 'fixture', return_value={'authentication_valid': True}):
            self.assertTrue(verify.doctor()['ok'])

    def test_external_urls_refused_before_network(self):
        with patch('urllib.request.build_opener') as opener:
            for url in ('https://example.test/', 'http://127.0.0.1:3001.evil.test/', 'http://127.0.0.1:6379/'):
                with self.subTest(url=url), self.assertRaises(ValueError): verify.get(url)
        opener.assert_not_called()

    def test_redirect_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'redirected'):
            verify.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.test/')

class OwnershipTests(unittest.TestCase):
    def test_ancestry(self):
        parents = {30: 20, 20: 10, 10: 1, 40: 1}
        self.assertTrue(verify.is_descendant(30, 10, parents))
        self.assertFalse(verify.is_descendant(40, 10, parents))
        self.assertFalse(verify.is_descendant(99, 10, parents))
        self.assertFalse(verify.is_descendant(20, 99, {20: 30, 30: 20}))

    def test_partial_startup_inspection_does_not_require_healthy_services(self):
        sock = MagicMock(); sock.exists.return_value = True; sock.lstat.return_value = SimpleNamespace(st_mode=stat.S_IFSOCK)
        with patch.object(verify, 'SOCKET', sock), patch.object(verify, 'supervisor_identity', return_value=1), patch.object(verify, 'process_parents', return_value={}), patch.object(verify, 'command', return_value='backend 10 stopped'), patch.object(verify, 'listeners', return_value=[]):
            self.assertEqual(verify.owned_services(require_ready=False)['supervisor']['pid'], 1)
            with self.assertRaisesRegex(RuntimeError, 'not running'): verify.owned_services()

    def test_unrelated_listener_rejected_even_with_same_directory(self):
        sock = MagicMock(); sock.exists.return_value = True; sock.lstat.return_value = SimpleNamespace(st_mode=stat.S_IFSOCK)
        with patch.object(verify, 'SOCKET', sock), patch.object(verify, 'supervisor_identity', return_value=1), patch.object(verify, 'process_parents', return_value={10: 1, 20: 2}), patch.object(verify, 'command', return_value='redis 10 running'), patch.object(verify, 'listeners', return_value=[{'pid': 20, 'addresses': ['127.0.0.1:6380']}]):
            with self.assertRaisesRegex(RuntimeError, 'not a descendant'): verify.owned_services(require_ready=False)

    def test_substituted_worker_rejected(self):
        with patch.object(verify, 'command', return_value='sleep 60'):
            with self.assertRaisesRegex(RuntimeError, 'Sidekiq'): verify.worker_identity(10, {10: 1, 20: 10})

class BrowserTests(unittest.TestCase):
    def test_telemetry_disabled_and_caller_stable(self):
        with patch.dict(os.environ, {'BH_TELEMETRY': '1'}):
            env = verify.browser_environment(Path('/tmp/config'), 'one-run')
        self.assertEqual(env['BH_TELEMETRY'], '0')
        self.assertEqual(env['BU_CALLER'], 'verify-chatwoot-one-run')

    def test_timeout_preserves_output_and_releases_same_caller(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp); environments = []
            def run(args, **kwargs):
                environments.append(kwargs['env'])
                if args[-1] == 'status':
                    return SimpleNamespace(returncode=0, stdout='{"enabled":false,"disabled_by_env":true}')
                if 'stdin' in kwargs:
                    kwargs['stdout'].write('partial browser output\n')
                    raise subprocess.TimeoutExpired(args, verify.BROWSER_TIMEOUT)
                return SimpleNamespace(returncode=0, stdout='True\n', stderr='')
            with patch.object(verify.subprocess, 'run', side_effect=run):
                with self.assertRaisesRegex(RuntimeError, 'outcome unknown'): verify.browser_run(out, {}, 'timeout-run')
            self.assertIn('partial browser output', (out / 'browser-journey.log').read_text())
            self.assertTrue((out / 'browser-timeout.json').is_file())
            self.assertEqual(len(environments), 3)
            self.assertEqual({e['BU_CALLER'] for e in environments}, {'verify-chatwoot-timeout-run'})
            self.assertTrue(all(e['BH_TELEMETRY'] == '0' for e in environments))

    def test_enabled_telemetry_prevents_browser_launch(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(verify.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{"enabled":true,"disabled_by_env":false}')) as run:
            with self.assertRaisesRegex(RuntimeError, 'telemetry must be disabled'): verify.browser_run(Path(temp), {}, 'refused')
            self.assertEqual(run.call_count, 1)

    def test_native_boolean_wait(self):
        tree = ast.parse((verify.SCRIPT_DIR / 'mail_flow.py').read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'wait_until')
        driver = MagicMock(return_value=True)
        clock = SimpleNamespace(monotonic=MagicMock(side_effect=[0, 0, 2]), sleep=MagicMock())
        env = {'js': driver, 'time': clock, 'WAIT_SECONDS': 1, 'POLL_SECONDS': 0.5}
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'mail_flow.py', 'exec'), env)
        env['wait_until']('true', 'Boolean'); driver.assert_called_once_with('true'); clock.sleep.assert_not_called()

    def test_draft_blocks_every_navigation_logout_and_input(self):
        tree = ast.parse((verify.SCRIPT_DIR / 'mail_flow.py').read_text())
        functions = DRAFT_NODES
        main = next(n for n in tree.body if isinstance(n, ast.Try))
        site = 'http://127.0.0.1:3001'
        tab = {'targetId': 'owned-test', 'title': 'Chatwoot Dummy', 'url': site + '/app/login', 'profile': 'Profile 14', 'ownership': 'unowned'}
        with tempfile.TemporaryDirectory() as temp:
            for reason in ('stored_drafts', 'editor_draft', 'attachments', 'unexpected_inputs'):
                state = dict.fromkeys(('stored_drafts', 'editor_draft', 'attachments', 'unexpected_inputs'), False); state[reason] = True
                env = {'json': json, 'CONFIG': {'target_id': 'owned-test', 'mode': 'journey'}, 'SITE': site, 'DASHBOARD': 'unused', 'CONVERSATION': 'unused', 'OUT': Path(temp), 'result': {'ok': False}, 'adopted': False, 'PreflightComplete': type('PreflightComplete', (Exception,), {}), 'discover_tabs': MagicMock(return_value=[tab]), 'adopt_tab': MagicMock(), 'record': MagicMock(), 'js': MagicMock(return_value=json.dumps(state)), 'snapshot': MagicMock(), 'release_caller': MagicMock()}
                inputs = ('cdp', 'click_control', 'fill_login', 'fill_input', 'press_key')
                env.update({name: MagicMock() for name in inputs})
                exec(compile(ast.Module(body=functions + [main], type_ignores=[]), 'mail_flow.py', 'exec'), env)
                self.assertFalse(env['result']['ok'])
                self.assertIn('Existing draft', env['result']['error'])
                for name in inputs: env[name].assert_not_called()
                env['release_caller'].assert_called_once()
                self.assertIn("localStorage.getItem('draftMessages')", env['js'].call_args[0][0])

    def test_field_aware_address_drafts_block_browser_mutation(self):
        for state in address_draft_states(BLOCKING_DRAFT_CASES):
            with self.subTest(state=state):
                self.assertTrue(state['unexpected_inputs'])
                env = rejected_browser_state(state)
                self.assertFalse(env['result']['ok'])
                self.assertIn('Existing draft', env['result']['error'])
                for name in ('cdp', 'click_control', 'fill_login', 'fill_input', 'press_key'):
                    env[name].assert_not_called()
                env['release_caller'].assert_called_once()

    def test_evidence_write_failure_still_releases_browser(self):
        tree = ast.parse((verify.SCRIPT_DIR / 'mail_flow.py').read_text())
        main = next(n for n in tree.body if isinstance(n, ast.Try))
        out = MagicMock(); out.__truediv__.return_value.write_text.side_effect = OSError('disk full')
        release = MagicMock()
        env = {'OUT': out, 'CONFIG': {'mode': 'journey'}, 'json': json, 'result': {'ok': False}, 'adopted': True, 'release_caller': release}
        with self.assertRaises(OSError): exec(compile(ast.Module(body=main.finalbody, type_ignores=[]), 'mail_flow.py', 'exec'), env)
        release.assert_called_once()

class AttachmentDOMTests(unittest.TestCase):
    def test_pasted_file_preview_is_detected_without_body_or_file_input(self):
        tree = ast.parse((verify.SCRIPT_DIR / 'mail_flow.py').read_text())
        functions = DRAFT_NODES
        clear = dict.fromkeys(('stored_drafts', 'editor_draft', 'attachments', 'unexpected_inputs'), False)
        driver = MagicMock(return_value=json.dumps(clear))
        env = {'json': json, 'js': driver, 'record': MagicMock()}
        exec(compile(ast.Module(body=functions, type_ignores=[]), 'mail_flow.py', 'exec'), env)
        env['guard_existing_drafts']()
        expression = driver.call_args[0][0]
        component = verify.SOURCE / 'app/javascript/dashboard/components/widgets/AttachmentsPreview.vue'
        template = component.read_text().split('<template>', 1)[1].rsplit('</template>', 1)[0]
        node = r'''
const {JSDOM} = require('jsdom');
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const dom = new JSDOM(input.html, {url: input.origin});
// JSDOM does not lay out elements. These shims affect visibility/text only;
// querySelector uses the actual DOM and the unmodified Vue-template classes.
Object.defineProperty(dom.window.HTMLElement.prototype, 'innerText', {get() {return this.textContent;}});
dom.window.HTMLElement.prototype.checkVisibility = () => true;
const document = dom.window.document;
const localStorage = dom.window.localStorage;
process.stdout.write(eval(input.expression));
dom.window.close();
'''
        for has_attachment in (False, True):
            html = '<div class="reply-box__top"><div contenteditable="true"></div>' + (template if has_attachment else '') + '</div>'
            result = subprocess.run(['node', '-e', node], cwd=verify.ROOT,
                                    input=json.dumps({'html': html, 'expression': expression, 'origin': verify.SITE}),
                                    capture_output=True, text=True, timeout=verify.HTTP_TIMEOUT, check=True)
            observed = json.loads(result.stdout)
            self.assertEqual(observed['attachments'], has_attachment)
            for key in ('stored_drafts', 'editor_draft', 'unexpected_inputs'): self.assertFalse(observed[key])
            if has_attachment:
                with self.assertRaisesRegex(RuntimeError, 'Existing draft'): env['reject_draft_state'](observed)
            else: env['reject_draft_state'](observed)

class AddressDOMTests(unittest.TestCase):
    def test_only_field_specific_baseline_values_are_allowed(self):
        cases = [{}, {'omit_headers': ['FROM', 'TO', 'BCC']}, {'headers': {'CC': HEADER_VALUES['TO']}},
                 {'composer': False, 'url': verify.SITE + '/app/login', 'extra_html': '<input name="email_address" value="' + AGENT_EMAIL + '">'}]
        for state in address_draft_states(cases):
            self.assertFalse(any(state.values()), state)

    def test_wrong_or_cleared_address_fields_are_refused(self):
        cases = BLOCKING_DRAFT_CASES + [{'headers': values} for values in
                 ({'BCC': HEADER_VALUES['FROM']}, {'BCC': AGENT_EMAIL}, {'CC': AGENT_EMAIL},
                  {'TO': HEADER_VALUES['FROM']}, {'FROM': HEADER_VALUES['TO']}, {'TO': ''}, {'FROM': ''})]
        for state in address_draft_states(cases):
            self.assertTrue(state['unexpected_inputs'], state)
            for key in ('stored_drafts', 'editor_draft', 'attachments'): self.assertFalse(state[key])

    def test_fixture_addresses_in_other_fields_are_refused(self):
        cases = [{'extra_html': '<input value="' + value + '">'} for value in (HEADER_VALUES['TO'], HEADER_VALUES['FROM'], AGENT_EMAIL)]
        cases += [{'extra_html': '<input name="email_address" value="' + AGENT_EMAIL + '">'},
                  {'extra_html': '<div class="input-group"><label class="input-group-label">TO</label><input value="' + HEADER_VALUES['TO'] + '"></div>'}]
        for state in address_draft_states(cases): self.assertTrue(state['unexpected_inputs'], state)

    def test_hidden_headers_and_uninspectable_composers_are_refused(self):
        cases = [{'headers': {'BCC': HEADER_VALUES['TO']}, 'hidden_headers': ['BCC']},
                 {'headers': {'CC': HEADER_VALUES['FROM']}, 'hidden_headers': ['CC']},
                 {'without_headers': True}]
        for state in address_draft_states(cases): self.assertTrue(state['unexpected_inputs'], state)

class LifecycleTests(unittest.TestCase):
    def exercise(self, failure, draft_state=None):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'tmp/dummy').mkdir(parents=True); sock = root / 'socket'; sock.touch()
            actions = []; current = {}
            fixture = {'conversation_id': 9, 'account_id': 1, 'display_id': 3}
            def manage(action, directory):
                actions.append(action)
                if action == 'stop': sock.unlink()
                else:
                    sock.touch()
                    if (failure == 'start' and actions.count('start') == 1) or (failure == 'restore-start' and actions.count('start') == 2): raise RuntimeError('simulated startup failure')
            def browser(directory, config, run_id, mode='journey'):
                if failure == 'preflight': raise RuntimeError('Existing draft')
                if failure == 'address-preflight':
                    blocked = rejected_browser_state(draft_state, mode='preflight')
                    if not blocked['result']['ok']: raise RuntimeError(blocked['result']['error'])
                if mode == 'preflight':
                    (directory / 'browser-preflight-result.json').write_text(json.dumps({'ok': True, 'discovered_target': {'targetId': 'test', 'profile': 'Profile 14'}}))
                    return
                current.update(config)
                (directory / 'browser-result.json').write_text('{"ok":true}')
                for name in ('actions.jsonl', '05-sent.png', 'captured-email.json'): (directory / name).write_text('synthetic')
            calls = iter([{'ok': True, 'fixture': fixture}, {'ok': False, 'check': 'owned-services'}, {'ok': True, 'fixture': fixture}, {'ok': False, 'check': 'candidate', 'error': 'Candidate mismatch'}, {'ok': failure != 'restore-doctor'}])
            def stored(marker):
                content = marker + ' unwanted suffix' if failure == 'content' else marker
                return {'messages': [{'message_type': 'outgoing', 'private': False, 'status': 'sent', 'content': content, 'conversation_id': 9}]}
            with contextlib.ExitStack() as stack:
                for name, value in {'ROOT': root, 'SOCKET': sock, 'EVIDENCE': root / 'evidence'}.items(): stack.enter_context(patch.object(verify, name, value))
                stack.enter_context(patch.object(verify, 'candidate'))
                stack.enter_context(patch.object(verify, 'listeners', return_value=[]))
                stack.enter_context(patch.object(verify, 'command', return_value=verify.BASE_SHA))
                stack.enter_context(patch.object(verify, 'doctor', side_effect=lambda *a: next(calls)))
                stack.enter_context(patch.object(verify, 'manage', side_effect=manage))
                stack.enter_context(patch.object(verify, 'browser_run', side_effect=browser))
                stack.enter_context(patch.object(verify, 'fixture', side_effect=stored))
                stack.enter_context(patch.object(verify, 'wait_ready'))
                stack.enter_context(patch.object(verify, 'owned_services'))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                code = verify.pilot(SimpleNamespace(expected_sha=verify.BASE_SHA, restart_existing=True, target_id='test'))
            receipt = json.loads(next((root / 'evidence').glob('*/receipt.json')).read_text())
            return code, actions, receipt, sock.exists()

    def test_preflight_refusal_leaves_services_untouched(self):
        code, actions, receipt, running = self.exercise('preflight')
        self.assertEqual(code, verify.FAILURE_EXIT); self.assertEqual(actions, []); self.assertTrue(running); self.assertTrue(receipt['initial_state_retained'])

    def test_field_aware_address_drafts_leave_services_untouched(self):
        for state in address_draft_states(BLOCKING_DRAFT_CASES):
            with self.subTest(state=state):
                code, actions, receipt, running = self.exercise('address-preflight', state)
                self.assertEqual(code, verify.FAILURE_EXIT)
                self.assertEqual(actions, [])
                self.assertTrue(running)
                self.assertTrue(receipt['initial_state_retained'])
                self.assertIn('Existing draft', receipt['error'])

    def test_partial_first_start_cleaned(self):
        code, actions, receipt, running = self.exercise('start')
        self.assertEqual(code, verify.FAILURE_EXIT); self.assertEqual(actions, ['stop', 'start', 'stop', 'start']); self.assertTrue(running)

    def test_partial_restore_start_cleaned(self):
        code, actions, receipt, running = self.exercise('restore-start')
        self.assertEqual(code, verify.FAILURE_EXIT); self.assertFalse(running); self.assertEqual(actions[-2:], ['start', 'stop']); self.assertTrue(receipt['failed_restore_stopped'])

    def test_restore_doctor_refusal_cleaned(self):
        code, actions, receipt, running = self.exercise('restore-doctor')
        self.assertEqual(code, verify.FAILURE_EXIT); self.assertFalse(running); self.assertTrue(receipt['failed_restore_stopped'])

    def test_extra_persisted_content_fails(self):
        code, actions, receipt, running = self.exercise('content')
        self.assertEqual(code, verify.FAILURE_EXIT); self.assertIn('exact sent public message', receipt['error']); self.assertTrue(running)

    def test_success_restores_running_state_and_preserves_proof(self):
        code, actions, receipt, running = self.exercise('success')
        self.assertEqual(code, 0); self.assertTrue(running); self.assertTrue(receipt['evidence_survived_cleanup']); self.assertTrue(receipt['proof_artifacts_complete'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
