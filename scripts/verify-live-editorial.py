"""Explicitly authorized live one-paper workflow; never run as routine CI.
Requires --allow-production-test, a private three-email accounts JSON, and private output.
Uses ordinary UI writes and normal verified sessions, never service-role browser access.
Phases resume from state.json; only the unique [E2E TEST] manuscript may be changed.
uv run --with playwright --with pymupdf --with certifi python scripts/verify-live-editorial.py ...
"""
import argparse
import hashlib
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from zoneinfo import ZoneInfo

import certifi
import pymupdf
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
REF = 'lvtdnrmwunahgwutafhv'
BASE = 'https://co-rnbd.org'
API = 'https://' + REF + '.supabase.co'
PHASES = ['initial','assign1','review1','revision','resubmit','assign2','review2','final','inspect']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--accounts', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--allow-production-test', action='store_true', required=True)
parser.add_argument('--phase', choices=['all','auth','close','audit'] + PHASES, default='all')
args = parser.parse_args()
assert args.allow_production_test
ACCOUNTS = json.loads(args.accounts.read_text())
assert set(ACCOUNTS) == {'chief','reviewer1','reviewer2'}
assert len(set(ACCOUNTS.values())) == 3 and all(re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', s) for s in ACCOUNTS.values())
assert args.accounts.stat().st_mode & 0o077 == 0, 'Accounts file must be private'
OUT = args.output.resolve()
OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
assert subprocess.run(['git','-C',str(OUT),'rev-parse','--is-inside-work-tree'],capture_output=True).returncode != 0, 'Private evidence must be outside a Git working tree'
os.chmod(OUT, 0o700)
STATE_PATH = OUT / 'state.json'
STATE = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {'run_id':datetime.now(ZoneInfo('Asia/Seoul')).strftime('%Y%m%d-%H%M')+'-'+uuid.uuid4().hex[:6], 'completed':[], 'checks':[], 'issues':[]}
TITLE = '[E2E TEST '+STATE['run_id']+'] 논문심사 시스템 전체 절차 검증'
TLS = ssl.create_default_context(cafile=certifi.where())
PAGES = {}
ACTORS = {}
BROWSER_ERRORS = []


def save():
    STATE_PATH.write_text(json.dumps(STATE, ensure_ascii=False, indent=2))
    os.chmod(STATE_PATH, 0o600)


def record(name):
    if name not in STATE['checks']: STATE['checks'].append(name)
    save()
    print('PASS: ' + name, flush=True)


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def sql(query, write=False):
    command = ['sh','scripts/supabase.sh','db','query','--remote='+REF, '--yes' if write else '--read-only', query]
    r = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if r.returncode: raise RuntimeError('Scoped database verification failed')
    data = json.loads(r.stdout[r.stdout.find('{'):])
    return data['rows'][0]['value'] if data.get('rows') else None


def request(url, payload=None, admin_key=None):
    headers = {'Content-Type':'application/json'}
    if admin_key: headers.update(apikey=admin_key, Authorization='Bearer '+admin_key)
    data = json.dumps(payload).encode() if payload is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), context=TLS, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError('Scoped Auth operation HTTP '+str(error.code)) from None


def paper():
    if not STATE.get('paper_id'): return None
    p = sql("select to_jsonb(p)||jsonb_build_object('reviews',coalesce((select jsonb_agg(r) from public.reviews r where r.paper_id=p.id),'[]'::jsonb),'files',coalesce((select jsonb_agg(f) from public.paper_files f where f.paper_id=p.id),'[]'::jsonb)) value from public.papers p where p.id="+literal(STATE['paper_id']))
    assert p and p['title'] == TITLE and p['owner_id'] == ACTORS['chief']['id'] and p['track'] == 'master_eng', 'Wrong manuscript'
    return p


def same_time(a,b):
    return bool(a and b) and datetime.fromisoformat(a.replace('Z','+00:00')) == datetime.fromisoformat(b.replace('Z','+00:00'))


def current_reviews(p):
    return [r for r in p['reviews'] if same_time(r['manuscript_submitted_at'],p['submitted_at']) and not r['revoked_at'] and r['review_state'] != 'declined']


def snap(page,name):
    for width in [1440,390]:
        page.set_viewport_size({'width':width,'height':1000})
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Page overflow'
        page.evaluate('window.scrollTo(0,0)')
        target = OUT / (name+'-'+str(width)+'.png')
        page.screenshot(path=str(target),full_page=True)
        os.chmod(target,0o600)
    page.set_viewport_size({'width':1440,'height':1000})


def fresh(role,path='/submission.html'):
    page = PAGES[role]
    page.goto(BASE+path,wait_until='networkidle')
    expect(page.locator('#chair-workspace' if path=='/chair.html' else '#workspace')).to_be_visible(timeout=20000)
    return page


def desk(role):
    page = fresh(role,'/chair.html')
    page.locator('[data-open="'+STATE['paper_id']+'"]').click()
    expect(page.locator('#chair-detail')).to_be_visible()
    expect(page.locator('#chair-message')).to_contain_text('최신')
    return page


def wait_mail(total):
    end = time.time()+240
    while time.time()<end:
        rows = sql("select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'status',status,'recipient',recipient_email,'recipient_id',recipient_id,'provider_id',provider_id,'attempts',attempts,'last_error',last_error,'is_test',is_test,'created_at',created_at)),'[]'::jsonb) value from app_private.review_email_outbox where paper_id="+literal(STATE['paper_id']))
        assert all(r['recipient'] in ACCOUNTS.values() and not r['is_test'] for r in rows), 'Unexpected recipient or bypass'
        assert len(rows)==total, 'Unexpected workflow mail count: '+str(len(rows))+' expected '+str(total)
        states = Counter(r['status'] for r in rows)
        print('MAIL: '+str(total)+' expected, '+str(dict(states)),flush=True)
        STATE['mail'] = rows; save()
        if states.get('sent',0)==total:
            assert all(r['provider_id'] and not r['last_error'] for r in rows)
            return
        assert not any(r['status'] in ['failed','uncertain','cancelled'] for r in rows), 'Mail requires investigation'
        # Dispatch only when no unrelated pending event could be sent by this call.
        ids=','.join(literal(a['id'])+'::uuid' for a in ACTORS.values())
        sql("do $$ begin if not exists(select 1 from app_private.review_email_outbox where status in ('queued','sending','retry') and (paper_id is distinct from "+literal(STATE['paper_id'])+"::uuid or recipient_id not in ("+ids+"))) then perform app_private.process_review_email_queue(); end if; end $$; select true value;",write=True)
        time.sleep(8)
    raise RuntimeError('Mail acknowledgment wait timed out; resume this phase')


def initial():
    p = paper()
    if not p:
        found = sql('select coalesce(jsonb_agg(id),\'[]\'::jsonb) value from public.papers where title='+literal(TITLE)+' and owner_id='+literal(ACTORS['chief']['id']))
        assert len(found)<=1
        if found: STATE['paper_id']=found[0]; save(); p=paper()
    page = fresh('chief')
    if not p:
        page.locator('#new-paper').click()
        page.locator('#paper-title').fill(TITLE)
        page.locator('#paper-abstract').fill('이 원고는 논문심사 시스템 전체 절차와 이메일 알림을 확인하는 운영 테스트입니다. 실제 연구 성과나 기업 자료를 포함하지 않습니다.')
        page.locator('#paper-track').select_option('master_eng')
        page.locator('[data-author=full_name]').fill('시스템 검증용 테스트 투고자')
        page.locator('[data-author=affiliation]').fill('시스템 검증용 임시 소속')
        page.locator('[data-author=email]').fill(ACCOUNTS['chief'])
        page.locator('#paper-file').set_input_files(str(OUT/'manuscript-v1.pdf'))
        page.locator('[data-save=draft]').click()
        expect(page.locator('#message')).to_contain_text('초안을 저장했습니다')
        found=sql('select jsonb_agg(id) value from public.papers where title='+literal(TITLE)+' and owner_id='+literal(ACTORS['chief']['id']))
        assert len(found)==1; STATE['paper_id']=found[0]; save(); p=paper()
    if p['status']=='draft':
        page=fresh('chief');page.locator('[data-action=author][data-id="'+p['id']+'"]').click()
        expect(page.locator('#paper-file-links')).to_be_visible()
        page.locator('[data-save=submitted]').click()
        expect(page.locator('#message')).to_contain_text('원고가 제출되었습니다')
    p=paper(); assert p['status']=='submitted' and len(p['files'])==1
    STATE['v1_submitted_at']=p['submitted_at']; save(); wait_mail(3);snap(page,'01-author-submitted'); record('live-author-initial-PDF-submission-and-three-real-notifications')


def assign(cycle):
    for role in ['reviewer1','reviewer2']:
        p=paper()
        if any(r['reviewer_id']==ACTORS[role]['id'] for r in current_reviews(p)): continue
        page=desk('chief')
        page.locator('#chair-reviewer').select_option(ACTORS[role]['id'])
        page.locator('#chair-assignment-form button[type=submit]').click()
        expect(page.locator('#chair-message')).to_contain_text('배정과 원고 상태를 저장')
        expect(page.locator('#chair-assignment-form button[type=submit]')).to_be_enabled()
    assert len(current_reviews(paper()))==2
    outside=fresh('reviewer2','/chair.html')
    if outside.locator('[data-open="'+STATE['paper_id']+'"]').count():
        issue='AE desk includes an assigned review outside the AE field'
        if issue not in STATE['issues']:STATE['issues'].append(issue)
        snap(outside,'issue-outside-field-AE-cycle-'+str(cycle));save()
    wait_mail(5 if cycle==1 else 15);snap(desk('chief'),'0'+str(cycle+1)+'-chief-assigned');record('live-chief-two-reviewer-assignment-cycle-'+str(cycle))


def reviews(cycle):
    for role in ['reviewer1','reviewer2']:
        p=paper(); row=next(r for r in current_reviews(p) if r['reviewer_id']==ACTORS[role]['id'])
        if row['review_state']=='submitted':
            assert STATE['run_id'] in row['comments']; continue
        page=fresh(role)
        page.locator('[data-tab=reviewer]').click()
        page.locator('[data-action=review][data-id="'+p['id']+'"]').click()
        page.locator('#review-conflict').check()
        page.locator('#review-recommendation').select_option('revise' if cycle==1 and role=='reviewer1' else 'accept')
        page.locator('#review-comments').fill('[E2E TEST '+STATE['run_id']+'] '+('검증 방법을 보완한 수정본을 요청합니다. 원고 심사 자동 알림 테스트 의견입니다.' if cycle==1 else '수정된 검증 방법을 확인했습니다. 최종 채택을 권고하는 시스템 테스트 의견입니다.'))
        page.locator('[data-review-action=submit]').click()
        expect(page.locator('#message')).to_contain_text('심사 의견을 제출했습니다')
    assert all(r['review_state']=='submitted' for r in current_reviews(paper()))
    wait_mail(9 if cycle==1 else 19);record('live-two-reviewers-opinions-and-four-editorial-notifications-cycle-'+str(cycle))


def publish(status):
    p=paper()
    if p['status']!=status:
        page=desk('reviewer1')
        expect(page.locator('#chair-assignment-form')).to_be_hidden()
        expect(page.locator('#chair-decision-submit')).to_be_enabled()
        page.locator('#desk-decision').select_option(status)
        page.locator('#desk-note').fill('[E2E TEST '+STATE['run_id']+'] '+('시스템 검증을 위해 같은 원고에 수정 PDF를 재제출해 주세요.' if status=='revision' else '두 명의 재심 의견을 확인하여 시스템 테스트 원고를 최종 채택합니다. 실제 학술 원고 채택을 의미하지 않습니다.'))
        page.locator('#chair-decision-submit').click()
        expect(page.locator('#chair-publish-dialog')).to_be_visible()
        page.locator('#chair-publish-confirm').click()
        expect(page.locator('#chair-message')).to_contain_text('저자 포털에 공개했습니다')
    p=paper();assert p['status']==status and p['decided_by']==ACTORS['reviewer1']['id']
    wait_mail(10 if status=='revision' else 20)
    page=fresh('chief');page.locator('[data-action=author][data-id="'+p['id']+'"]').click()
    expect(page.locator('#author-review-feedback article')).to_have_count(2)
    feedback=page.locator('#author-review-feedback').inner_text()
    assert all(ACCOUNTS[r] not in feedback for r in ['reviewer1','reviewer2'])
    snap(page,'04-author-revision' if status=='revision' else '07-author-final');record('live-AE-'+status+'-publication-author-anonymous-feedback-and-email')


def resubmit():
    p=paper()
    if same_time(p['submitted_at'],STATE['v1_submitted_at']):
        assert p['status']=='revision'
        page=fresh('chief');page.locator('[data-action=author][data-id="'+p['id']+'"]').click()
        if max(f['version'] for f in p['files'])<2:page.locator('#paper-file').set_input_files(str(OUT/'manuscript-v2.pdf'))
        page.locator('[data-save=submitted]').click()
        expect(page.locator('#message')).to_contain_text('원고가 제출되었습니다')
    p=paper();assert p['status']=='submitted' and len(p['files'])==2 and not current_reviews(p)
    assert not same_time(p['submitted_at'],STATE['v1_submitted_at'])
    STATE['v2_submitted_at']=p['submitted_at'];save();wait_mail(13);record('live-author-revised-PDF-new-submission-snapshot-and-three-notifications')


def inspect():
    p=paper();assert p['status']=='accepted' and len(p['files'])==2 and len(p['reviews'])==4
    assert len(current_reviews(p))==2
    page=desk('chief');expect(page.locator('#chair-reviews .history')).to_have_count(2);snap(page,'08-chief-history')
    wrong=fresh('reviewer2','/chair.html')
    if wrong.locator('[data-open="'+p['id']+'"]').count():
        issue='AE desk includes an assigned review outside the AE field'
        if issue not in STATE['issues']:STATE['issues'].append(issue)
        snap(wrong,'issue-outside-field-AE')
    record('live-four-reviews-two-PDFs-chief-history-and-field-scope-inspection')



def audit():
    p=paper();assert p['status']=='accepted'
    page=desk('reviewer1')
    response=page.request.get(BASE+'/legacy/chair.js')
    assert response.status==200 and hashlib.sha256(response.body()).digest()==hashlib.sha256((ROOT/'site/public/legacy/chair.js').read_bytes()).digest(), 'Production code is not the reviewed fix'
    expect(page.locator('#chair-assignment-form')).to_be_hidden()
    snap(page,'09-fixed-AE1-desk')
    outside=fresh('reviewer2','/chair.html')
    assert outside.locator('[data-open="'+p['id']+'"]').count()==0
    assert outside.locator('#chair-track-filter option[value=master_eng]').count()==0
    snap(outside,'10-fixed-AE2-scope')
    payload={'p_paper_id':p['id'],'p_status':'revision','p_note':'E2E forbidden field decision probe',
             'p_presentation':None,'p_session':None,'p_exception_reason':'','p_expected_updated_at':p['updated_at'],'p_expected_reviews':[]}
    # Empty snapshot is an extra no-write guard even if a role regression occurred.
    result=outside.evaluate("""async payload => {const {conferenceClient}=await import('/legacy/conference-client.js');
      const r=await (await conferenceClient()).rpc('chair_publish_decision',payload);
      return {code:r.error?.code,message:r.error?.message};}""",payload)
    assert result.get('code')=='P0001' and result.get('message')=='Chair permission required','Cross-field decision was not refused by role guard'
    STATE['backend_denial']=result
    for role in ['reviewer1','reviewer2']:
        page=fresh(role);page.locator('[data-tab=reviewer]').click()
        page.locator('[data-action=review][data-id="'+p['id']+'"]').click()
        for version in [1,2]:
            file=next(f for f in p['files'] if f['file_stage']=='submission' and f['version']==version)
            with page.expect_download() as event:
                page.locator('#review-file-links [data-file="'+file['storage_path']+'"]').click()
            downloaded=OUT/('download-'+role+'-v'+str(version)+'.pdf')
            event.value.save_as(str(downloaded));os.chmod(downloaded,0o600)
            assert hashlib.sha256(downloaded.read_bytes()).digest()==hashlib.sha256((OUT/('manuscript-v'+str(version)+'.pdf')).read_bytes()).digest()
        snap(page,'11-'+role+'-PDF-history')
    page=fresh('chief');page.locator('[data-action=author][data-id="'+p['id']+'"]').click()
    expect(page.locator('#author-review-feedback article')).to_have_count(2)
    feedback=page.locator('#author-review-feedback').inner_text()
    assert '수정된 검증 방법을 확인했습니다' in feedback
    assert all(ACCOUNTS[r] not in feedback for r in ['reviewer1','reviewer2'])
    assert paper()['status']=='accepted';wait_mail(20)
    STATE['resolved_issues']=list(STATE['issues']);record('deployed-AE-scope-role-denial-both-reviewer-PDF-downloads-and-author-final-feedback')


def preflight():
    values=','.join(literal(e) for e in ACCOUNTS.values())
    users=sql("select jsonb_agg(jsonb_build_object('id',u.id,'email',u.email,'verified',u.email_confirmed_at is not null,'role',s.role,'complete',coalesce(length(trim(p.full_name)),0)>0 and coalesce(length(trim(p.affiliation)),0)>0)) value from auth.users u left join public.profiles p on p.user_id=u.id left join public.staff_roles s on s.user_id=u.id where u.email in ("+values+")")
    assert len(users)==3 and all(u['verified'] and u['complete'] for u in users)
    for role,email in ACCOUNTS.items():ACTORS[role]=next(u for u in users if u['email']==email)
    assert ACTORS['chief']['role']=='chair' and all(ACTORS[r]['role'] is None for r in ['reviewer1','reviewer2'])
    flags=sql("select jsonb_build_object('enabled',enabled,'review_submitted',review_submitted_enabled,'paper_submitted',paper_submitted_enabled,'author_receipt',author_receipt_enabled,'chief_only',review_submitted_chair_ids=array["+literal(ACTORS['chief']['id'])+"::uuid]) value from app_private.review_email_config")
    assert all(flags.values()), 'Unexpected mail config'
    save()


def make_pdfs():
    for version in [1,2]:
        path=OUT/('manuscript-v'+str(version)+'.pdf')
        if path.exists():continue
        doc=pymupdf.open();page=doc.new_page();page.insert_text((60,70),'E2E SYSTEM TEST ONLY - NOT A RESEARCH MANUSCRIPT\nRun '+STATE['run_id']+' / version '+str(version)+'\nNo research, company, or participant data.');doc.save(path);doc.close();os.chmod(path,0o600)


def authenticate(browser):
    missing=[r for r in ACCOUNTS if not (OUT/('.auth-'+r+'.json')).exists()]
    admin_key=None
    if missing:
        result=subprocess.run(['sh','scripts/supabase.sh','projects','api-keys','--remote='+REF,'--reveal','--output','json'],cwd=ROOT,capture_output=True,text=True,check=True)
        keys=json.loads(result.stdout);admin_key=next(k['api_key'] for k in keys if k['id']=='service_role')
        del result,keys
    for role in ACCOUNTS:
        target=OUT/('.auth-'+role+'.json')
        context=browser.new_context(storage_state=str(target) if target.exists() else None,viewport={'width':1440,'height':1000})
        page=context.new_page();page.on('pageerror',lambda error:BROWSER_ERRORS.append(type(error).__name__))
        if target.exists():page.goto(BASE+'/submission.html',wait_until='networkidle')
        else:
            link=request(API+'/auth/v1/admin/generate_link',{'type':'magiclink','email':ACCOUNTS[role]},admin_key)
            assert link.get('hashed_token'), 'No login token returned'
            page.goto(BASE+'/submission.html#auth-magiclink='+link['hashed_token'],wait_until='networkidle')
            del link
        expect(page.locator('#workspace')).to_be_visible(timeout=25000)
        expect(page.locator('#account-email')).to_contain_text(ACCOUNTS[role])
        context.storage_state(path=str(target));os.chmod(target,0o600)
        PAGES[role]=page
    admin_key=None;record('three-designated-verified-accounts-normal-Auth-sessions')


def close_sessions():
    config=request(BASE+'/api/config')
    for role in ACCOUNTS:
        target=OUT/('.auth-'+role+'.json')
        if not target.exists():continue
        state=json.loads(target.read_text())
        for origin in state['origins']:
            for item in origin['localStorage']:
                if item['name'].endswith('-auth-token'):
                    token=json.loads(item['value'])['access_token']
                    req=urllib.request.Request(API+'/auth/v1/logout?scope=local',data=b'',headers={'apikey':config['publishableKey'],'Authorization':'Bearer '+token},method='POST')
                    with urllib.request.urlopen(req,context=TLS,timeout=30) as response:assert response.status==204
        target.unlink()
    record('only-test-sessions-revoked-private-session-files-removed')


try:
    preflight()
    if args.phase=='close':close_sessions()
    else:
        make_pdfs()
        with sync_playwright() as pw:
            browser=pw.chromium.launch(headless=True)
            try:
                authenticate(browser)
                actions={'initial':initial,'assign1':lambda:assign(1),'review1':lambda:reviews(1),'revision':lambda:publish('revision'),'resubmit':resubmit,'assign2':lambda:assign(2),'review2':lambda:reviews(2),'final':lambda:publish('accepted'),'inspect':inspect,'audit':audit}
                for name in (PHASES if args.phase=='all' else [] if args.phase=='auth' else [args.phase]):
                    if name in STATE['completed']:continue
                    print('PHASE: '+name,flush=True);STATE['active_phase']=name;save();actions[name]();STATE['completed'].append(name);save()
            finally:
                for role,page in PAGES.items():
                    try:page.context.storage_state(path=str(OUT/('.auth-'+role+'.json')));os.chmod(OUT/('.auth-'+role+'.json'),0o600)
                    except Exception:pass
                browser.close()
        assert not BROWSER_ERRORS, 'Browser runtime error'
    STATE.pop('last_error',None);save()
except Exception as error:
    # Never include Auth URLs/tokens, HTTP headers or admin response bodies in logs.
    detail=re.sub(r'#auth-magiclink=[^\s\'\"]+','#auth-magiclink=<redacted>',str(error))
    detail=re.sub(r'eyJ[A-Za-z0-9_.-]+','<redacted-jwt>',detail)
    STATE['last_error']=detail[:1000];save();print('FAILED: '+type(error).__name__+'; private state contains sanitized diagnostic',flush=True)
    raise SystemExit(1)
