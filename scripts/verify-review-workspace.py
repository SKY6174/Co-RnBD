"""Audit the completed, disposable LOCAL editorial fixture in Chromium and WebKit.
Run verify-review-email.py first. Resets ONLY the five-account example.test fixture's
three audit users to a temporary password; never loads production credentials.
Download pinned axe-core separately (see site/README.md), then pass --axe-script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--environment', type=Path, required=True)
parser.add_argument('--axe-script', type=Path, required=True)
args = parser.parse_args()
OUT = args.environment.resolve()
META = json.loads((OUT / 'environment.json').read_text())
STATUS = json.loads((OUT / '.env.local-status.json').read_text())
API, BASE = META['api'], META['base']
assert META['project'].startswith('co-rnbd-e2e-')
assert all(urlparse(u).hostname == '127.0.0.1' for u in [API, BASE, STATUS['DB_URL']])
assert not (Path(META['local']) / 'supabase/.temp/project-ref').exists()
assert hashlib.sha256(args.axe_script.read_bytes()).hexdigest() == '20c09fe157a8a34a30e241aaa1fcdade657734f08ab379ecfbeb7d45cc46e878', 'Use pinned axe-core 4.14.0'
KEY = STATUS.get('PUBLISHABLE_KEY') or STATUS['ANON_KEY']
PASSWORD = secrets.token_urlsafe(24)
RESULT = {'checks': [], 'browser_errors': [], 'blocked_requests': [], 'status': 'FAIL'}


def admin(path, payload=None):
    key = STATUS['SERVICE_ROLE_KEY']
    headers = {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}
    request = urllib.request.Request(API + path, headers=headers,
                                    data=json.dumps(payload).encode() if payload else None,
                                    method='PUT' if payload else 'GET')
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def audit(page, view, engine):
    page.add_script_tag(path=str(args.axe_script.resolve()))
    violations = page.evaluate("""async () => {
      const r = await axe.run(document, {runOnly: {type: 'tag', values: ['wcag2a','wcag2aa','wcag21aa']}});
      return r.violations.map(v => ({id: v.id, impact: v.impact, nodes: v.nodes.map(n =>
        ({target: n.target, html: n.html, failureSummary: n.failureSummary}))}));
    }""")
    RESULT['checks'].append({'browser': engine, 'view': view, 'violations': violations})
    print(engine, view, 'violations', [(v['id'], len(v['nodes'])) for v in violations], flush=True)
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), view + ' overflow'


def screenshots(page, name):
    for width in [1440, 390]:
        page.set_viewport_size({'width': width, 'height': 1000})
        page.evaluate('window.scrollTo(0,0)')
        page.screenshot(path=str(OUT / f'{name}-{width}.png'), full_page=True)
    page.set_viewport_size({'width': 1440, 'height': 1000})


def local_only(route):
    url = route.request.url
    if url.startswith((BASE + '/', API + '/')) or (route.request.method == 'GET' and
            urlparse(url).hostname in ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com']):
        route.continue_()
    else:
        RESULT['blocked_requests'].append(urlparse(url).hostname)
        route.abort()


server = None
try:
    prior = json.loads((OUT / 'editorial-results.json').read_text())
    assert prior['status'] == 'PASS', 'Complete the disposable editorial fixture first'
    users = admin('/auth/v1/admin/users?page=1&per_page=50')['users']
    assert {u['email'] for u in users} == {r + '@example.test' for r in ['author','chief','reviewer1','reviewer2','outsider']}, 'Synthetic fixture only'
    for role in ['author', 'chief', 'reviewer1']:
        user = next(u for u in users if u['email'] == role + '@example.test')
        admin('/auth/v1/admin/users/' + user['id'], {'password': PASSWORD})
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SUPABASE_', 'REVIEW_MAIL_', 'RESEND_', 'PG', 'OPENAI_'))}
    env.update(SUPABASE_URL=API, SUPABASE_PUBLISHABLE_KEY=KEY, NAVER_OAUTH_ENABLED='false')
    with (OUT / 'accessibility-server.log').open('w') as log:
        server = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', '8786'],
                                  cwd=ROOT / 'site', env=env, stdout=log, stderr=log)
        for _ in range(50):
            try:
                with urllib.request.urlopen(BASE + '/api/config', timeout=1) as response:
                    assert json.load(response)['url'] == API
                break
            except (OSError, TimeoutError):
                time.sleep(.2)
        else:
            raise RuntimeError('Local app did not start')
        with sync_playwright() as pw:
            for engine in ['chromium', 'webkit']:
                browser = getattr(pw, engine).launch(headless=True)
                try:
                    for role in ['anonymous', 'author', 'reviewer1', 'chief']:
                        context = browser.new_context(viewport={'width': 1440, 'height': 1000}, reduced_motion='reduce')
                        context.route('**/*', local_only)
                        page = context.new_page()
                        page.on('pageerror', lambda e: RESULT['browser_errors'].append(str(e)))
                        page.goto(BASE + '/submission.html', wait_until='networkidle')
                        expect(page.locator('#auth-panel')).to_be_visible()
                        if role == 'anonymous':
                            audit(page, 'public-login', engine)
                            if engine == 'chromium': screenshots(page, 'public-portal')
                            page.goto(BASE + '/chair.html', wait_until='networkidle')
                            expect(page.locator('#chair-access')).to_be_visible()
                            audit(page, 'anonymous-chair', engine)
                            context.close()
                            continue
                        page.locator('#auth-email').fill(role + '@example.test')
                        page.locator('#auth-password').fill(PASSWORD)
                        page.locator('#email-auth-form button[type=submit]').click()
                        expect(page.locator('#workspace')).to_be_visible(timeout=15000)
                        expect(page.locator('.portal-main')).to_have_class('portal-main has-workspace')
                        if role == 'chief':
                            page.goto(BASE + '/chair.html', wait_until='networkidle')
                            expect(page.locator('#chair-workspace')).to_be_visible()
                            audit(page, 'chief-overview', engine)
                            if engine == 'chromium': screenshots(page, 'polished-chair')
                            page.locator('[data-open]').first.click()
                            expect(page.locator('#chair-detail')).to_be_visible()
                            audit(page, 'chief-detail', engine)
                            if engine == 'chromium': screenshots(page, 'polished-detail')
                            if page.locator('.chair-mail-history').count():
                                page.locator('.chair-mail-history summary').click()
                                expect(page.locator('.chair-mail-history')).to_have_attribute('open', '')
                        else:
                            if role == 'reviewer1':
                                page.locator('[data-tab=reviewer]').click()
                                expect(page.locator('#reviewer-count')).to_contain_text('전체 2편')
                                expect(page.locator('#review-list .card-action').first).to_contain_text('심사 기록 확인')
                            else:
                                page.locator('#author-search').fill('NO MATCH')
                                expect(page.locator('#my-papers .empty-state')).to_be_visible()
                                page.locator('[data-reset-list=author]').click()
                                expect(page.locator('#my-papers .paper-card')).to_have_count(2)
                            audit(page, role + '-workspace', engine)
                            if engine == 'chromium': screenshots(page, 'polished-' + role)
                            page.locator('[data-tab=profile]').click()
                            audit(page, role + '-profile', engine)
                        page.set_viewport_size({'width': 390, 'height': 844})
                        audit(page, role + '-mobile', engine)
                        context.close()
                finally:
                    browser.close()
    assert len(RESULT['checks']) == 22
    assert not any(c['violations'] for c in RESULT['checks']), 'See accessibility-results.json'
    assert not RESULT['browser_errors'], RESULT['browser_errors']
    assert not RESULT['blocked_requests'], RESULT['blocked_requests']
    RESULT['status'] = 'PASS'
finally:
    if server:
        server.terminate()
        server.wait(timeout=15)
    (OUT / 'accessibility-results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))
