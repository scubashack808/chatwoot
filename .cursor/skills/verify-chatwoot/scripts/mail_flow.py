#!/usr/bin/env browser-harness
"""Executed by browser-harness on stdin; never import a second browser driver."""
import datetime as dt
import json
import os
import re
from browser_harness import telemetry
from pathlib import Path
import time
import urllib.request

if os.environ.get('BH_TELEMETRY') != '0' or telemetry.is_enabled():
    raise RuntimeError('Refusing browser work while telemetry is enabled')

CONFIG = json.loads(Path(os.environ['VERIFY_CHATWOOT_CONFIG']).read_text())
OUT = Path(CONFIG['directory'])
ROOT = Path(CONFIG['root'])
FIXTURE = CONFIG['fixture']
MARKER = CONFIG['marker']
SITE = 'http://127.0.0.1:3001'
MAIL = 'http://127.0.0.1:8025'
WAIT_SECONDS = 90
MAIL_WAIT_SECONDS = 45
POLL_SECONDS = 0.5
REQUEST_TIMEOUT = 10
EDITOR = 'div.ProseMirror[contenteditable="true"]'
LOGIN_EMAIL = 'input[name="email_address"]'
LOGIN_PASSWORD = 'input[name="password"]'
LOGIN_URL = SITE + '/app/login'
DASHBOARD = f"{SITE}/app/accounts/{FIXTURE['account_id']}/dashboard" if FIXTURE else None
CONVERSATION = f"{SITE}/app/accounts/{FIXTURE['account_id']}/conversations/{FIXTURE['display_id']}" if FIXTURE else None

class PreflightComplete(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('Mail capture redirected; refusing')

def mail_get(path):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(MAIL + path, timeout=REQUEST_TIMEOUT) as response:
        return json.load(response)

def record(action, **details):
    with (OUT / 'actions.jsonl').open('a') as stream:
        stream.write(json.dumps({'at': dt.datetime.now(dt.timezone.utc).isoformat(),
                                 'action': action, **details}) + '\n')

def wait_until(expression, description):
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        if js(expression) is True:
            return
        time.sleep(POLL_SECONDS)
    raise RuntimeError('Timed out: ' + description)

def point(selector, text=None, contains=False):
    expression = '''JSON.stringify((()=>{
      const s=SELECTOR, text=TEXT, contains=CONTAINS;
      const matches=[...document.querySelectorAll(s)].filter(e=>e.checkVisibility()&&!e.disabled&&
        (text===null||(contains?e.innerText.includes(text):e.innerText.trim()===text)));
      if(matches.length!==1) throw Error('Expected exactly one visible control: '+s+'; found '+matches.length);
      const r=matches[0].getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};
    })())'''
    return json.loads(js(expression.replace('SELECTOR', json.dumps(selector)).replace('TEXT', json.dumps(text)).replace('CONTAINS', json.dumps(contains))))

def click_control(selector, text=None, contains=False):
    position = point(selector, text, contains)
    record('click', selector=selector, text=text)
    click_at_xy(position['x'], position['y'])

def snapshot(name):
    capture_screenshot(path=str(OUT / (name + '.png')))
    (OUT / (name + '.txt')).write_text(js('document.body.innerText'))
    nodes = cdp('Accessibility.getFullAXTree')['nodes']
    # Omit input values and all backend node IDs; names/roles describe rendered UI.
    simple = [{'role': n.get('role', {}).get('value'), 'name': n.get('name', {}).get('value')}
              for n in nodes if not n.get('ignored')]
    (OUT / (name + '.aria.json')).write_text(json.dumps(simple, indent=2))

def fill_login(selector, value):
    point(selector)  # Require a single visible, enabled field before input.
    js('document.querySelector(' + json.dumps(selector) + ').select()')
    press_key('Backspace')
    if int(js('document.querySelector(' + json.dumps(selector) + ').value.length')) != 0:
        raise RuntimeError('Login field did not clear')
    fill_input(selector, value, clear_first=False)
    if int(js('document.querySelector(' + json.dumps(selector) + ').value.length')) != len(value):
        raise RuntimeError('Login field length mismatch')
    record('fill synthetic credential', selector=selector, value='[not recorded]')

def reject_draft_state(state):
    if state['stored_drafts'] or state['editor_draft'] or state['attachments'] or state['unexpected_inputs']:
        raise RuntimeError('Existing draft, addressing or attachment state, or an uninspectable composer; no navigation/logout/input allowed')

def guard_existing_drafts():
    # Actual AttachmentsPreview container mounted under ReplyBox. The DOM test
    # reads the pinned Vue template so a selector drift fails qualification.
    attachment_preview = '.reply-box__top .flex.flex-wrap.gap-y-1.gap-x-2'
    state = json.loads(js('''JSON.stringify((()=>{
      const raw=localStorage.getItem('draftMessages');
      const drafts=raw?JSON.parse(raw):{};
      if(!drafts||typeof drafts!=='object'||Array.isArray(drafts))throw Error('Unrecognized draft storage');
      const customer='customer@chatwoot-dummy.test', sender='support@chatwoot-dummy.test';
      const headers={TO:[customer],FROM:[sender],CC:['',customer],BCC:['']};
      const headerLabel=e=>e.querySelector('.input-group-label')?.textContent.trim().toUpperCase();
      const unreadableComposer=[...document.querySelectorAll('.reply-box')].some(box=>
        ![...box.querySelectorAll('.input-group')].some(group=>headerLabel(group)==='CC'&&group.querySelector('input')?.checkVisibility()));
      const unexpectedInput=e=>{
        if(['checkbox','radio','file','hidden','submit','button'].includes(e.type))return false;
        const group=e.closest('.reply-box .input-group');
        if(group){
          const expected=headers[headerLabel(group)];
          return !expected||!expected.includes(e.value);
        }
        if(!e.checkVisibility())return false;
        if(e.value==='')return false;
        return !(location.href===LOGIN_URL_VALUE&&e.matches(LOGIN_EMAIL_SELECTOR)&&e.value==='agent@chatwoot-dummy.test');
      };
      return {
        stored_drafts:Object.values(drafts).some(v=>v!=null&&(typeof v!=='string'||Boolean(v.trim()))),
        editor_draft:[...document.querySelectorAll('[contenteditable=true]')].some(e=>Boolean(e.innerText.trim())||Boolean(e.querySelector('img,video,audio'))),
        attachments:[...document.querySelectorAll('input[type=file]')].some(e=>e.files.length>0)||Boolean(document.querySelector(ATTACHMENT_SELECTOR)),
        unexpected_inputs:unreadableComposer||[...document.querySelectorAll('input,select')].some(unexpectedInput)
      };
    })())'''.replace('ATTACHMENT_SELECTOR', json.dumps(attachment_preview)).replace('LOGIN_EMAIL_SELECTOR', json.dumps(LOGIN_EMAIL)).replace('LOGIN_URL_VALUE', json.dumps(LOGIN_URL))))
    reject_draft_state(state)
    record('draft preflight passed', **state)

result = {'ok': False, 'marker': MARKER}
adopted = False
try:
    tabs = discover_tabs(include_chrome=False, profile='Profile 14')
    matches = [tab for tab in tabs if tab['targetId'] == CONFIG['target_id']]
    if len(matches) != 1:
        raise RuntimeError('Exactly discovered target is absent; rediscover instead of opening another tab')
    tab = matches[0]
    result['discovered_target'] = {key: tab.get(key) for key in ('targetId', 'title', 'url', 'profile', 'ownership')}
    allowed = {LOGIN_URL, DASHBOARD, CONVERSATION}
    if CONFIG.get('mode') == 'preflight' and re.fullmatch(re.escape(SITE) + r'/app/accounts/[0-9]+/(dashboard|conversations/[0-9]+)', tab['url']):
        allowed.add(tab['url'])
    approved_tab = CONFIG.get('approved_tab', {})
    owned_restart_error = CONFIG.get('mode') == 'journey' and tab['title'] == '127.0.0.1' and approved_tab.get('targetId') == tab['targetId'] and approved_tab.get('profile') == tab.get('profile')
    if tab['url'] not in allowed or tab.get('profile') != 'Profile 14' or (tab['title'] not in ('Chatwoot Dummy', '🟢 Chatwoot Dummy') and not owned_restart_error):
        raise RuntimeError('Target URL/title/profile does not match the synthetic pilot')
    if any(t['targetId'] != tab['targetId'] and t['url'].startswith(SITE + '/app/') for t in tabs):
        raise RuntimeError('Another dummy app tab shares this login; refusing cross-tab logout. Close only a proven task-created duplicate or ask its owner.')
    adopt_tab(tab)
    adopted = True
    record('adopt exact tab', target_id=tab['targetId'], url=tab['url'], profile=tab['profile'])
    if owned_restart_error:
        if 'ERR_CONNECTION_REFUSED' not in js('document.body.innerText'):
            raise RuntimeError('Unrecognized error document; refusing navigation')
        record('recover owned restart error', target_id=tab['targetId'], approved_preflight=True)
    else:
        guard_existing_drafts()
    if CONFIG.get('mode') == 'preflight':
        raise PreflightComplete()
    # Reload only this exact local document after the supervised service restart.
    cdp('Page.navigate', {'url': tab['url']})
    if not wait_for_load():
        raise RuntimeError('Local document did not load')
    wait_until('Boolean(document.querySelector(' + json.dumps(LOGIN_EMAIL) + ')||document.body.innerText.includes("agent@chatwoot-dummy.test"))', 'login or synthetic account')
    guard_existing_drafts()  # Recheck persisted state before any destructive logout.
    if js('Boolean(document.querySelector(' + json.dumps(LOGIN_EMAIL) + '))') is not True:
        click_control('button', 'agent@chatwoot-dummy.test', contains=True)
        wait_until('[...document.querySelectorAll("button")].some(e=>e.checkVisibility()&&e.innerText.trim()==="Log out")', 'Log out menu')
        click_control('button', 'Log out')
        wait_until('Boolean(document.querySelector(' + json.dumps(LOGIN_EMAIL) + '))', 'signed-out form')
    snapshot('01-login')
    env = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines() if line and not line.startswith('#'))
    fill_login(LOGIN_EMAIL, env['DUMMY_EMAIL'])
    fill_login(LOGIN_PASSWORD, 'deliberately-wrong-dummy-password')
    click_control('button[type="submit"]')
    wait_until('/Invalid login credentials/i.test(document.body.innerText)', 'wrong-password rejection')
    record('wrong password rejected', url=page_info()['url'])
    snapshot('02-rejected')
    fill_login(LOGIN_PASSWORD, env['DUMMY_PASSWORD'])
    click_control('button[type="submit"]')
    wait_until('document.body.innerText.includes("agent@chatwoot-dummy.test")', 'signed-in synthetic agent')
    record('signed in', url=page_info()['url'])
    snapshot('03-inbox')
    click_control('a[title="All Conversations"]')
    wait_until('Boolean(document.querySelector("h4.conversation--user"))', 'conversation list')
    click_control('h4.conversation--user', 'Synthetic Customer')
    wait_until('location.href===' + json.dumps(CONVERSATION) + '&&Boolean(document.querySelector(' + json.dumps(EDITOR) + '))', 'seeded conversation and composer')
    wait_until('document.body.innerText.includes(' + json.dumps(FIXTURE['seed_text']) + ')', 'seeded incoming text')
    draft = js('document.querySelector(' + json.dumps(EDITOR) + ').innerText.trim()')
    if draft:
        raise RuntimeError('Existing unsent draft found; refusing to overwrite it')
    wait_until('[...document.querySelectorAll(".input-group input")].some(e=>e.checkVisibility())', 'email recipient controls')
    headers = json.loads(js('''JSON.stringify([...document.querySelectorAll('.input-group')].filter(e=>e.querySelector('input,select')?.checkVisibility()).map(e=>({label:e.querySelector('.input-group-label')?.textContent.trim().toUpperCase(),value:e.querySelector('input,select')?.value})))'''))
    if not any(header.get('label') == 'CC' for header in headers):
        raise RuntimeError('Expected visible Cc control is missing')
    for header in headers:
        label, value = header.get('label'), header.get('value', '')
        if label == 'TO' and value != FIXTURE['customer_email']:
            raise RuntimeError('Unexpected To draft; refusing to replace it')
        if label == 'FROM' and value != FIXTURE['sender_email']:
            raise RuntimeError('Unexpected From draft; refusing to replace it')
        if label == 'BCC' and value:
            raise RuntimeError('Existing Bcc draft; refusing to replace it')
        if label == 'CC' and value:
            if value != FIXTURE['customer_email']:
                raise RuntimeError('Existing Cc draft; refusing to replace it')
            # This synthetic baseline can prefill its customer in both To and Cc.
            # Explicitly choose an empty Cc through the UI; preserve other drafts.
            row = "[...document.querySelectorAll('.input-group')].filter(e=>e.querySelector('input')?.checkVisibility()&&e.querySelector('.input-group-label')?.textContent.trim().toUpperCase()==='CC')"
            if js('(' + row + ').length') != 1:
                raise RuntimeError('Ambiguous Cc field')
            js('(' + row + ')[0].querySelector("input").select()')
            press_key('Backspace')
            click_control(EDITOR)  # Blur commits the visible recipient edit.
            wait_until('(' + row + ')[0].querySelector("input").value===""', 'empty synthetic Cc')
            record('set synthetic recipient scope', to=FIXTURE['customer_email'], cc=[], bcc=[])
    before = mail_get('/api/v1/messages')
    existing = {m['ID'] for m in before['messages']}
    click_control(EDITOR)
    fill_input(EDITOR, MARKER, clear_first=False)
    wait_until('document.querySelector(' + json.dumps(EDITOR) + ').innerText.trim()===' + json.dumps(MARKER), 'draft text')
    record('typed reply', marker=MARKER, conversation_url=CONVERSATION)
    snapshot('04-draft')
    click_control('button', 'Send (⌘ + ↵)')
    wait_until('document.querySelector(' + json.dumps(EDITOR) + ').innerText.trim()===""&&document.body.innerText.includes(' + json.dumps(MARKER) + ')', 'sent message and cleared composer')
    record('reply rendered', marker=MARKER)
    snapshot('05-sent')
    deadline = time.monotonic() + MAIL_WAIT_SECONDS
    captured = None
    while time.monotonic() < deadline:
        messages = mail_get('/api/v1/messages')['messages']
        for summary in messages:
            if summary['ID'] in existing:
                continue
            message = mail_get('/api/v1/message/' + summary['ID'])
            if message['Text'].strip() == MARKER:
                (OUT / 'captured-email.json').write_text(json.dumps(message, indent=2))
                if message['From']['Address'] != FIXTURE['sender_email'] or [to['Address'] for to in message['To']] != [FIXTURE['customer_email']]:
                    raise RuntimeError('Captured sender or recipient mismatch')
                if message['Cc'] or message['Bcc']:
                    raise RuntimeError('Unexpected extra recipients')
                captured = message
                break
        if captured:
            break
        time.sleep(POLL_SECONDS)
    if captured is None:
        raise RuntimeError('UI reply was not captured locally; do not resend without reconciliation')
    (OUT / 'captured-email.json').write_text(json.dumps(captured, indent=2))
    record('local SMTP delivery observed', mail_id=captured['ID'], sender=FIXTURE['sender_email'], recipient=FIXTURE['customer_email'])
    result.update(ok=True, url=page_info()['url'], mail_id=captured['ID'], wrong_password_rejected=True, ui_login=True)
except PreflightComplete:
    result.update(ok=True, preflight=True)
except BaseException as error:
    result['error'] = str(error)
    if adopted:
        try:
            snapshot('failure')
        except Exception:
            pass
finally:
    try:
        filename = 'browser-preflight-result.json' if CONFIG.get('mode') == 'preflight' else 'browser-result.json'
        (OUT / filename).write_text(json.dumps(result, indent=2))
    finally:
        if adopted:
            release_caller()
print(json.dumps(result))
if not result['ok']:
    raise RuntimeError(result.get('error', 'Browser journey failed'))
