"""Authenticated editorial workflow against a disposable LOCAL Supabase only.
Build site/, then prepare-lifecycle-env.py --output /tmp/new-run.
uv run --with playwright --with pymupdf python scripts/verify-field-editor-review.py --environment /tmp/new-run
Never reads production credentials, sends external mail, or creates remote records.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

import pymupdf
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--environment', required=True, type=Path)
OUT = parser.parse_args().environment.resolve()
META = json.loads((OUT / 'environment.json').read_text())
STATUS = json.loads((OUT / '.env.local-status.json').read_text())
API, BASE = META['api'], META['base']
assert META['project'].startswith('co-rnbd-e2e-')
assert all(urlparse(u).hostname == '127.0.0.1' for u in [API, BASE, STATUS['DB_URL']])
assert not (Path(META['local']) / 'supabase/.temp/project-ref').exists()
KEY = STATUS.get('PUBLISHABLE_KEY') or STATUS['ANON_KEY']
PASSWORD = secrets.token_urlsafe(24)
ACTORS, TOKENS, PAGES = {}, {}, {}
RESULT = {'checks': [], 'browser_errors': [], 'blocked_requests': []}


def record(name):
    RESULT['checks'].append(name)
    (OUT / 'editorial-results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))
    print('PASS: ' + name, flush=True)


def request(role, method, path, payload=None, admin=False):
    key = STATUS['SERVICE_ROLE_KEY'] if admin else KEY
    headers = {'apikey': key, 'Authorization': 'Bearer ' + (TOKENS.get(role) or key), 'Prefer': 'return=representation'}
    body = None
    if payload is not None:
        headers['Content-Type'] = 'application/json'
        body = json.dumps(payload).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(API + path, data=body, headers=headers, method=method), timeout=30) as response:
            body = response.read()
            return response.status, json.loads(body) if 'json' in response.headers.get('Content-Type', '') else body
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def ok(role, method, path, payload=None):
    code, data = request(role, method, path, payload)
    assert 200 <= code < 300, (role, method, path, code, data)
    return data


def denied(role, method, path, payload=None):
    code, data = request(role, method, path, payload)
    assert code >= 400 or (method == 'PATCH' and data == []), (role, method, path, code, data)


def paper(pid):
    return ok('chief', 'GET', f'/rest/v1/papers?id=eq.{pid}&select=*,paper_authors(*),reviews(*),paper_files(*)')[0]


def snapshot(pid, status='revision'):
    p = paper(pid)
    return {'p_paper_id': pid, 'p_status': status, 'p_note': '합성 원고 판정입니다. 검증 방법을 보완해 주세요.',
            'p_presentation': None, 'p_session': None, 'p_exception_reason': '',
            'p_expected_updated_at': p['updated_at'],
            'p_expected_reviews': sorted([r for r in p['reviews'] if r['manuscript_submitted_at'] == p['submitted_at']], key=lambda r: r['id'])}


def fresh(page, path='/submission.html'):
    page.goto(BASE + path, wait_until='networkidle')


def open_desk(page, pid):
    fresh(page, '/chair.html')
    expect(page.locator('#chair-workspace')).to_be_visible()
    page.locator(f'[data-open="{pid}"]').click()
    expect(page.locator('#chair-detail')).to_be_visible()
    expect(page.locator('#chair-message')).to_contain_text('최신')


def assign(pid):
    page = PAGES['chief']
    open_desk(page, pid)
    for role in ['reviewer1', 'reviewer2']:
        page.locator('#chair-reviewer').select_option(ACTORS[role]['id'])
        page.locator('#chair-assignment-form button[type=submit]').click()
        expect(page.locator('#chair-message')).to_contain_text('배정과 원고 상태를 저장')
        expect(page.locator('#chair-assignment-form button[type=submit]')).to_be_enabled()


def review(role, pid, recommendation):
    page = PAGES[role]
    fresh(page)
    page.locator('[data-tab=reviewer]').click()
    page.locator(f'[data-action=review][data-id="{pid}"]').click()
    page.locator('#review-comments').fill('합성 심사의견: 연구 결과와 검증 방법을 확인했습니다. ' + recommendation)
    page.locator('#review-recommendation').select_option(recommendation)
    page.locator('#review-conflict').check()
    page.locator('[data-review-action=submit]').click()
    expect(page.locator('#message')).to_contain_text('심사 의견을 제출했습니다')


def publish(role, pid, status):
    page = PAGES[role]
    print('Checking AE publication: ' + role + ' -> ' + status, flush=True)
    open_desk(page, pid)
    page.locator('#desk-decision').select_option(status)
    page.locator('#desk-note').fill('합성 AE 판정: 검증 방법을 보완한 수정본을 제출해 주세요.' if status == 'revision' else '합성 AE 판정: 심사 의견을 검토하여 ' + status)
    page.locator('#chair-decision-submit').click()
    expect(page.locator('#chair-publish-dialog')).to_be_visible()
    page.locator('#chair-publish-confirm').click()
    expect(page.locator('#chair-message')).to_contain_text('판정을 확정하고 저자 포털에 공개')
    assert paper(pid)['status'] == status
    assert paper(pid)['decided_by'] == ACTORS[role]['id']


def submit(track='master_eng'):
    page = PAGES['author']
    fresh(page)
    page.locator('#new-paper').click()
    page.locator('#paper-title').fill('[LOCAL TEST ONLY] 편집위원 심사 ' + secrets.token_hex(4))
    page.locator('#paper-abstract').fill('실제 개인정보나 연구 자료가 없는 격리 환경의 합성 논문 심사 테스트입니다.')
    page.locator('#paper-track').select_option(track)
    page.locator('[data-author=full_name]').fill('합성 저자')
    page.locator('[data-author=affiliation]').fill('합성 기관')
    page.locator('[data-author=email]').fill(ACTORS['author']['email'])
    page.locator('#paper-file').set_input_files(str(OUT / 'synthetic.pdf'))
    page.locator('[data-save=draft]').click()
    expect(page.locator('#message')).to_contain_text('초안을 저장했습니다')
    rows = ok('author', 'GET', '/rest/v1/papers?status=eq.draft&select=id')
    pid = rows[0]['id']
    assert ok('reviewer1', 'GET', f'/rest/v1/papers?id=eq.{pid}') == []
    fresh(page)
    page.locator(f'[data-action=author][data-id="{pid}"]').click()
    expect(page.locator('#paper-file-links')).to_be_visible()
    page.locator('[data-save=submitted]').click()
    expect(page.locator('#message')).to_contain_text('원고가 제출되었습니다')
    return pid


def flow(browser):
    for role in ACTORS:
        context = browser.new_context(viewport={'width': 1440, 'height': 1000}, service_workers='block')
        def local_only(route):
            url = route.request.url
            if url.startswith((BASE + '/', API + '/')) or (route.request.method == 'GET' and urlparse(url).hostname in ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com']):
                route.continue_()
            else:
                RESULT['blocked_requests'].append(urlparse(url).hostname)
                route.abort()
        context.route('**/*', local_only)
        page = context.new_page()
        page.on('pageerror', lambda error: RESULT['browser_errors'].append(str(error)))
        PAGES[role] = page
        fresh(page)
        page.locator('#auth-email').fill(ACTORS[role]['email'])
        page.locator('#auth-password').fill(PASSWORD)
        page.locator('#email-auth-form button[type=submit]').click()
        expect(page.locator('#workspace')).to_be_visible()
        TOKENS[role] = page.evaluate("JSON.parse(localStorage.getItem(Object.keys(localStorage).find(k=>k.endsWith('-auth-token')))).access_token")
        page.locator('[data-tab=profile]').click()
        page.locator('#profile-name').fill('합성 ' + role)
        page.locator('#profile-affiliation').fill('합성 기관')
        page.locator('[name=expertise-track][value=master_eng]').check()
        page.locator('#profile-form button[type=submit]').click()
        expect(page.locator('#message')).to_contain_text('내 정보를 저장했습니다')
    record('real-email-password-login-five-local-accounts')
    settings = ok('chief', 'PATCH', '/rest/v1/conference_settings?edition_year=eq.2026', {'submissions_open': True, 'reviews_open': True})
    assert settings
    # Build the same dual-role arrangement requested for production, using local emails only.
    for role, editor_track in [('reviewer1', 'master_eng'), ('reviewer2', 'industry_joint')]:
        for track in ['master_eng', 'industry_joint']:
            ok('chief', 'POST', '/rest/v1/review_committee', {'edition_year': 2026, 'track': track, 'committee_role': 'reviewer', 'display_name': '테스트위원 ' + role, 'email': ACTORS[role]['email']})
        ok('chief', 'POST', '/rest/v1/review_committee', {'edition_year': 2026, 'track': editor_track, 'committee_role': 'associate_editor', 'display_name': '테스트AE ' + role, 'email': ACTORS[role]['email']})
    chief = PAGES['chief']
    fresh(chief, '/chair.html')
    chief.locator('#committee-panel summary').click()
    chief.locator('#committee-name').fill('화면 등록 테스트')
    chief.locator('#committee-email').fill(ACTORS['outsider']['email'])
    chief.locator('#committee-track').select_option('master_sci')
    chief.locator('#committee-form button').click()
    expect(chief.locator('#chair-message')).to_contain_text('위원 구성을 저장')
    expect(chief.locator('#committee-list')).to_contain_text('계정 연결 완료')
    for width in [1440, 390]:
        chief.set_viewport_size({'width': width, 'height': 1000})
        assert chief.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Roster overflow'
        chief.screenshot(path=str(OUT / f'committee-{width}.png'), full_page=True)
    chief.set_viewport_size({'width': 1440, 'height': 1000})
    record('committee-browser-save-and-desktop-mobile-layout')
    pid = submit()
    assert ok('reviewer2', 'GET', f'/rest/v1/papers?id=eq.{pid}') == []
    assert ok('outsider', 'GET', f'/rest/v1/papers?id=eq.{pid}') == []
    denied('outsider', 'POST', '/rest/v1/rpc/chair_publish_decision', snapshot(pid))
    denied('reviewer1', 'PATCH', f'/rest/v1/papers?id=eq.{pid}', {'title': 'FORGED TITLE'})
    denied('reviewer1', 'PATCH', '/rest/v1/conference_settings?edition_year=eq.2026', {'reviews_open': False})
    denied('reviewer1', 'POST', '/rest/v1/rpc/chair_assign_reviewer', {'p_paper_id': pid, 'p_reviewer_id': ACTORS['outsider']['id']})
    assign(pid)
    denied('reviewer1', 'POST', '/rest/v1/rpc/chair_publish_decision', snapshot(pid))
    denied('reviewer1', 'POST', '/rest/v1/rpc/chair_publish_decision', {**snapshot(pid), 'p_exception_reason': '위조 예외 판정 사유'})
    assert ok('author', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid}) == []
    open_desk(PAGES['reviewer1'], pid)
    expect(PAGES['reviewer1'].locator('#chair-assignment-form')).to_be_hidden()
    expect(PAGES['reviewer1'].locator('#chair-decision-submit')).to_be_disabled()
    record('field-scope-and-write-boundaries-and-incomplete-decision-denials')
    review('reviewer1', pid, 'revise')
    stale = snapshot(pid)
    review('reviewer2', pid, 'accept')
    denied('reviewer1', 'POST', '/rest/v1/rpc/chair_publish_decision', stale)
    assert ok('author', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid}) == []
    publish('reviewer1', pid, 'revision')
    feedback = ok('author', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid})
    assert len(feedback) == 2 and all(set(r) == {'recommendation', 'comments'} for r in feedback)
    assert ok('outsider', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid}) == []
    author = PAGES['author']
    fresh(author)
    author.locator(f'[data-action=author][data-id="{pid}"]').click()
    expect(author.locator('#author-review-feedback')).to_contain_text('합성 심사의견')
    author.locator('#paper-file').set_input_files(str(OUT / 'synthetic.pdf'))
    author.locator('[data-save=submitted]').click()
    expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
    assert ok('author', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid}) == []
    record('revision-notification-anonymous-feedback-stale-snapshot-resubmit')
    assign(pid)
    review('reviewer1', pid, 'accept')
    review('reviewer2', pid, 'accept')
    publish('reviewer1', pid, 'accepted')
    assert len(paper(pid)['reviews']) == 4
    assert len(ok('author', 'POST', '/rest/v1/rpc/author_review_feedback', {'p_id': pid})) == 2
    editor = PAGES['reviewer1']
    for width in [1440, 390]:
        editor.set_viewport_size({'width': width, 'height': 1000})
        assert editor.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Editor overflow'
        editor.screenshot(path=str(OUT / f'editor-accepted-{width}.png'), full_page=True)
    record('new-manuscript-two-new-reviews-AE-accept-and-history')
    rejected = submit('industry_joint')
    assign(rejected)
    review('reviewer1', rejected, 'reject')
    review('reviewer2', rejected, 'reject')
    publish('reviewer2', rejected, 'rejected')
    record('second-field-AE-and-reject-path')
    # A field editor whose email is a coauthor has no editorial privilege.
    sql = "insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email) values ('" + rejected + "',2,'합성 AE 공동저자','합성 기관','" + ACTORS['reviewer2']['email'] + "');"
    subprocess.run(['docker', 'exec', '-i', 'supabase_db_' + META['project'], 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'], input=sql, text=True, check=True)
    denied('reviewer2', 'POST', '/rest/v1/rpc/chair_publish_decision', snapshot(rejected, 'accepted'))
    roster = ok('chief', 'GET', '/rest/v1/review_committee?committee_role=eq.associate_editor&track=eq.master_eng')[0]
    ok('chief', 'PATCH', '/rest/v1/review_committee?id=eq.' + roster['id'], {'active': False})
    denied('reviewer1', 'POST', '/rest/v1/rpc/chair_publish_decision', snapshot(pid))
    denied(None, 'GET', '/rest/v1/review_committee')
    assert not RESULT['browser_errors'], RESULT['browser_errors']
    assert not RESULT['blocked_requests'], RESULT['blocked_requests']
    record('coauthor-conflict-role-revocation-anonymous-denial-no-production-requests')


server = None
try:
    count = subprocess.run(['docker', 'exec', 'supabase_db_' + META['project'], 'psql', '-U', 'postgres', '-Atc', 'select count(*) from auth.users'], capture_output=True, text=True, check=True)
    assert count.stdout.strip() == '0', 'Use an empty disposable test environment'
    for role in ['chief', 'author', 'reviewer1', 'reviewer2', 'outsider']:
        email = role + '@example.test'
        code, user = request(None, 'POST', '/auth/v1/admin/users', {'email': email, 'password': PASSWORD, 'email_confirm': True}, admin=True)
        assert code in (200, 201), (role, code)
        ACTORS[role] = {'id': user['id'], 'email': email}
    sql = "insert into public.staff_roles(user_id,role) values ('" + ACTORS['chief']['id'] + "','chair')"
    subprocess.run(['docker', 'exec', '-i', 'supabase_db_' + META['project'], 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'], input=sql, text=True, check=True)
    doc = pymupdf.open()
    doc.new_page().insert_text((60, 70), 'SYNTHETIC EDITORIAL TEST ONLY. No participant data.')
    doc.save(OUT / 'synthetic.pdf')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SUPABASE_', 'PG', 'S3_', 'OPENAI_'))}
    env.update(SUPABASE_URL=API, SUPABASE_PUBLISHABLE_KEY=KEY, NAVER_OAUTH_ENABLED='false')
    with (OUT / 'editorial-server.log').open('w') as log:
        server = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', '8786'], cwd=ROOT / 'site', env=env, stdout=log, stderr=log)
        for _ in range(60):
            try:
                with urllib.request.urlopen(BASE + '/api/config', timeout=1) as response:
                    assert json.load(response)['url'] == API
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(.2)
        else:
            raise RuntimeError('Local app did not start')
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            try:
                flow(browser)
            except Exception as error:
                RESULT['original_failure'] = str(error)
                print('Failure: ' + str(error).split('\n')[0], flush=True)
                for role, page in PAGES.items():
                    try:
                        page.screenshot(path=str(OUT / ('failure-' + role + '.png')), full_page=True, timeout=2000)
                    except Exception:
                        pass
                raise
            finally:
                browser.close()
    RESULT['status'] = 'PASS'
except Exception as error:
    RESULT.update(status='FAIL', failure=str(error))
    raise
finally:
    if server:
        server.terminate()
        server.wait(timeout=15)
    (OUT / 'editorial-results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))
