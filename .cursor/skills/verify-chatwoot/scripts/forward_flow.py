#!/usr/bin/env browser-harness
"""Executed by browser-harness on stdin; never import a second browser driver.

Drives the email-forward journey on the seeded forward conversation. Mode 'forward' checks the
context-menu gating, the dialog's validation and sends three forwards; mode 'retry' retries the
forward that verify.py marked failed. Delivery and persistence are judged by verify.py."""
import datetime as dt
import json
import os
from browser_harness import telemetry
from pathlib import Path
import time

if os.environ.get('BH_TELEMETRY') != '0' or telemetry.is_enabled():
    raise RuntimeError('Refusing browser work while telemetry is enabled')

CONFIG = json.loads(Path(os.environ['VERIFY_CHATWOOT_CONFIG']).read_text())
OUT = Path(CONFIG['directory'])
ROOT = Path(CONFIG['root'])
FIXTURE = CONFIG['forward_fixture']
MARKERS = CONFIG['markers']
RECIPIENTS = CONFIG['recipients']
MODE = CONFIG['mode']
SITE = 'http://127.0.0.1:3001'
AGENT_EMAIL = 'agent@chatwoot-dummy.test'
WAIT_SECONDS = 90
POLL_SECONDS = 0.5
LOGIN_EMAIL = 'input[name="email_address"]'
LOGIN_PASSWORD = 'input[name="password"]'
LOGIN_URL = SITE + '/app/login'
CONVERSATION = f"{SITE}/app/accounts/{FIXTURE['account_id']}/conversations/{FIXTURE['display_id']}"
DIALOG = 'dialog[open]'
TO_INPUT = 'dialog[open] [data-testid="forward-email-to"] input, dialog[open] input[data-testid="forward-email-to"]'
CC_INPUT = 'dialog[open] [data-testid="forward-email-cc"] input, dialog[open] input[data-testid="forward-email-cc"]'
NOTE_INPUT = 'dialog[open] textarea'
FORWARD_LABEL = 'Forward'
INVALID_ADDRESS = 'not-an-email'
FAILED_LABEL = 'Failed to send'
FORWARD_BLOCK_LABEL = 'Forwarded message'
RETRY_BUTTON = 'button:has([class*="i-lucide-refresh-ccw"])'
# Inside the bubble's header (sender and subject), clear of the rendered letter body.
BUBBLE_HEADER_OFFSET = {'x': 24, 'y': 14}

def record(action, **details):
    with (OUT / 'forward-actions.jsonl').open('a') as stream:
        stream.write(json.dumps({'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'mode': MODE,
                                 'action': action, **details}) + '\n')

def wait_until(expression, description):
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        if js(expression) is True:
            return
        time.sleep(POLL_SECONDS)
    raise RuntimeError('Timed out: ' + description)

def point(selector, text=None):
    expression = '''JSON.stringify((()=>{
      const s=SELECTOR, text=TEXT;
      const matches=[...document.querySelectorAll(s)].filter(e=>e.checkVisibility()&&!e.disabled&&
        (text===null||e.innerText.trim()===text));
      if(matches.length!==1) throw Error('Expected exactly one visible control: '+s+'; found '+matches.length);
      const r=matches[0].getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};
    })())'''
    return json.loads(js(expression.replace('SELECTOR', json.dumps(selector)).replace('TEXT', json.dumps(text))))

def click_control(selector, text=None):
    position = point(selector, text)
    record('click', selector=selector, text=text)
    click_at_xy(position['x'], position['y'])

def snapshot(name):
    capture_screenshot(path=str(OUT / (name + '.png')))
    (OUT / (name + '.txt')).write_text(js('document.body.innerText'))

def bubble(message_id):
    return f'[data-message-id="{message_id}"] [class*="grid-area:bubble"]'

def bubble_header(message_id, far_side=False):
    selector = bubble(message_id)
    js('document.querySelector(' + json.dumps(selector) + ').scrollIntoView({block:"center"})')
    rect = json.loads(js('JSON.stringify(document.querySelector(' + json.dumps(selector) + ').getBoundingClientRect())'))
    x = rect['x'] + rect['width'] - BUBBLE_HEADER_OFFSET['x'] if far_side else rect['x'] + BUBBLE_HEADER_OFFSET['x']
    return x, rect['y'] + BUBBLE_HEADER_OFFSET['y']

def open_context_menu(message_id):
    x, y = bubble_header(message_id)
    record('right-click message', message_id=message_id)
    click_at_xy(x, y, button='right')
    wait_until('Boolean(document.querySelector(".menu-container"))', 'message context menu')

def menu_labels():
    return json.loads(js('JSON.stringify([...document.querySelectorAll(".menu-container .menu")].map(e=>e.innerText.trim()))'))

def close_menu(message_id):
    # The menu closes when focus leaves it. It opens at the right-click point, so click the far
    # side of the same message, clear of the menu.
    x, y = bubble_header(message_id, far_side=True)
    click_at_xy(x, y)
    wait_until('!document.querySelector(".menu-container")', 'context menu closed')

def menu_offers_forward(message_id):
    open_context_menu(message_id)
    labels = menu_labels()
    close_menu(message_id)
    record('menu options', message_id=message_id, labels=labels)
    return FORWARD_LABEL in labels

def type_into(selector, value):
    point(selector)  # Require one visible, enabled field before input.
    field = 'document.querySelector(' + json.dumps(selector) + ')'
    if js(field + '.value'):
        js(field + '.select()')
        press_key('Backspace')
        if js(field + '.value') != '':
            raise RuntimeError('Field did not clear: ' + selector)
    fill_input(selector, value, clear_first=False)
    actual = js('document.querySelector(' + json.dumps(selector) + ').value')
    if actual != value:
        raise RuntimeError('Field did not take the typed value: ' + selector)
    record('type', selector=selector, value=value)

def dialog_text():
    return js('document.querySelector(' + json.dumps(DIALOG) + ')?.innerText || ""')

def forward(source_id, to, cc, marker, invalid_first=False):
    open_context_menu(source_id)
    click_control('.menu-container .menu', FORWARD_LABEL)
    wait_until('Boolean(document.querySelector(' + json.dumps(DIALOG) + '))', 'forward dialog')
    checks = {}
    if invalid_first:
        click_control(DIALOG + ' button', FORWARD_LABEL)
        wait_until('document.querySelector(' + json.dumps(DIALOG) + ')?.innerText.includes("Add at least one valid email address")', 'empty To refused')
        checks['empty_to_refused'] = True
        type_into(TO_INPUT, INVALID_ADDRESS)
        click_control(DIALOG + ' button', FORWARD_LABEL)
        wait_until('document.querySelector(' + json.dumps(DIALOG) + ')?.innerText.includes("Add at least one valid email address")', 'invalid To refused')
        checks['invalid_to_refused'] = True
        snapshot('f4-refused')
    type_into(TO_INPUT, ', '.join(to))
    if cc:
        type_into(CC_INPUT, ', '.join(cc))
    type_into(NOTE_INPUT, marker)
    checks['preview_has_subject'] = 'Subject:' in dialog_text()
    snapshot('forward-dialog-' + marker.split()[-1].lower())
    click_control(DIALOG + ' button', FORWARD_LABEL)
    wait_until('!document.querySelector(' + json.dumps(DIALOG) + ')', 'dialog closed after send')
    # The optimistic bubble shows only the note; the stored forward arrives with its email body.
    rendered = '[...document.querySelectorAll("[data-message-id]")].find(e=>e.innerText.includes(MARKER))'.replace('MARKER', json.dumps(marker))
    wait_until('Boolean(' + rendered + '?.innerText.includes(' + json.dumps(FORWARD_BLOCK_LABEL) + '))', 'forward rendered in thread')
    text = js(rendered + '.innerText')
    checks.update(rendered_subject='Fwd: ' in text, rendered_forward_block=FORWARD_BLOCK_LABEL in text,
                  rendered_source_body=FIXTURE['html_marker'] in text)
    record('forward sent', source_id=source_id, marker=marker, to=to, cc=cc, rendered=checks)
    return checks

def sign_in_if_needed():
    if js('Boolean(document.querySelector(' + json.dumps(LOGIN_EMAIL) + '))') is not True:
        return False
    env = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines() if line and not line.startswith('#'))
    fill_input(LOGIN_EMAIL, env['DUMMY_EMAIL'])
    fill_input(LOGIN_PASSWORD, env['DUMMY_PASSWORD'])
    record('fill synthetic credentials', value='[not recorded]')
    click_control('button[type="submit"]')
    wait_until('document.body.innerText.includes(' + json.dumps(AGENT_EMAIL) + ')', 'signed-in synthetic agent')
    return True

def open_conversation():
    cdp('Page.navigate', {'url': CONVERSATION})
    if wait_for_load(timeout=WAIT_SECONDS) is not True:
        raise RuntimeError('Conversation document did not load')
    if sign_in_if_needed():
        cdp('Page.navigate', {'url': CONVERSATION})
        wait_for_load(timeout=WAIT_SECONDS)
    # Messages render as plain bubbles until the inbox loads; email-only actions such as Forward
    # appear once the source renders as an email, with its Subject header.
    source = 'document.querySelector(' + json.dumps(bubble(FIXTURE['html_source']['id'])) + ')'
    wait_until('Boolean(' + source + '?.innerText.includes("Subject: " + ' + json.dumps(FIXTURE['html_source']['subject']) + '))',
               'seeded forward source rendered as an email')
    record('opened forward conversation', url=CONVERSATION)

result = {'ok': False, 'mode': MODE}
adopted = False
try:
    tabs = discover_tabs(include_chrome=False, profile='Profile 14')
    matches = [tab for tab in tabs if tab['targetId'] == CONFIG['target_id']]
    if len(matches) != 1:
        raise RuntimeError('Exactly discovered target is absent; rediscover instead of opening another tab')
    tab = matches[0]
    if not tab['url'].startswith(SITE + '/app/') or tab.get('profile') != 'Profile 14':
        raise RuntimeError('Target URL/profile does not match the synthetic dummy app')
    adopt_tab(tab)
    adopted = True
    record('adopt exact tab', target_id=tab['targetId'], url=tab['url'], profile=tab['profile'])
    open_conversation()
    if MODE == 'forward':
        result['gating'] = {
            'incoming_offers_forward': menu_offers_forward(FIXTURE['html_source']['id']),
            'outgoing_offers_forward': menu_offers_forward(FIXTURE['outgoing_reply']['id']),
            'private_note_offers_forward': menu_offers_forward(FIXTURE['private_note']['id']),
        }
        snapshot('f5-gating')
        result['F1'] = forward(FIXTURE['html_source']['id'], RECIPIENTS['F1_to'], RECIPIENTS['F1_cc'], MARKERS['F1'], invalid_first=True)
        snapshot('f1-sent')
        result['F2'] = forward(FIXTURE['outgoing_reply']['id'], RECIPIENTS['F2_to'], [], MARKERS['F2'])
        result['F3'] = forward(FIXTURE['plain_source']['id'], RECIPIENTS['F3_to'], [], MARKERS['F3'])
        snapshot('f3-sent')
    elif MODE == 'retry':
        # Freshly loaded after the forwards: the composer derives its addressing from the thread on
        # load, and must still address the conversation, not a forward's recipients.
        wait_until('[...document.querySelectorAll(".reply-box .input-group input")].some(e=>e.checkVisibility())', 'reply composer addressing')
        result['composer_recipients'] = json.loads(js('''JSON.stringify([...document.querySelectorAll('.reply-box .input-group')]
          .filter(e=>e.querySelector('input')?.checkVisibility())
          .map(e=>({label:e.querySelector('.input-group-label')?.textContent.trim().toUpperCase(),value:e.querySelector('input').value})))'''))
        record('reply composer addressing after forwards', recipients=result['composer_recipients'])
        snapshot('f10-composer')
        failed_id = CONFIG['failed_forward_id']
        failed = json.dumps(f'[data-message-id="{failed_id}"]')
        wait_until('document.querySelector(' + failed + ')?.innerText.includes(' + json.dumps(FAILED_LABEL) + ')', 'failed forward shows its error')
        result['failed_offers_forward'] = menu_offers_forward(failed_id)
        snapshot('f6-failed')
        click_control(f'[data-message-id="{failed_id}"] {RETRY_BUTTON}')
        wait_until('!document.querySelector(' + failed + ')?.innerText.includes(' + json.dumps(FAILED_LABEL) + ')', 'retry cleared the failure')
        record('retry clicked', message_id=failed_id)
        snapshot('f6-retried')
    else:
        raise RuntimeError('Unknown mode')
    result['ok'] = True
except BaseException as error:
    result['error'] = str(error)
    if adopted:
        try:
            snapshot('forward-failure-' + MODE)
        except Exception:
            pass
finally:
    try:
        (OUT / f'forward-browser-{MODE}.json').write_text(json.dumps(result, indent=2))
    finally:
        if adopted:
            release_caller()
print(json.dumps(result))
if not result['ok']:
    raise RuntimeError(result.get('error', 'Forward journey failed'))
