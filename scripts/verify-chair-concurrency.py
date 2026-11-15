"""Real local regression checks for stale reviews and concurrent decisions.
Requires verify-chair-desk.py fixtures. Never connects to production.
uv run --with playwright --with 'psycopg[binary]' python scripts/verify-chair-concurrency.py
"""
import importlib.util
import json
import threading
import time
from pathlib import Path
from urllib.parse import urlparse
import psycopg
from psycopg.types.json import Jsonb
from playwright.sync_api import sync_playwright, expect

spec=importlib.util.spec_from_file_location('lifecycle',Path(__file__).with_name('verify-submission-lifecycle.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
OUT=m.ROOT/'outputs/chair-concurrency-verification';OUT.mkdir(parents=True,exist_ok=True)
fixture=json.loads((m.ROOT/'outputs/chair-desk-verification/final-state.json').read_text())
PID=fixture['paper']['id']
assert fixture['paper']['title'].startswith('[LOCAL CHAIR]')
assert urlparse(m.status['DB_URL']).hostname in ('127.0.0.1','localhost')
TOKENS={}
for role in ('chair','outsider','reviewer','author'):
    code,result=m.request('POST','/auth/v1/token?grant_type=password',{'email':m.FIXTURES['actors'][role]['email'],'password':m.FIXTURES['password']})
    assert code==200
    TOKENS[role]=result['access_token']

def call(role,method,path,payload=None):
    return m.request(method,path,payload,TOKENS[role])

def paper():
    code,rows=call('chair','GET',f'/rest/v1/papers?id=eq.{PID}&select=*,reviews(*)')
    assert code==200 and len(rows)==1
    return rows[0]

def decision(snapshot):
    return {'p_paper_id':PID,'p_status':'accepted','p_note':'최신 심사 의견을 확인한 회귀 검증 판정입니다.',
      'p_presentation':'oral','p_session':'oral_1','p_exception_reason':'','p_expected_updated_at':snapshot['updated_at'],
      'p_expected_reviews':sorted([r for r in snapshot['reviews'] if r['manuscript_submitted_at']==snapshot['submitted_at']],key=lambda r:r['id'])}

RID=next(r['id'] for r in paper()['reviews'] if r['reviewer_id']==m.FIXTURES['actors']['outsider']['id'] and r['manuscript_submitted_at']==paper()['submitted_at'])
EVIDENCE=[]
def record(check,details):
    EVIDENCE.append({'check':check,'details':details});(OUT/'evidence.json').write_text(json.dumps(EVIDENCE,ensure_ascii=False,indent=2));print(check+': PASS',flush=True)

def reopen():
    code,result=call('chair','PATCH',f'/rest/v1/papers?id=eq.{PID}',{'status':'under_review'});assert code==200,(code,result)
    code,result=call('outsider','PATCH',f'/rest/v1/reviews?id=eq.{RID}',{'review_state':'submitted','recommendation':'accept','comments':'원래 심사 의견입니다. 현장 적용 결과를 확인했습니다.','conflict_confirmed':True});assert code==200,(code,result)
    return paper()

def connection(role):
    conn=psycopg.connect(m.status['DB_URL'])
    conn.execute('set local role authenticated')
    conn.execute("select set_config('request.jwt.claim.sub',%s,true)",(m.FIXTURES['actors'][role]['id'],))
    conn.execute("set local statement_timeout='8s'")
    return conn

def publish_sql(conn,payload):
    return conn.execute('select public.chair_publish_decision(%s,%s,%s,%s,%s,%s,%s,%s)',tuple(Jsonb(v) if k=='p_expected_reviews' else v for k,v in payload.items()))

def worker(conn,action):
    result={}
    def run():
        try:
            cursor=action(conn);result['rows']=cursor.rowcount;conn.commit()
        except Exception as error:
            result['error']=str(error);conn.rollback()
    thread=threading.Thread(target=run,daemon=True);thread.start();return thread,result

def wait_for_lock(conn,thread):
    deadline=time.monotonic()+5
    with psycopg.connect(m.status['DB_URL'],autocommit=True) as observer:
        while time.monotonic()<deadline:
            row=observer.execute('select wait_event_type from pg_stat_activity where pid=%s',(conn.info.backend_pid,)).fetchone()
            if row and row[0]=='Lock':return
            assert thread.is_alive(),'Concurrent operation completed before acquiring a required lock'
            time.sleep(.03)
    raise AssertionError('Expected concurrent request to wait for a row lock')

# REST-level optimistic review check, including cached old-client guard.
s=reopen();stale=decision(s)
code,_=call('outsider','PATCH',f'/rest/v1/reviews?id=eq.{RID}',{'recommendation':'reject','comments':'판정 화면이 열린 후 변경된 심사 의견입니다.'});assert code==200
code,result=call('chair','POST','/rest/v1/rpc/chair_publish_decision',stale);assert code>=400 and 'Reviews changed' in str(result),(code,result)
assert paper()['status']=='under_review'
legacy={k:v for k,v in stale.items() if k!='p_expected_reviews'}
code,result=call('chair','POST','/rest/v1/rpc/chair_publish_decision',legacy);assert code>=400 and 'snapshot required' in str(result)
for role in ('author','outsider'):
    code,_=call(role,'POST','/rest/v1/rpc/chair_publish_decision',decision(paper()));assert code>=400
code,result=call('chair','POST','/rest/v1/rpc/chair_publish_decision',decision(paper()));assert code in (200,204),(code,result)
record('01-stale-review-and-old-client',{'stale':'denied','old_client':'denied','nonchair':'denied','refreshed':'published'})

# Reviewer writes first: chair must wait, see the new review and reject stale input.
s=reopen();review_conn=connection('outsider');chair_conn=connection('chair')
try:
    review_conn.execute("update public.reviews set comments=%s where id=%s",('동시에 먼저 저장된 심사 의견입니다. 이를 확인해야 판정할 수 있습니다.',RID))
    thread,result=worker(chair_conn,lambda c:publish_sql(c,decision(s)))
    wait_for_lock(chair_conn,thread);review_conn.commit();thread.join(9)
    assert not thread.is_alive();assert 'Reviews changed' in result.get('error',''),result
    assert paper()['status']=='under_review'
finally:
    review_conn.close();chair_conn.close()
record('02-review-before-decision',{'waited_for_review':True,'stale_decision':'denied','deadlock':False})

# Chair writes first: review update waits and cannot change a published decision basis.
s=reopen();chair_conn=connection('chair');review_conn=connection('outsider')
try:
    publish_sql(chair_conn,decision(s))
    thread,result=worker(review_conn,lambda c:c.execute('update public.reviews set comments=%s where id=%s',('판정 공개 후 들어온 늦은 심사 수정입니다.',RID)))
    wait_for_lock(review_conn,thread);chair_conn.commit();thread.join(9)
    assert not thread.is_alive()
    assert result.get('error') or result.get('rows')==0,result
    assert next(r for r in paper()['reviews'] if r['id']==RID)['comments']!='판정 공개 후 들어온 늦은 심사 수정입니다.'
finally:
    chair_conn.close();review_conn.close()
record('03-decision-before-review',{'waited_for_decision':True,'late_review':'denied','deadlock':False})

# Browser stale-review recovery, real API (no mocks), narrow mobile layout.
reopen()
with sync_playwright() as p:
    browser=p.chromium.launch(channel='chrome',headless=True)
    chair=m.login(browser,'chair');chair.goto(m.BASE+'/chair.html');expect(chair.locator('#chair-workspace')).to_be_visible()
    chair.locator(f'[data-open="{PID}"]').click();expect(chair.locator('#chair-detail')).to_be_visible()
    chair.set_viewport_size({'width':390,'height':844})
    code,_=call('outsider','PATCH',f'/rest/v1/reviews?id=eq.{RID}',{'comments':'위원장이 최신 심사를 다시 확인해야 하는 브라우저 회귀 검증입니다.'});assert code==200
    chair.locator('#desk-decision').select_option('accepted');chair.locator('#desk-note').fill('심사 변경 감지와 재확인 검증입니다.')
    chair.locator('#chair-decision-form button[type=submit]').click();chair.locator('#chair-publish-confirm').click()
    expect(chair.locator('#chair-message')).to_contain_text('심사 내용이 변경')
    expect(chair.locator('#chair-publish-dialog')).not_to_be_visible()
    assert paper()['status']=='under_review'
    chair.locator('#chair-detail-refresh').click();expect(chair.locator('#chair-reviews')).to_contain_text('최신 심사를 다시 확인')
    expect(chair.locator('#chair-message')).to_contain_text('최신 원고와 심사 의견')
    assert not chair.evaluate('document.documentElement.scrollWidth>innerWidth')
    chair.screenshot(path=str(OUT/'refreshed-mobile.png'),full_page=True)
    # Reject is a real UI decision too; restore accepted afterwards with a fresh snapshot.
    chair.locator('#desk-decision').select_option('rejected');chair.locator('#desk-note').fill('검증을 위한 반려 판정입니다. 신규 원고가 아닙니다.')
    chair.locator('#chair-decision-form button[type=submit]').click();chair.locator('#chair-publish-confirm').click();expect(chair.locator('#chair-message')).to_contain_text('판정을 확정')
    assert paper()['status']=='rejected'
    record('04-mobile-stale-recovery-and-rejection',{'refresh_button':True,'overflow':False,'rejected_in_db':True})
    # Conflict decline remains available when review input is closed, revokes access and is replaceable.
    reopen();code,_=call('chair','PATCH','/rest/v1/conference_settings?edition_year=eq.2026',{'reviews_open':False});assert code==200
    other=m.login(browser,'outsider');m.reload(other,'reviewer');other.locator(f'[data-action=review][data-id="{PID}"]').click()
    other.locator('#review-decline-panel').evaluate('(el)=>el.open=true');other.locator('#review-decline-reason').fill('공동 과제 참여로 이해관계가 있어 심사를 거절합니다.')
    other.once('dialog',lambda dialog:dialog.accept());other.locator('#decline-review').click();expect(other.locator('#message')).to_contain_text('배정을 거절했습니다')
    code,rows=call('outsider','GET',f'/rest/v1/papers?id=eq.{PID}');assert code==200 and rows==[]
    file=fixture['files'][0];code,_=m.request('GET','/storage/v1/object/authenticated/paper-pdfs/'+file['storage_path'],token=TOKENS['outsider']);assert code>=400
    # A declined reviewer no longer fills a slot, even when an exception reason is given.
    missing=decision(paper());missing['p_exception_reason']='이해관계 거절 후에도 인원 부족을 우회할 수 없는지 검증합니다.'
    code,result=call('chair','POST','/rest/v1/rpc/chair_publish_decision',missing)
    assert code>=400 and 'Exactly two active reviewers' in str(result),(code,result)
    chair.locator('#chair-detail-refresh').click()
    expect(chair.locator('#chair-review-progress')).to_contain_text('배정 1/2명')
    expect(chair.locator('#chair-decision-submit')).to_be_disabled()
    code,result=call('chair','POST','/rest/v1/rpc/chair_assign_reviewer',{'p_paper_id':PID,'p_reviewer_id':m.FIXTURES['actors']['chair']['id'],'p_replace_review_id':RID,'p_reason':'이해관계로 배정을 거절한 심사위원을 교체합니다.'});assert code==200,(code,result)
    record('05-closed-review-conflict-decline',{'decline':'saved','paper_and_pdf_access':'revoked','replacement':'saved'})
    assert not m.ERRORS,m.ERRORS
    browser.close()
# Restore test-only operational switches and leave a clear final test state.
code,_=call('chair','PATCH','/rest/v1/conference_settings?edition_year=eq.2026',{'reviews_open':True});assert code==200
payload=decision(paper());payload['p_exception_reason']='격리 로컬 시험 기록 정리를 위한 위원장 판정입니다.'
code,result=call('chair','POST','/rest/v1/rpc/chair_publish_decision',payload);assert code in (200,204),(code,result)
record('06-browser-errors',{'errors':m.ERRORS})
