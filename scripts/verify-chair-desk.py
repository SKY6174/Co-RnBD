"""Chair desk integration checks against isolated local Auth/Postgres/Storage only.
Run after verify-submission-lifecycle.py has created the local fixtures.
uv run --with playwright python scripts/verify-chair-desk.py
"""
import importlib.util
import json
import time
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

spec=importlib.util.spec_from_file_location('lifecycle',Path(__file__).with_name('verify-submission-lifecycle.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
OUT=m.ROOT/'outputs/chair-desk-verification';OUT.mkdir(exist_ok=True,parents=True)
EVIDENCE=[]

def record(name,details):
    EVIDENCE.append({'check':name,'details':details})
    (OUT/'evidence.json').write_text(json.dumps(EVIDENCE,ensure_ascii=False,indent=2))
    print(name+': PASS',flush=True)

def state(pid):
    return json.loads(m.sql(f"""select json_build_object('paper',(select row_to_json(p) from public.papers p where id='{pid}'),
      'reviews',(select json_agg(r) from public.reviews r where paper_id='{pid}'),
      'files',(select json_agg(f order by version) from public.paper_files f where paper_id='{pid}'),
      'events',(select json_agg(e order by created_at) from public.paper_events e where paper_id='{pid}'),
      'final_check',(select row_to_json(c) from public.paper_final_checks c where paper_id='{pid}'));"""))

def fresh_chair(page,pid):
    page.goto(m.BASE+'/chair.html',wait_until='domcontentloaded')
    expect(page.locator('#chair-workspace')).to_be_visible()
    page.locator(f'[data-open="{pid}"]').click()
    expect(page.locator('#chair-detail')).to_be_visible()
    expect(page.locator('#chair-events')).not_to_contain_text('불러오고')

def assign(page,user_id,replace=None):
    page.locator('#chair-reviewer').select_option(user_id)
    if replace:
        page.locator('#chair-replace').select_option(replace)
        page.locator('#chair-replace-reason').fill('로컬 검증을 위한 심사위원 교체')
    with page.expect_response(lambda r: '/rpc/chair_assign_reviewer' in r.url):
        page.locator('#chair-assignment-form button[type=submit]').click()
    expect(page.locator('#chair-assignment-form button[type=submit]')).to_be_enabled()
    expect(page.locator('#chair-message')).to_contain_text('배정과 원고 상태를 저장')

def publish(page,status,note,exception=''):
    page.locator('#desk-decision').select_option(status)
    if status=='accepted':
        page.locator('#desk-session').select_option('oral_1')
    page.locator('#desk-note').fill(note)
    if exception:page.locator('#desk-exception').fill(exception)
    page.locator('#chair-decision-form button[type=submit]').click()
    expect(page.locator('#chair-publish-dialog')).to_be_visible()
    expect(page.locator('#chair-publish-note')).to_have_text(note)
    page.locator('#chair-publish-confirm').click()
    expect(page.locator('#chair-message')).to_contain_text('판정을 확정하고 저자 포털에 공개')

def review(page,pid,recommendation='accept'):
    m.reload(page,'reviewer')
    page.locator(f'[data-action=review][data-id="{pid}"]').click()
    page.locator('#review-comments').fill('현장 적용 결과와 연구 내용을 확인했습니다. 검증용 심사 의견입니다.')
    page.locator('#review-recommendation').select_option(recommendation)
    page.locator('#review-conflict').check()
    page.locator('[data-review-action=submit]').click()
    expect(page.locator('#message')).to_contain_text('심사 의견을 제출했습니다')

with sync_playwright() as p:
    browser=p.chromium.launch(channel='chrome',headless=True)
    pid=None
    try:
        context=browser.new_context(viewport={'width':1440,'height':1000})
        chair=context.new_page();m.PAGES['chair']=chair
        chair.on('pageerror',lambda e:m.ERRORS.append({'role':'chair','error':str(e)}))
        chair.goto(m.BASE+'/chair.html');expect(chair.locator('#chair-access')).to_be_visible()
        chair.locator('#chair-login').click();expect(chair.locator('#auth-panel')).to_be_visible()
        chair.locator('#auth-email').fill(m.FIXTURES['actors']['chair']['email']);chair.locator('#auth-password').fill(m.FIXTURES['password'])
        chair.locator('#email-auth-form button[type=submit]').click()
        expect(chair).to_have_url(m.BASE+'/chair.html');expect(chair.locator('#chair-workspace')).to_be_visible()
        record('01-login-return',{'url':chair.url})
        ops=m.operation_page(chair);m.set_stages(ops,reviews=True,final=True)
        ops.locator('a[href="./chair.html"]').click();expect(ops).to_have_url(m.BASE+'/chair.html')
        expect(ops.locator('h1')).to_have_text('원고 심사 관리')
        author=m.login(browser,'author');reviewer=m.login(browser,'reviewer');other=m.login(browser,'outsider')
        m.profile(other,'outsider');other.locator('[data-tab=profile]').click();other.locator('[name=expertise-track][value=master_eng]').check();other.locator('#profile-form button[type=submit]').click();expect(other.locator('#message')).to_contain_text('내 정보를 저장')
        # Normal author submits an actual PDF through the existing form.
        title='[LOCAL CHAIR] 심사 관리 검증 '+time.strftime('%H%M%S')
        author.locator('#new-paper').click();author.locator('#paper-title').fill(title)
        author.locator('#paper-abstract').fill('위원장 전용 화면에서 배정, 심사, 판정 공개와 최종본 확인을 검증하는 합성 원고입니다.')
        author.locator('[data-author=full_name]').fill('검증 저자');author.locator('[data-author=affiliation]').fill('로컬 검증 기관')
        author.locator('[data-author=email]').fill(m.FIXTURES['actors']['author']['email'])
        author.locator('#paper-file').set_input_files(str(m.OUT/'submission-v1.pdf'))
        author.locator('[data-save=submitted]').click();expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
        pid=m.sql("select id from public.papers where title='"+title+"';")
        fresh_chair(chair,pid);s=state(pid)
        assert {'file_uploaded','paper_submitted'} <= {e['action'] for e in s['events']}
        record('02-submission-audit',{'paper_id':pid,'events':[e['action'] for e in s['events']]})
        # Backend checks cannot be bypassed with a direct API request.
        payload={'p_paper_id':pid,'p_reviewer_id':m.FIXTURES['actors']['reviewer']['id']}
        for role in ('author','reviewer','outsider'):
            code,_=m.call(role,'POST','/rest/v1/rpc/chair_assign_reviewer',payload);assert code>=400,(role,code)
        code,_=m.request('POST','/rest/v1/rpc/chair_assign_reviewer',payload);assert code>=400
        code,_=m.call('chair','POST','/rest/v1/paper_events',{'paper_id':pid,'actor_label':'forged','action':'fake','after_data':{}});assert code>=400
        code,_=m.call('author','GET',f'/rest/v1/paper_events?paper_id=eq.{pid}');assert code==200
        decision={'p_paper_id':pid,'p_status':'accepted','p_note':'검증 판정','p_presentation':'oral','p_session':'oral_1','p_exception_reason':'','p_expected_updated_at':s['paper']['updated_at'],'p_expected_reviews':[]}
        for exception in ('','배정 인원 부족을 우회하려는 검증 사유입니다.'):
            code,result=m.call('chair','POST','/rest/v1/rpc/chair_publish_decision',{**decision,'p_exception_reason':exception})
            assert code>=400 and 'Exactly two active reviewers' in str(result),(code,result)
        expect(chair.locator('#chair-decision-submit')).to_be_disabled()
        expect(chair.locator('#chair-review-progress')).to_contain_text('배정 0/2명')
        assert state(pid)['paper']['status']=='submitted'
        record('03-authorization-and-incomplete-review',{'forged_event':'denied','nonchair_rpc':'denied','incomplete_decision':'denied'})
        assign(chair,m.FIXTURES['actors']['reviewer']['id']);s=state(pid);rid=s['reviews'][0]['id']
        review(reviewer,pid)
        fresh_chair(chair,pid);expect(chair.locator('#chair-review-progress')).to_contain_text('심사 제출 1/2명')
        expect(chair.locator('#chair-decision-submit')).to_be_disabled()
        expect(chair.locator('#chair-decision-requirement')).to_contain_text('2명을 먼저 구성')
        s=state(pid)
        one_review={**decision,'p_expected_updated_at':s['paper']['updated_at'],'p_expected_reviews':sorted(s['reviews'],key=lambda r:r['id']),'p_exception_reason':'한 명의 심사로 판정하려는 검증 사유입니다.'}
        for outcome in ('accepted','revision','rejected'):
            code,result=m.call('chair','POST','/rest/v1/rpc/chair_publish_decision',{**one_review,'p_status':outcome})
            assert code>=400 and 'Exactly two active reviewers' in str(result),(code,result)
        code,result=m.call('chair','PATCH',f'/rest/v1/papers?id=eq.{pid}',{'status':'accepted','decision_note':'직접 업데이트 우회 검증','decision_exception_reason':'직접 요청으로 2명 조건을 우회하는지 확인합니다.'})
        assert code>=400 and 'Exactly two active reviewers' in str(result),(code,result)
        chair.locator('#chair-back').click();chair.locator('#chair-search').fill(title)
        chair.locator('#chair-status-filter').select_option('ready');expect(chair.locator('#chair-empty')).to_be_visible()
        chair.locator('#chair-status-filter').select_option('unassigned');expect(chair.locator('#chair-rows tr')).to_have_count(1)
        chair.set_viewport_size({'width':390,'height':844});assert not chair.evaluate('document.documentElement.scrollWidth>innerWidth')
        chair.screenshot(path=str(OUT/'two-reviewers-needed-mobile.png'),full_page=True)
        chair.set_viewport_size({'width':1440,'height':1000});fresh_chair(chair,pid)
        record('03b-two-reviewer-minimum',{'zero_and_one_reviewer_decisions':'denied even with exception','direct_update':'denied','one_complete_review':'assignment needed','mobile_overflow':False})
        code,_=m.call('chair','POST','/rest/v1/rpc/chair_assign_reviewer',payload);assert code>=400
        code,_=m.call('chair','POST','/rest/v1/rpc/chair_assign_reviewer',{'p_paper_id':pid,'p_reviewer_id':m.FIXTURES['actors']['author']['id']});assert code>=400
        # Failed replacement must preserve the original assignment and access.
        code,_=m.call('chair','POST','/rest/v1/rpc/chair_assign_reviewer',{'p_paper_id':pid,'p_reviewer_id':m.FIXTURES['actors']['author']['id'],'p_replace_review_id':rid,'p_reason':'실패하는 교체 원자성 검증'});assert code>=400
        assert state(pid)['reviews'][0]['revoked_at'] is None
        assign(chair,m.FIXTURES['actors']['outsider']['id'],rid)
        s=state(pid);assert next(r for r in s['reviews'] if r['id']==rid)['revoked_at']
        code,rows=m.call('reviewer','GET',f'/rest/v1/papers?id=eq.{pid}');assert code==200 and rows==[]
        code,_=m.call('reviewer','GET','/storage/v1/object/authenticated/paper-pdfs/'+s['files'][0]['storage_path']);assert code>=400
        record('04-assignment-replacement',{'old_assignment_preserved':True,'old_access_revoked':True,'failed_replacement_rolled_back':True})
        # A second reviewer is allowed; a third is rejected. One pending review requires an explicit exception.
        assign(chair,m.FIXTURES['actors']['chair']['id'])
        assert chair.locator('#chair-replace').evaluate('(el)=>el.options[0].disabled && el.required && !el.checkValidity()')
        code,result=m.call('chair','POST','/rest/v1/rpc/chair_assign_reviewer',payload);assert code>=400 and 'At most two' in str(result)
        review(other,pid,'revise')
        fresh_chair(chair,pid)
        s=state(pid)
        incomplete={**decision,'p_expected_updated_at':s['paper']['updated_at'],'p_expected_reviews':sorted(s['reviews'],key=lambda r:r['id'])}
        code,result=m.call('chair','POST','/rest/v1/rpc/chair_publish_decision',incomplete)
        assert code>=400 and 'Incomplete reviews' in str(result),(code,result)
        publish(chair,'revision','검증 방법을 보완하여 수정본을 제출해 주세요.','시범 운영 검증을 위해 제출된 한 명의 의견으로 수정 요청합니다.')
        s=state(pid);assert s['paper']['decided_by']==m.FIXTURES['actors']['chair']['id'];assert s['paper']['decision_published_at']
        m.reload(author);author.locator(f'[data-action=author][data-id="{pid}"]').click();expect(author.locator('#message')).to_contain_text('수정본을 제출')
        expect(author.locator('#message')).to_contain_text('예외 사유')
        record('05-public-decision',{'status':s['paper']['status'],'published_at':s['paper']['decision_published_at'],'actor_recorded':True})
        old_basis=s['paper']['submitted_at'];author.locator('#paper-file').set_input_files(str(m.OUT/'submission-v2.pdf'));author.locator('[data-save=submitted]').click();expect(author.locator('#message')).to_contain_text('원고가 제출되었습니다')
        assert state(pid)['paper']['submitted_at']!=old_basis
        fresh_chair(chair,pid);assign(chair,m.FIXTURES['actors']['outsider']['id']);review(other,pid)
        fresh_chair(chair,pid);expect(chair.locator('#chair-decision-submit')).to_be_disabled()
        expect(chair.locator('#chair-review-progress')).to_contain_text('배정 1/2명')
        assign(chair,m.FIXTURES['actors']['reviewer']['id']);review(reviewer,pid)
        s=state(pid);assert len([r for r in s['reviews'] if r['reviewer_id']==m.FIXTURES['actors']['outsider']['id']])==2
        old=next(r for r in s['reviews'] if r['reviewer_id']==m.FIXTURES['actors']['outsider']['id'] and r['manuscript_submitted_at']==old_basis)
        code,result=m.call('outsider','PATCH',f'/rest/v1/reviews?id=eq.{old["id"]}',{'comments':'지난 제출본을 임의 수정합니다.'});assert code>=400
        code,_=m.call('chair','POST','/rest/v1/rpc/chair_publish_decision',decision);assert code>=400
        fresh_chair(chair,pid);assert chair.locator('#chair-exception-panel').is_hidden()
        expect(chair.locator('#chair-review-progress')).to_contain_text('심사 제출 2/2명')
        expect(chair.locator('#chair-decision-submit')).to_be_enabled()
        chair.locator('#chair-back').click();chair.locator('#chair-search').fill(title)
        chair.locator('#chair-status-filter').select_option('ready');expect(chair.locator('#chair-rows tr')).to_have_count(1)
        chair.locator(f'[data-open="{pid}"]').click();expect(chair.locator('#chair-detail')).to_be_visible()
        publish(chair,'accepted','수정 사항을 확인하여 구두 발표로 채택합니다.')
        record('06-revision-review-and-acceptance',{'review_rows_preserved':len(s['reviews']),'stale_decision':'denied','old_review_edit':'denied'})
        m.reload(author);author.locator(f'[data-action=author][data-id="{pid}"]').click();author.locator('#final-file').set_input_files(str(m.OUT/'final-v3.pdf'));author.locator('#final-form button[type=submit]').click();expect(author.locator('#message')).to_contain_text('최종 PDF를 업로드')
        fresh_chair(chair,pid);expect(chair.locator('#chair-final-status')).to_contain_text('v3 확인 대기')
        with chair.expect_popup() as pop:
            chair.locator('#chair-files [data-file]').first.click()
        pop.value.wait_for_load_state('domcontentloaded');assert '/storage/v1/object/sign/' in pop.value.url;pop.value.close()
        chair.locator('#chair-final-confirm').check();chair.locator('#chair-final-form button').click();expect(chair.locator('#chair-message')).to_contain_text('v3 확인 완료')
        s=state(pid);old_final=s['final_check']['file_id'];assert s['final_check']['checked_by']==m.FIXTURES['actors']['chair']['id']
        author.locator('#final-file').set_input_files(str(m.OUT/'final-v3.pdf'));author.locator('#final-form button[type=submit]').click();expect(author.locator('#message')).to_contain_text('최종 PDF를 업로드')
        fresh_chair(chair,pid);expect(chair.locator('#chair-final-status')).to_contain_text('v4 확인 대기')
        code,_=m.call('chair','PATCH',f'/rest/v1/paper_final_checks?paper_id=eq.{pid}',{'file_id':old_final});assert code>=400
        chair.locator('#chair-final-confirm').check();chair.locator('#chair-final-form button').click();expect(chair.locator('#chair-message')).to_contain_text('v4 확인 완료')
        m.reload(author);author.locator(f'[data-action=author][data-id="{pid}"]').click();expect(author.locator('#final-status')).to_contain_text('v4 위원장 확인 완료')
        record('07-final-file-version-check',{'confirmed_version':4,'old_confirmation_retained_in_events':True,'stale_file_check':'denied'})
        s=state(pid)
        code,_=m.call('chair','PATCH',f'/rest/v1/paper_events?paper_id=eq.{pid}',{'action':'changed'});assert code>=400
        code,rows=m.call('author','GET',f'/rest/v1/paper_events?paper_id=eq.{pid}');assert code==200 and rows==[]
        code,_=m.call('author','PATCH',f'/rest/v1/paper_final_checks?paper_id=eq.{pid}',{'checked_at':'2020-01-01T00:00:00Z'});assert code>=400 or state(pid)['final_check']['checked_at']==s['final_check']['checked_at']
        record('08-private-immutable-audit',{'events':len(s['events']),'actions':sorted(set(e['action'] for e in s['events']))})
        # Search and mobile presentation use the actual returned data.
        chair.screenshot(path=str(OUT/'chair-detail-desktop.png'),full_page=True)
        chair.locator('#chair-back').click();chair.locator('#chair-search').fill(title);expect(chair.locator('#chair-rows tr')).to_have_count(1)
        chair.locator('#chair-track-filter').select_option('master_sci');expect(chair.locator('#chair-empty')).to_be_visible();chair.locator('#chair-track-filter').select_option('all')
        chair.screenshot(path=str(OUT/'chair-list-desktop.png'),full_page=True)
        chair.set_viewport_size({'width':390,'height':844});assert not chair.evaluate('document.documentElement.scrollWidth>innerWidth')
        chair.screenshot(path=str(OUT/'chair-list-mobile.png'),full_page=True)
        chair.locator(f'[data-open="{pid}"]').click();expect(chair.locator('#chair-detail')).to_be_visible();assert not chair.evaluate('document.documentElement.scrollWidth>innerWidth')
        chair.screenshot(path=str(OUT/'chair-detail-mobile.png'),full_page=True)
        author.goto(m.BASE+'/chair.html');expect(author.locator('#chair-access-text')).to_contain_text('위원장 권한이 없습니다');expect(author.locator('#chair-workspace')).to_be_hidden()
        chair.goto(m.BASE+'/submission.html#chair');expect(chair).to_have_url(m.BASE+'/chair.html');expect(chair.locator('#chair-workspace')).to_be_visible()
        assert not m.ERRORS,m.ERRORS
        record('09-navigation-mobile-and-no-errors',{'old_link_redirect':True,'mobile_overflow':False,'nonchair_access':'denied','browser_errors':m.ERRORS})
        (OUT/'final-state.json').write_text(json.dumps(s,ensure_ascii=False,indent=2))
    except Exception:
        for role,page in m.PAGES.items():
            page.screenshot(path=str(OUT/f'failure-{role}.png'),full_page=True)
        if pid:(OUT/'failure-state.json').write_text(json.dumps(state(pid),ensure_ascii=False,indent=2))
        raise
    finally:
        (OUT/'network.json').write_text(json.dumps(m.NETWORK,ensure_ascii=False,indent=2))
        (OUT/'browser-errors.json').write_text(json.dumps(m.ERRORS,ensure_ascii=False,indent=2))
        browser.close()
