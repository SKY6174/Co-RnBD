"""Real authenticated UI/API/DB/Storage lifecycle, on a fresh LOCAL environment only.
Build site/ first, then prepare-lifecycle-env.py --output /tmp/my-new-test-run.
uv run --with playwright --with pymupdf --with pypdf python \
  scripts/verify-authenticated-lifecycle.py --environment /tmp/my-new-test-run
No production env, account, participant, payment provider or mail recipient is used.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.request
from urllib.parse import urlparse

import pymupdf
from pypdf import PdfReader
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--environment', required=True, type=Path)
args = parser.parse_args()
OUT = args.environment.resolve()
META = json.loads((OUT / 'environment.json').read_text())
STATUS = json.loads((OUT / '.env.local-status.json').read_text())
API, BASE = META['api'], META['base']
assert META['project'].startswith('co-rnbd-e2e-')
assert all(urlparse(url).hostname == '127.0.0.1' for url in (API, BASE, STATUS['DB_URL']))
assert STATUS['API_URL'] == API
assert not (Path(META['local']) / 'supabase/.temp/project-ref').exists()
PUBLIC_KEY = STATUS.get('PUBLISHABLE_KEY') or STATUS['ANON_KEY']
PASSWORD = secrets.token_urlsafe(24)
ACTORS, PAGES, TOKENS = {}, {}, {}
RESULT = {'project': META['project'], 'checks': [], 'browser_errors': [], 'blocked_requests': [], 'network': []}
PID = None


def record(name, **details):
    RESULT['checks'].append({'name': name, **details})
    (OUT / 'results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))
    print('PASS: ' + name, flush=True)


def request(role, method, path, payload=None, raw=None, admin=False):
    assert urlparse(API).hostname == '127.0.0.1' and path.startswith('/')
    key = STATUS['SERVICE_ROLE_KEY'] if admin else PUBLIC_KEY
    headers = {'apikey': key, 'Authorization': 'Bearer ' + (TOKENS.get(role) or key), 'Prefer': 'return=representation'}
    body = raw
    if payload is not None:
        body = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    elif raw is not None:
        headers['Content-Type'] = 'application/pdf'
    try:
        with urllib.request.urlopen(urllib.request.Request(API + path, data=body, headers=headers, method=method), timeout=30) as response:
            body = response.read()
            return response.status, json.loads(body) if 'json' in response.headers.get('Content-Type', '') else body
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def ok(role, method, path, payload=None):
    code, data = request(role, method, path, payload)
    assert 200 <= code < 300, (method, path, code, data)
    return data


def denied(role, method, path, payload=None, raw=None):
    code, data = request(role, method, path, payload, raw=raw)
    assert code >= 400 or (method == 'PATCH' and data == []), (method, path, code)


def sql(statement, check=True):
    result = subprocess.run(['docker', 'exec', '-i', 'supabase_db_' + META['project'],
        'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'],
        input=statement, text=True, capture_output=True, check=check)
    return result


def fresh(page, path):
    page.goto(BASE + path, wait_until='networkidle')


def shot(page, name):
    page.screenshot(path=str(OUT / (name + '.png')), full_page=True)


def paper():
    return ok('chair', 'GET', f'/rest/v1/papers?id=eq.{PID}&select=*,paper_authors(*),paper_files(*),reviews(*),paper_final_checks(*)')[0]


def author_paper(page):
    fresh(page, '/submission.html')
    page.locator(f'[data-action=author][data-id="{PID}"]').click()
    expect(page.locator('#paper-form')).to_be_visible()


def chair_paper(page):
    fresh(page, '/chair.html')
    expect(page.locator('#chair-workspace')).to_be_visible()
    page.locator(f'[data-open="{PID}"]').click()
    expect(page.locator('#chair-detail')).to_be_visible()
    expect(page.locator('#chair-message')).to_contain_text('최신')


def assign(page, role):
    page.locator('#chair-reviewer').select_option(ACTORS[role]['id'])
    page.locator('#chair-assignment-form button[type=submit]').click()
    expect(page.locator('#chair-message')).to_contain_text('배정과 원고 상태를 저장')
    expect(page.locator('#chair-assignment-form button[type=submit]')).to_be_enabled()


def review(page, draft=False, recommendation='accept'):
    fresh(page, '/submission.html')
    page.locator('[data-tab=reviewer]').click()
    page.locator(f'[data-action=review][data-id="{PID}"]').click()
    page.locator('#review-comments').fill('격리 환경에서 연구 결과와 검증 방법을 확인한 합성 심사 의견입니다.')
    if not draft:
        page.locator('#review-recommendation').select_option(recommendation)
        page.locator('#review-conflict').check()
    page.locator('[data-review-action=' + ('draft' if draft else 'submit') + ']').click()
    expect(page.locator('#message')).to_contain_text('임시저장' if draft else '심사 의견을 제출했습니다')


def publish(page, status):
    page.locator('#desk-decision').select_option(status)
    if status == 'accepted':
        page.locator('#desk-presentation').select_option('oral')
        page.locator('#desk-session').select_option('oral_1')
    page.locator('#desk-note').fill('검증 방법을 보완하여 수정본을 제출해 주세요.' if status == 'revision' else '수정된 연구 결과를 확인하여 채택합니다. 최종본을 제출해 주세요.')
    page.locator('#chair-decision-submit').click()
    expect(page.locator('#chair-publish-dialog')).to_be_visible()
    page.locator('#chair-publish-confirm').click()
    expect(page.locator('#chair-message')).to_contain_text('판정을 확정하고 저자 포털에 공개')


def stages(page, reviews=False, final=False):
    fresh(page, '/operations.html')
    expect(page.locator('#operations-workspace')).to_be_visible()
    for selector, value in [('#paper-submissions-open', True), ('#paper-reviews-open', reviews), ('#paper-final-open', final)]:
        page.locator(selector).set_checked(value)
    for selector in ['#paper-submission-deadline', '#paper-review-deadline', '#paper-final-deadline']:
        page.locator(selector).fill('')
    page.locator('#paper-notice').fill('LOCAL TEST ONLY — 실제 행사 접수가 아닙니다.')
    page.locator('#paper-settings-form button[type=submit]').click()
    expect(page.locator('#operations-message')).to_contain_text('운영 설정을 저장했습니다')


def pdf(name):
    path = OUT / (name + '.pdf')
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((60, 70), 'LOCAL SYNTHETIC TEST: ' + name, fontsize=16)
    page.insert_text((60, 110), 'No participant or research data.', fontsize=12)
    doc.save(path)
    return path


def document_issue(page, rid, kind):
    fresh(page, '/mypage.html')
    page.locator(f'[data-issue="{rid}"][data-kind="{kind}"]').click()
    page.wait_for_url('**/document.html?id=*')
    expect(page.locator('#issued-document')).to_be_visible()
    did = page.url.split('id=')[1]
    assert ok('author', 'GET', f'/rest/v1/registration_documents?id=eq.{did}')[0]['state'] == 'issued'
    return did


def business_flow(browser):
    global PID
    for role in ['chair', 'author', 'reviewer-a', 'reviewer-b', 'outsider']:
        context = browser.new_context(viewport={'width': 1440, 'height': 1000}, service_workers='block')
        def local_only(route):
            url = route.request.url
            if url.startswith((BASE + '/', API + '/')) or (urlparse(url).hostname in
                    ('cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com') and route.request.method == 'GET'):
                route.continue_()
            else:
                RESULT['blocked_requests'].append({'method': route.request.method, 'host': urlparse(url).hostname})
                route.abort()
        context.route('**/*', local_only)
        page = context.new_page()
        loading_checks = []
        def profile_loading(route):
            assert route.request.url.startswith(API + '/'), 'Profile requests must stay local'
            if route.request.method == 'GET':
                loading_checks.append(page.locator('#workspace').is_hidden())
            route.continue_()
        page.route('**/rest/v1/profiles?*', profile_loading, times=1)
        page.on('pageerror', lambda error: RESULT['browser_errors'].append(str(error)))
        page.on('response', lambda response: RESULT['network'].append({'method': response.request.method,
            'path': urlparse(response.url).path, 'status': response.status}) if response.url.startswith(API) else None)
        PAGES[role] = page
        fresh(page, '/submission.html')
        page.locator('#auth-email').fill(ACTORS[role]['email'])
        page.locator('#auth-password').fill(PASSWORD)
        page.locator('#email-auth-form button[type=submit]').click()
        expect(page.locator('#workspace')).to_be_visible()
        assert loading_checks == [True], 'The workspace must stay hidden while the initial profile loads'
        TOKENS[role] = page.evaluate("JSON.parse(localStorage.getItem(Object.keys(localStorage).find(k=>k.endsWith('-auth-token')))).access_token")
        page.locator('[data-tab=profile]').click()
        page.locator('#profile-name').fill('로컬 검증 ' + role)
        page.locator('#profile-affiliation').fill('합성 테스트 기관')
        page.locator('[name=expertise-track][value=master_eng]').check()
        page.locator('#profile-form button[type=submit]').click()
        expect(page.locator('#message')).to_contain_text('내 정보를 저장했습니다')
        fresh(page, '/submission.html')
        page.locator('[data-tab=profile]').click()
        expect(page.locator('#profile-name')).to_have_value('로컬 검증 ' + role)
    record('01-email-login-and-profile-persistence', actors=5)
    chair, author, a, b, outsider = [PAGES[r] for r in ['chair', 'author', 'reviewer-a', 'reviewer-b', 'outsider']]
    stages(chair)
    fresh(author, '/submission.html')
    author.locator('#new-paper').click()
    title = '[LOCAL E2E] 투고 심사 저장 흐름 ' + secrets.token_hex(4)
    author.locator('#paper-title').fill(title)
    author.locator('#paper-abstract').fill('격리 환경에서 초안 저장부터 최종본 확인까지 검증하는 합성 연구 자료입니다.')
    author.locator('[data-author=full_name]').fill('로컬 검증 author')
    author.locator('[data-author=affiliation]').fill('합성 테스트 기관')
    author.locator('[data-author=email]').fill(ACTORS['author']['email'])
    v1, v2, final = pdf('submission-v1'), pdf('submission-v2'), pdf('final-v3')
    author.locator('#paper-file').set_input_files(str(v1))
    author.locator('[data-save=draft]').click()
    expect(author.locator('#message')).to_contain_text('초안을 저장했습니다')
    PID = ok('author', 'GET', '/rest/v1/papers?select=id')[0]['id']
    row = paper()
    assert row['status'] == 'draft' and len(row['paper_authors']) == 1 and len(row['paper_files']) == 1
    author_paper(author)
    author.locator('[data-save=submitted]').click()
    expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
    assert paper()['status'] == 'submitted'
    denied('author', 'PATCH', f'/rest/v1/papers?id=eq.{PID}', {'status': 'accepted'})
    denied('author', 'POST', '/rest/v1/rpc/chair_assign_reviewer',
           {'p_paper_id': PID, 'p_reviewer_id': ACTORS['reviewer-a']['id']})
    assert ok('outsider', 'GET', f'/rest/v1/papers?id=eq.{PID}') == []
    denied('outsider', 'GET', '/storage/v1/object/authenticated/paper-pdfs/' + row['paper_files'][0]['storage_path'])
    record('02-draft-authors-PDF-submit-and-ownership', file_sha256=hashlib.sha256(v1.read_bytes()).hexdigest())
    chair_paper(chair)
    expect(chair.locator('#chair-decision-submit')).to_be_disabled()
    assign(chair, 'reviewer-a')
    assign(chair, 'reviewer-b')
    assert len([r for r in paper()['reviews'] if not r['revoked_at']]) == 2
    stages(chair, reviews=True)
    review(a, draft=True)
    assert next(r for r in paper()['reviews'] if r['reviewer_id'] == ACTORS['reviewer-a']['id'])['review_state'] == 'draft'
    review(a, recommendation='revise')
    review(b, recommendation='revise')
    assert all(r['review_state'] == 'submitted' for r in paper()['reviews'])
    record('03-two-reviewer-assignment-draft-and-submit', reviewers=2)
    chair_paper(chair)
    publish(chair, 'revision')
    assert paper()['status'] == 'revision'
    author_paper(author)
    expect(author.locator('#message')).to_contain_text('수정본')
    author.locator('#paper-file').set_input_files(str(v2))
    author.locator('[data-save=submitted]').click()
    expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
    assert paper()['status'] == 'submitted' and len(paper()['paper_files']) == 2
    chair_paper(chair)
    assign(chair, 'reviewer-a')
    assign(chair, 'reviewer-b')
    review(a)
    review(b)
    chair_paper(chair)
    publish(chair, 'accepted')
    assert paper()['status'] == 'accepted' and paper()['decision_published_at']
    author_paper(author)
    expect(author.locator('#final-submit')).to_be_disabled()
    denied('author', 'POST', f'/storage/v1/object/paper-pdfs/{ACTORS["author"]["id"]}/{PID}/closed-final.pdf', raw=final.read_bytes())
    stages(chair, reviews=True, final=True)
    author_paper(author)
    author.locator('#final-file').set_input_files(str(final))
    author.locator('#final-submit').click()
    expect(author.locator('#message')).to_contain_text('최종 PDF를 업로드했습니다')
    file = next(f for f in paper()['paper_files'] if f['file_stage'] == 'final')
    code, content = request('chair', 'GET', '/storage/v1/object/authenticated/paper-pdfs/' + file['storage_path'])
    assert code == 200 and content == final.read_bytes()
    denied('reviewer-a', 'GET', '/storage/v1/object/authenticated/paper-pdfs/' + file['storage_path'])
    chair_paper(chair)
    chair.locator('#chair-final-confirm').check()
    chair.locator('#chair-final-form button').click()
    expect(chair.locator('#chair-message')).to_contain_text('최종본 v3 확인 완료')
    check = paper()['paper_final_checks']
    assert (check[0] if isinstance(check, list) else check)['file_id'] == file['id']
    record('04-revision-resubmit-rereview-accept-final-confirm', versions=3)
    shot(chair, 'chair-final-confirmed')
    fresh(author, '/registration.html')
    expect(author.locator('#registration-form')).to_be_visible()
    author.locator('#registration-category').select_option('faculty')
    author.locator('[name=attendance-day]').first.check()
    author.locator('#registration-form button[type=submit]').click()
    expect(author.locator('#registration-current')).to_contain_text('확인 대기')
    reg = ok('author', 'GET', '/rest/v1/attendee_registrations?select=*')[0]
    rid = reg['id']
    fresh(author, '/registration.html')
    expect(author.locator('#registration-category')).to_have_value('faculty')
    author.locator('#registration-category').select_option('industry')
    author.locator('#registration-form button[type=submit]').click()
    expect(author.locator('#registration-current')).to_contain_text('기업')
    denied('author', 'POST', '/rest/v1/attendee_registrations', {k: reg[k] for k in ['user_id', 'edition_year', 'category', 'attendance_days']})
    for kind in ['attendance', 'receipt', 'statement']:
        denied('author', 'POST', '/rest/v1/rpc/issue_registration_document', {'p_registration_id': rid, 'p_kind': kind})
    fresh(chair, '/operations.html')
    chair.locator(f'[data-registration="{rid}"][data-action=confirm]').click()
    expect(chair.locator('#operations-message')).to_contain_text('참가를 확정')
    chair.locator(f'[data-registration="{rid}"][data-action=checkin]').click()
    expect(chair.locator('#operations-message')).to_contain_text('현장 체크인')
    assert ok('author', 'GET', f'/rest/v1/attendee_registrations?id=eq.{rid}')[0]['checked_in_at']
    record('05-registration-create-update-duplicate-denial-confirm-checkin')
    fresh(chair, '/document-admin.html')
    expect(chair.locator('#documents-workspace')).to_be_visible()
    chair.locator('.document-settings summary').click()
    for field, value in {'organization': 'LOCAL TEST 학회', 'representative': '합성 대표',
        'address': '테스트 환경', 'contact_email': 'issuer@example.test'}.items():
        chair.locator('#issuer-' + field).fill(value)
    chair.locator('#issuer-enabled').check()
    chair.locator('#issuer-verified').check()
    chair.locator('#issuer-form button').click()
    expect(chair.locator('#documents-message')).to_contain_text('발급기관 설정을 저장')
    chair.locator(f'[data-person="{rid}"]').click()
    chair.locator('#billing-amount').fill('120000')
    chair.locator('#billing-status').select_option('unpaid')
    chair.locator('#billing-verified').check()
    chair.locator('#billing-form button').click()
    expect(chair.locator('#documents-message')).to_contain_text('수동 확인 내역을 저장')
    denied('author', 'POST', '/rest/v1/rpc/issue_registration_document', {'p_registration_id': rid, 'p_kind': 'receipt'})
    docs = {kind: document_issue(author, rid, kind) for kind in ['attendance', 'statement']}
    fresh(chair, '/document-admin.html')
    chair.locator(f'[data-person="{rid}"]').click()
    chair.locator('#billing-status').select_option('paid')
    chair.locator('#billing-method').select_option('transfer')
    # The form interprets input in KST; use a known past instant in KST in every host timezone.
    chair.locator('#billing-paid-at').fill('2026-01-01T12:00')
    chair.locator('#billing-verified').check()
    chair.locator('#billing-form button').click()
    expect(chair.locator('#documents-message')).to_contain_text('수동 확인 내역을 저장')
    assert ok('author', 'GET', f'/rest/v1/registration_documents?id=eq.{docs["statement"]}')[0]['state'] == 'revoked'
    docs['receipt'] = document_issue(author, rid, 'receipt')
    docs['statement'] = document_issue(author, rid, 'statement')
    for kind, did in docs.items():
        fresh(author, '/document.html?id=' + did)
        expect(author.locator('#issued-document')).to_be_visible()
        author.evaluate('document.fonts.ready')
        author.pdf(path=str(OUT / (kind + '-issued.pdf')), prefer_css_page_size=True, print_background=True)
        reader = PdfReader(str(OUT / (kind + '-issued.pdf')))
        assert len(reader.pages) == 1 and abs(float(reader.pages[0].mediabox.width) - 595.28) < 2
        author.set_viewport_size({'width': 390, 'height': 844})
        assert author.evaluate('document.documentElement.scrollWidth <= innerWidth')
        shot(author, kind + '-mobile')
    record('06-issuer-billing-save-three-document-issues-and-A4-print', kinds=list(docs))
    for table in ['registration_documents', 'registration_billing']:
        assert ok('outsider', 'GET', f'/rest/v1/{table}?registration_id=eq.{rid}') == []
        denied(None, 'GET', f'/rest/v1/{table}?select=*&limit=1')
    denied('outsider', 'POST', '/rest/v1/rpc/issue_registration_document', {'p_registration_id': rid, 'p_kind': 'receipt'})
    denied('author', 'PATCH', f'/rest/v1/document_issuers?edition_year=eq.{reg["edition_year"]}', {'organization': 'forged'})
    denied('author', 'PATCH', f'/rest/v1/registration_billing?registration_id=eq.{rid}', {'amount': 1})
    denied('chair', 'PATCH', f'/rest/v1/registration_documents?id=eq.{docs["receipt"]}', {'snapshot': {'forged': True}})
    fresh(outsider, '/document.html?id=' + docs['receipt'])
    expect(outsider.locator('#issued-document')).to_be_hidden()
    expect(outsider.locator('#document-message')).to_contain_text('문서를 볼 수 없습니다')
    payload = {'p_registration_id': rid, 'p_kind': 'receipt'}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: request('author', 'POST', '/rest/v1/rpc/issue_registration_document', payload), range(4)))
    assert all(code == 200 and did == docs['receipt'] for code, did in results)
    ok('chair', 'PATCH', f'/rest/v1/registration_billing?registration_id=eq.{rid}', {'status': 'refunded'})
    fresh(author, '/document.html?id=' + docs['receipt'])
    expect(author.locator('#document-message')).to_contain_text('발급 취소')
    expect(author.locator('#document-print')).to_be_disabled()
    denied('author', 'POST', '/rest/v1/rpc/issue_registration_document', payload)
    ok('chair', 'PATCH', f'/rest/v1/attendee_registrations?id=eq.{rid}', {'checked_in_at': None})
    fresh(author, '/registration.html')
    author.once('dialog', lambda dialog: dialog.accept())
    author.locator('#cancel-registration').click()
    expect(author.locator('#registration-current')).to_contain_text('취소')
    assert not ok('author', 'GET', f'/rest/v1/registration_documents?registration_id=eq.{rid}&state=eq.issued')
    fresh(author, '/mypage.html')
    expect(author.locator('#member-history')).to_contain_text('참가 취소')
    author.locator('#member-signout').click()
    expect(author.locator('#member-workspace')).to_be_hidden()
    expect(author.locator('#member-history')).to_be_empty()
    record('07-document-ownership-immutability-idempotency-revocation-cancellation-signout')
    assert not RESULT['browser_errors'], RESULT['browser_errors']
    assert not RESULT['blocked_requests'], RESULT['blocked_requests']
    record('08-no-browser-exceptions-or-production-requests')


server = None
try:
    assert sql('select count(*) from auth.users;').stdout.strip() == '0', 'Use a NEW empty test project for every run'
    migrated = int(sql('select count(*) from supabase_migrations.schema_migrations;').stdout.strip())
    assert migrated == len(list((ROOT / 'supabase/migrations').glob('*.sql')))
    for role in ['chair', 'author', 'reviewer-a', 'reviewer-b', 'outsider']:
        email = role + '@example.test'
        code, user = request(None, 'POST', '/auth/v1/admin/users', {'email': email, 'password': PASSWORD, 'email_confirm': True}, admin=True)
        assert code in (200, 201), ('fixture-user', role, code)
        ACTORS[role] = {'id': user['id'], 'email': email}
    sql("insert into public.staff_roles(user_id,role,is_super_admin) values ('" + ACTORS['chair']['id'] + "','chair',true);")
    original_guard = (ROOT / 'supabase/migrations/20260927151538_super_admin_monitor.sql').read_text().split('alter table')[0]
    result = sql(original_guard, check=False)
    assert result.returncode != 0 and 'Both verified super admin accounts must exist' in result.stderr
    function_guard = (ROOT / 'supabase/migrations/20260925190050_db_connectivity_optimization.sql').read_text().split('do $$')[-1]
    function_guard = 'do $$' + function_guard
    permissions = sql("begin; create function public.rls_auto_enable() returns void language sql as 'select'; "
        + function_guard + " select not has_function_privilege('anon','public.rls_auto_enable()','execute') "
        "and not has_function_privilege('authenticated','public.rls_auto_enable()','execute'); rollback;")
    assert permissions.stdout.strip() == 't', 'Hosted platform function permissions must still be revoked'
    record('00-fresh-migrations-and-populated-project-admin-guard', migrations=migrated)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SUPABASE_', 'PG', 'S3_', 'OPENAI_'))}
    env.update(SUPABASE_URL=API, SUPABASE_PUBLISHABLE_KEY=PUBLIC_KEY, NAVER_OAUTH_ENABLED='false')
    with (OUT / 'next-server.log').open('w') as log:
        server = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', '8786'], cwd=ROOT / 'site', env=env, stdout=log, stderr=log)
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            # Playwright waits for the app to listen before beginning any login/write.
            import time
            for _ in range(50):
                try:
                    with urllib.request.urlopen(BASE + '/api/config', timeout=1) as response:
                        config = json.load(response)
                    assert config['url'] == API
                    break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(.2)
            else:
                raise RuntimeError('Local Next server did not start')
            try:
                business_flow(browser)
            except Exception:
                for role, page in PAGES.items():
                    shot(page, 'failure-' + role)
                raise
            finally:
                browser.close()
    RESULT['status'] = 'PASS'
except Exception as error:
    RESULT['status'] = 'FAIL'
    RESULT['failure'] = str(error)
    for role, page in PAGES.items():
        try:
            shot(page, 'failure-' + role)
        except Exception:
            pass
    raise
finally:
    if server:
        server.terminate()
        server.wait(timeout=15)
    (OUT / 'results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))
