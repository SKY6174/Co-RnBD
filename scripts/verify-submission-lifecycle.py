"""Real local Auth/Postgres/Storage + browser lifecycle verification (never production)."""
import argparse
import hashlib
import json
import secrets
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'outputs/submission-lifecycle-20261015'
OUT.mkdir(parents=True, exist_ok=True)
BASE = 'http://127.0.0.1:8770'
CONTAINER = 'supabase_db_co-rnbd-lifecycle-20261015'
LOCAL = ROOT / 'tmp/submission-lifecycle'
status = json.loads(subprocess.run(['supabase', 'status', '--workdir', str(LOCAL), '-o', 'json'], capture_output=True, text=True, check=True).stdout)
API = status['API_URL']
assert urlparse(API).hostname in ('127.0.0.1', 'localhost'), 'Local Supabase only'
assert urlparse(BASE).hostname == '127.0.0.1', 'Local browser only'


def request(method, path, payload=None, token=None, admin=False, raw=None):
    key = status['SERVICE_ROLE_KEY'] if admin else status['ANON_KEY']
    headers = {'apikey': key, 'Authorization': 'Bearer ' + (token or key)}
    data = None
    if raw is not None:
        data = raw
        headers['Content-Type'] = 'application/pdf'
    elif payload is not None:
        data = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    headers['Prefer'] = 'return=representation'
    try:
        with urllib.request.urlopen(urllib.request.Request(API + path, data=data, headers=headers, method=method)) as response:
            body = response.read()
            return response.status, json.loads(body) if 'json' in response.headers.get('Content-Type', '') else body
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def sql(statement):
    result = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'], input=statement, capture_output=True, text=True, check=True)
    return result.stdout.strip()


def prepare():
    fixture_path = OUT / '.env.demo-fixtures'
    if fixture_path.exists():
        return json.loads(fixture_path.read_text())
    fixtures = {'password': secrets.token_urlsafe(24), 'actors': {}}
    for role in ('author', 'reviewer', 'chair', 'outsider'):
        email = f'lifecycle-{role}@example.test'
        code, actor = request('POST', '/auth/v1/admin/users', {'email': email, 'password': fixtures['password'], 'email_confirm': True, 'user_metadata': {'full_name': f'검증 {role}'}}, admin=True)
        assert code in (200, 201), (role, code, actor)
        fixtures['actors'][role] = {'id': actor['id'], 'email': email}
    chair_id = fixtures['actors']['chair']['id']
    sql(f"insert into public.staff_roles(user_id,role) values ('{chair_id}','chair');")
    fixture_path.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2))
    fixture_path.chmod(0o600)
    return fixtures


FIXTURES = prepare()
EVIDENCE = []
NETWORK = []
PAGES = {}
ERRORS = []
PAPER_ID = None


def record(name, details):
    EVIDENCE.append({'step': name, 'details': details})
    (OUT / 'evidence.json').write_text(json.dumps(EVIDENCE, ensure_ascii=False, indent=2))
    print(name + ': PASS', flush=True)


def db_snapshot(name):
    if not PAPER_ID:
        return
    data = json.loads(sql(f"""select json_build_object(
      'paper',(select row_to_json(p) from public.papers p where id='{PAPER_ID}'),
      'authors',(select json_agg(a order by sort_order) from public.paper_authors a where paper_id='{PAPER_ID}'),
      'files',(select json_agg(f order by version) from public.paper_files f where paper_id='{PAPER_ID}'),
      'reviews',(select json_agg(r order by assigned_at) from public.reviews r where paper_id='{PAPER_ID}'),
      'settings',(select row_to_json(s) from public.conference_settings s where edition_year=2026));"""))
    (OUT / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False, indent=2))
    return data


def shot(name, page, selector):
    page.locator(selector).screenshot(path=str(OUT / f'{name}.png'), style='.site-header { visibility: hidden !important; }')


def token(role):
    return PAGES[role].evaluate("JSON.parse(localStorage.getItem(Object.keys(localStorage).find(k => k.endsWith('-auth-token')))).access_token")


def call(role, method, path, payload=None, raw=None):
    return request(method, path, payload, token(role), raw=raw)


def login(browser, role):
    context = browser.new_context(viewport={'width': 1440, 'height': 1000})
    page = context.new_page()
    page.on('pageerror', lambda error: ERRORS.append({'role': role, 'error': str(error)}))
    def response_log(response):
        if response.url.startswith(API):
            NETWORK.append({'role': role, 'method': response.request.method, 'path': urlparse(response.url).path, 'status': response.status})
    page.on('response', response_log)
    page.goto(BASE + '/submission.html', wait_until='domcontentloaded')
    page.locator('#auth-panel').wait_for(state='visible')
    page.locator('#auth-email').fill(FIXTURES['actors'][role]['email'])
    page.locator('#auth-password').fill(FIXTURES['password'])
    page.locator('#email-auth-form button[type=submit]').click()
    expect(page.locator('#welcome')).to_contain_text('작업 공간')
    expect(page.locator('#account-email')).to_have_text(FIXTURES['actors'][role]['email'])
    PAGES[role] = page
    return page


def profile(page, role):
    page.locator('[data-tab=profile]').click()
    page.locator('#profile-name').fill({'author':'검증 저자','reviewer':'검증 심사위원','chair':'검증 위원장','outsider':'비배정 회원'}[role])
    page.locator('#profile-affiliation').fill('Co-R&BD 로컬 검증 기관')
    if role == 'reviewer':
        page.locator('[name=expertise-track][value=master_eng]').check()
    page.locator('#profile-form button[type=submit]').click()
    expect(page.locator('#message')).to_contain_text('내 정보를 저장했습니다')
    page.locator('[data-tab=author]').click()


def reload(page, tab='author'):
    page.reload(wait_until='domcontentloaded')
    page.locator('#workspace').wait_for(state='visible')
    page.locator(f'[data-tab={tab}]').click()


def open_paper(page, role):
    if role == 'chair':
        page.locator(f'[data-action=chair][data-id="{PAPER_ID}"]').click()
        page.locator('#chair-form').wait_for(state='visible')
    elif role == 'reviewer':
        page.locator(f'[data-action=review][data-id="{PAPER_ID}"]').click()
        page.locator('#review-form').wait_for(state='visible')
    else:
        page.locator(f'[data-action=author][data-id="{PAPER_ID}"]').click()
        page.locator('#paper-form').wait_for(state='visible')


def operation_page(chair):
    page = chair.context.new_page()
    page.on('pageerror', lambda error: ERRORS.append({'role': 'operations', 'error': str(error)}))
    page.goto(BASE + '/operations.html', wait_until='domcontentloaded')
    page.locator('#operations-workspace').wait_for(state='visible', timeout=12000)
    page.locator('#paper-management-status').wait_for(state='visible')
    return page


def set_stages(ops, submissions=True, reviews=False, final=False):
    for selector, checked in [('#paper-submissions-open', submissions), ('#paper-reviews-open', reviews), ('#paper-final-open', final)]:
        ops.locator(selector).set_checked(checked)
    for selector in ['#paper-submission-deadline','#paper-review-deadline','#paper-final-deadline']:
        ops.locator(selector).fill('')
    ops.locator('#paper-notice').fill('로컬 검증 전용 원고입니다. 운영 데이터와 무관합니다.')
    ops.locator('#paper-settings-form button[type=submit]').click()
    expect(ops.locator('#operations-message')).to_contain_text('운영 설정을 저장했습니다')
    values = json.loads(sql('select row_to_json(s) from public.conference_settings s where edition_year=2026;'))
    assert (values['submissions_open'],values['reviews_open'],values['final_uploads_open']) == (submissions,reviews,final)


def pdf_fixture(name, title):
    import pymupdf
    path = OUT / name
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((60,70),title,fontsize=20)
    page.insert_text((60,110),'LOCAL TEST ONLY - no participant or research data',fontsize=12)
    doc.save(path)
    return path


def verify(mode):
    global PAPER_ID
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel='chrome',headless=True)
        try:
            chair = login(browser,'chair')
            if mode == 'smoke':
                try:
                    operation_page(chair)
                except Exception:
                    page = chair.context.pages[-1]
                    page.screenshot(path=str(OUT/'operations-before.png'),full_page=True)
                    print(json.dumps({'browser_errors':ERRORS,'status':page.locator('#operations-message').inner_text()},ensure_ascii=False),flush=True)
                    raise
                return
            profile(chair,'chair')
            ops = operation_page(chair)
            set_stages(ops)
            record('01-chair-stages', 'Chair UI saved local submissions=open, review/final=closed')
            shot('01-chair-stages',ops,'#paper-management')
            author = login(browser,'author');profile(author,'author')
            reviewer = login(browser,'reviewer');profile(reviewer,'reviewer')
            outsider = login(browser,'outsider')
            v1=pdf_fixture('submission-v1.pdf','Submission v1')
            v2=pdf_fixture('submission-v2.pdf','Revised submission v2')
            final=pdf_fixture('final-v3.pdf','Accepted final manuscript v3')
            author.locator('#new-paper').click()
            title='[LOCAL E2E] 현장 적용 연구 검증 '+time.strftime('%H%M%S')
            author.locator('#paper-title').fill(title)
            author.locator('#paper-abstract').fill('이 원고는 투고부터 심사, 위원장 판정과 최종본 제출까지 검증하기 위한 합성 연구 자료입니다.')
            author.locator('[data-author=full_name]').fill('검증 저자')
            author.locator('[data-author=affiliation]').fill('Co-R&BD 로컬 검증 기관')
            author.locator('[data-author=email]').fill(FIXTURES['actors']['author']['email'])
            author.locator('[data-author=note]').fill('교신저자')
            author.locator('#paper-file').set_input_files(str(v1))
            author.locator('[data-save=draft]').click()
            expect(author.locator('#message')).to_contain_text('초안을 저장했습니다')
            PAPER_ID = sql("select id from public.papers where title='"+title+"';")
            assert PAPER_ID
            state=db_snapshot('02-draft');assert state['paper']['status']=='draft' and len(state['authors'])==1 and len(state['files'])==1
            record('02-draft', {'paper_id':PAPER_ID,'file_version':1,'authors':1});shot('02-draft',author,'#tab-author')
            code,data=call('author','PATCH',f'/rest/v1/papers?id=eq.{PAPER_ID}',{'status':'accepted'})
            assert code>=400,(code,data)
            record('03-author-cannot-decide', {'status':code})
            open_paper(author,'author');author.locator('[data-save=submitted]').click()
            expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
            state=db_snapshot('04-submitted');assert state['paper']['status']=='submitted' and state['paper']['submitted_at']
            record('04-submitted',state['paper']['submitted_at']);shot('04-submitted',author,'#tab-author')
            code,rows=call('outsider','GET',f'/rest/v1/papers?id=eq.{PAPER_ID}&select=id')
            assert code==200 and rows==[]
            code,_=call('outsider','GET','/storage/v1/object/authenticated/paper-pdfs/'+state['files'][0]['storage_path']);assert code>=400
            record('05-unassigned-access-denied',{'paper_rows':0,'storage_status':code})
            reload(chair,'chair');open_paper(chair,'chair')
            chair.locator('#reviewer-email').fill(FIXTURES['actors']['reviewer']['email']);chair.locator('#assign-reviewer').click()
            expect(chair.locator('#message')).to_contain_text('심사위원을 배정했습니다')
            state=db_snapshot('06-assigned');assert state['paper']['status']=='under_review' and state['reviews'][0]['review_state']=='assigned'
            record('06-assigned',state['reviews'][0]['id']);shot('06-assigned',chair,'#chair-form')
            reload(reviewer,'reviewer');open_paper(reviewer,'reviewer')
            assert reviewer.locator('[data-review-action=submit]').is_disabled()
            rid=state['reviews'][0]['id']
            code,_=call('reviewer','PATCH',f'/rest/v1/reviews?id=eq.{rid}',{'review_state':'draft','comments':'닫힌 단계 검증'})
            assert code>=400
            record('07-review-closed-denied',{'status':code})
            set_stages(ops,reviews=True)
            reload(reviewer,'reviewer');open_paper(reviewer,'reviewer')
            with reviewer.expect_download() as download:
                reviewer.locator('#review-file-links [data-file]').first.click()
            assert Path(download.value.path()).read_bytes()==v1.read_bytes()
            reviewer.locator('#review-comments').fill('현장 적용 결과와 검증 방법을 보완해 주세요. 수정 후 채택을 권고합니다.')
            reviewer.locator('[data-review-action=draft]').click()
            expect(reviewer.locator('#message')).to_contain_text('임시저장')
            state=db_snapshot('08-review-draft');assert state['reviews'][0]['review_state']=='draft' and state['reviews'][0]['submitted_at'] is None
            record('08-review-draft','Real private PDF download and draft DB row verified')
            open_paper(reviewer,'reviewer');reviewer.locator('#review-conflict').check();reviewer.locator('#review-recommendation').select_option('revise')
            reviewer.locator('[data-review-action=submit]').click();expect(reviewer.locator('#message')).to_contain_text('심사 의견을 제출했습니다')
            state=db_snapshot('09-review-submitted');assert state['reviews'][0]['submitted_at'] and state['reviews'][0]['recommendation']=='revise'
            record('09-review-submitted',state['reviews'][0]['submitted_at']);shot('09-review-submitted',reviewer,'#tab-reviewer')
            reload(chair,'chair');open_paper(chair,'chair')
            expect(chair.locator('#assigned-reviewers')).to_contain_text('현장 적용 결과')
            chair.locator('#chair-status').select_option('revision');chair.locator('#chair-note').fill('현장 적용 결과를 보완하고 수정본을 다시 제출해 주세요.')
            chair.locator('#chair-form button[type=submit]').click();expect(chair.locator('#message')).to_contain_text('판정 및 세션 배정 상태를 저장했습니다')
            state=db_snapshot('10-revision');assert state['paper']['status']=='revision'
            reload(author);open_paper(author,'author');expect(author.locator('#message')).to_contain_text('현장 적용 결과를 보완')
            record('10-revision-notification','Chair review and decision note displayed to author after reload');shot('10-revision-notification',author,'#paper-form')
            author.locator('#paper-abstract').fill('수정본: 현장 적용 결과와 검증 방법을 보완했습니다. 이 자료는 전체 투고 절차 검증만을 위한 합성 연구 자료입니다.')
            author.locator('#paper-file').set_input_files(str(v2));author.locator('[data-save=submitted]').click()
            expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
            state=db_snapshot('11-resubmitted');assert state['paper']['status']=='submitted' and len(state['files'])==2
            record('11-resubmitted',{'versions':[f['version'] for f in state['files']]})
            reload(chair,'chair');open_paper(chair,'chair')
            expect(chair.locator('#chair-file-links')).to_contain_text('투고본 v2')
            chair.locator('#chair-status').select_option('accepted');chair.locator('#chair-presentation').select_option('oral');chair.locator('#chair-session').select_option('oral_1')
            chair.locator('#chair-note').fill('수정본을 검토하여 채택합니다. 최종 PDF를 제출해 주세요.')
            chair.locator('#chair-form button[type=submit]').click();expect(chair.locator('#message')).to_contain_text('판정 및 세션 배정 상태를 저장했습니다')
            state=db_snapshot('12-accepted');assert state['paper']['status']=='accepted' and state['paper']['decided_at'] and state['paper']['assigned_session']=='oral_1'
            reload(author);open_paper(author,'author');expect(author.locator('#message')).to_contain_text('채택합니다')
            assert author.locator('#final-submit').is_disabled()
            blocked_path=f"{FIXTURES['actors']['author']['id']}/{PAPER_ID}/closed-final.pdf"
            code,_=call('author','POST','/storage/v1/object/paper-pdfs/'+blocked_path,raw=final.read_bytes());assert code>=400
            record('12-accepted-final-closed',{'decided_at':state['paper']['decided_at'],'closed_storage_status':code});shot('12-accepted',author,'#paper-form')
            set_stages(ops,reviews=True,final=True)
            reload(author);open_paper(author,'author');author.locator('#final-file').set_input_files(str(final));author.locator('#final-submit').click()
            expect(author.locator('#message')).to_contain_text('최종 PDF를 업로드했습니다')
            state=db_snapshot('13-final');assert len(state['files'])==3 and state['files'][-1]['file_stage']=='final' and state['files'][-1]['version']==3
            record('13-final-uploaded',{'version':3,'stage':'final','paper_status':state['paper']['status']});shot('13-final-uploaded',author,'#final-form')
            reload(chair,'chair');open_paper(chair,'chair')
            with chair.expect_download() as download:
                chair.locator('#chair-file-links [data-file]').filter(has_text='최종본 v3').click()
            assert Path(download.value.path()).read_bytes()==final.read_bytes()
            code,rows=call('reviewer','GET',f'/rest/v1/paper_files?paper_id=eq.{PAPER_ID}&select=file_stage')
            assert code==200 and all(row['file_stage']=='submission' for row in rows) and len(rows)==2
            code,_=call('reviewer','GET','/storage/v1/object/authenticated/paper-pdfs/'+state['files'][-1]['storage_path']);assert code>=400
            record('14-chair-final-verification',{'sha256':hashlib.sha256(final.read_bytes()).hexdigest(),'reviewer_final_download_status':code});shot('14-chair-final-verification',chair,'#chair-form')
            assert not ERRORS,ERRORS
            record('15-browser-errors',{'count':0})
        except Exception:
            if PAPER_ID:
                db_snapshot('failure-state')
            for role, page in PAGES.items():
                page.screenshot(path=str(OUT / f'failure-{role}.png'), full_page=True)
            raise
        finally:
            (OUT/'network.json').write_text(json.dumps(NETWORK,ensure_ascii=False,indent=2))
            (OUT/'browser-errors.json').write_text(json.dumps(ERRORS,ensure_ascii=False,indent=2))
            browser.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--smoke',action='store_true');args=parser.parse_args()
    verify('smoke' if args.smoke else 'full')
