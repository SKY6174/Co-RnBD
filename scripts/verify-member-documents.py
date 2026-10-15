"""Actual local Auth/Postgres/browser verification; never writes to production.
uv run --with playwright --with pypdf python scripts/verify-member-documents.py
"""
import concurrent.futures
import importlib.util
import json
import uuid
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
from pypdf import PdfReader

spec=importlib.util.spec_from_file_location('lifecycle',Path(__file__).with_name('verify-submission-lifecycle.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
OUT=m.ROOT/'outputs/member-documents';OUT.mkdir(parents=True,exist_ok=True)
checks=[]
def record(name):
    checks.append(name);print(name+': PASS',flush=True)
def ok(role,method,path,payload=None):
    code,result=m.call(role,method,path,payload);assert 200<=code<300,(path,code,result);return result
def denied(role,method,path,payload=None,contains=None):
    code,result=m.call(role,method,path,payload);assert code>=400,(path,code,result)
    if contains:assert contains in str(result),(contains,result)
def issue(role,rid,kind):
    return ok(role,'POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':kind})

def submit(page,selector,table):
    with page.expect_response(lambda r: '/rest/v1/'+table in r.url and r.request.method=='POST'):
        page.locator(selector).click()
    expect(page.locator(selector)).to_be_enabled()

def fresh(page,path):
    page.goto(m.BASE+path,wait_until='networkidle')

with sync_playwright() as p:
    browser=p.chromium.launch(channel='chrome',headless=True)
    author=m.login(browser,'author');chair=m.login(browser,'chair');outsider=m.login(browser,'outsider')
    actors=m.FIXTURES['actors'];tokens={r:m.token(r) for r in ['author','chair','outsider']}
    # Reset only isolated fixtures, using real authenticated endpoints for business writes.
    ok('chair','PATCH','/rest/v1/conference_settings?edition_year=eq.2026',{'registration_open':True,'registration_deadline':'2027-01-05T09:00:00Z'})
    regs=ok('author','GET','/rest/v1/attendee_registrations?select=id,status')
    if regs:
        rid=regs[0]['id']
        ok('chair','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'status':'applied','checked_in_at':None})
    else:
        rid=ok('author','POST','/rest/v1/attendee_registrations',{'user_id':actors['author']['id'],'edition_year':2026,'category':'faculty','attendance_days':['2027-01-21','2027-01-22']})[0]['id']
    for kind in ['attendance','receipt','statement']:
        denied('author','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':kind},'Confirmed registration')
    ok('chair','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'status':'confirmed'})
    # UI setup; no issuer details are invented in the production migration.
    fresh(chair,'/document-admin.html');expect(chair.locator('#documents-workspace')).to_be_visible()
    chair.locator('.document-settings summary').click()
    for field,value in {'organization':'검증 학회 (로컬 전용)','representative':'검증 대표','address':'로컬 검증 주소','contact_email':'local@example.test','organization_number':'TEST-LOCAL'}.items():chair.locator('#issuer-'+field).fill(value)
    chair.locator('#issuer-enabled').uncheck();chair.locator('#issuer-verified').check();submit(chair,'#issuer-form button','document_issuers')
    expect(chair.locator('#documents-message')).to_contain_text('발급기관 설정을 저장')
    denied('author','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'attendance'},'Issuer configuration')
    chair.locator('#issuer-enabled').check();chair.locator('#issuer-verified').check();submit(chair,'#issuer-form button','document_issuers')
    expect(chair.locator('#documents-message')).to_contain_text('발급기관 설정을 저장')
    denied('author','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'attendance'},'Attendance check-in')
    # Member cannot assign an issuer or payment state (empty UPDATE is also a denied change).
    original=ok('author','GET','/rest/v1/document_issuers?edition_year=eq.2026')[0]
    altered=ok('author','PATCH','/rest/v1/document_issuers?edition_year=eq.2026',{'organization':'forged'})
    assert altered==[] and ok('chair','GET','/rest/v1/document_issuers?edition_year=eq.2026')[0]['organization']==original['organization']
    denied('author','POST','/rest/v1/registration_billing',{'registration_id':rid,'amount':1,'status':'paid','payment_method':'cash','paid_at':'2026-10-14T00:00:00Z','verified':True,'updated_by':actors['author']['id']})
    record('01-issuer-checkin-and-billing-authority')
    ok('chair','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'checked_in_at':'2026-10-14T00:00:00Z'})
    chair.locator(f'[data-person="{rid}"]').click();chair.locator('#billing-amount').fill('120000');chair.locator('#billing-status').select_option('unpaid');chair.locator('#billing-verified').check();submit(chair,'#billing-form button','registration_billing')
    expect(chair.locator('#documents-message')).to_contain_text('수동 확인 내역을 저장')
    statement=issue('author',rid,'statement')
    denied('author','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'receipt'},'Verified payment')
    # Actual My Page and attendance issue.
    fresh(author,'/mypage.html');expect(author.locator('#member-history')).to_contain_text('참가 확정')
    author.locator('[data-kind=attendance]').click();author.wait_for_url('**/document.html?id=*')
    expect(author.locator('#issued-document')).to_contain_text('참가확인증')
    assert not author.evaluate('document.documentElement.scrollWidth>innerWidth')
    author.screenshot(path=str(OUT/'certificate-desktop.png'),full_page=True)
    certificate=author.url.split('id=')[1]
    fresh(chair,'/document-admin.html');chair.locator(f'[data-person="{rid}"]').click()
    chair.locator('#billing-status').select_option('paid');chair.locator('#billing-method').select_option('transfer');chair.locator('#billing-paid-at').fill('2026-10-14T12:00');chair.locator('#billing-verified').check();submit(chair,'#billing-form button','registration_billing')
    expect(chair.locator('#documents-message')).to_contain_text('수동 확인 내역을 저장')
    assert ok('author','GET',f'/rest/v1/registration_documents?id=eq.{statement}')[0]['state']=='revoked'
    receipt=issue('author',rid,'receipt');statement2=issue('author',rid,'statement')
    assert statement2!=statement
    # Server-generated immutable snapshots, not editable HTML input as a source of truth.
    receipt_row=ok('author','GET',f'/rest/v1/registration_documents?id=eq.{receipt}')[0]
    assert receipt_row['snapshot']['billing']['amount']==120000
    assert receipt_row['snapshot']['recipient']['name']!='forged'
    assert ok('author','PATCH',f'/rest/v1/registration_documents?id=eq.{receipt}',{'snapshot':{'forged':True}})==[]
    denied('chair','PATCH',f'/rest/v1/registration_documents?id=eq.{receipt}',{'snapshot':{'forged':True}},'immutable')
    ok('chair','POST','/rest/v1/rpc/revoke_registration_document',{'p_id':certificate,'p_reason':'자동 생성 무결성 재검증'})
    forged=ok('author','POST','/rest/v1/registration_documents',{'registration_id':rid,'kind':'attendance','document_no':'forged','snapshot':{'recipient':{'name':'forged'}},'issued_by':actors['outsider']['id']})[0]
    assert forged['document_no']!='forged' and forged['snapshot']['recipient']['name']!='forged' and forged['issued_by']==actors['author']['id']
    record('02-auto-issuance-and-snapshot-integrity')
    # Anonymous/another member never sees private rows or generates documents for this registration.
    for table in ['registration_documents','registration_billing']:
        assert ok('outsider','GET',f'/rest/v1/{table}?registration_id=eq.{rid}')==[]
        code,_=m.request('GET',f'/rest/v1/{table}?select=*&limit=1');assert code in [401,403]
    denied('outsider','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'receipt'})
    denied('outsider','POST','/rest/v1/rpc/revoke_registration_document',{'p_id':receipt,'p_reason':'불법 발급 취소 검증'})
    fresh(outsider,'/document.html?id='+receipt);expect(outsider.locator('#document-message')).to_contain_text('문서를 볼 수 없습니다');expect(outsider.locator('#issued-document')).to_be_hidden()
    code,_=m.request('POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'receipt'});assert code in [401,403]
    record('03-owner-isolation-and-anonymous-denial')
    # Actual print rendering: A4, one page, fonts loaded.
    for kind,did in [('attendance',forged['id']),('receipt',receipt),('statement',statement2)]:
        fresh(author,'/document.html?id='+did);expect(author.locator('#issued-document')).to_be_visible();author.evaluate('document.fonts.ready')
        author.emulate_media(media='print');pdf=OUT/(kind+'.pdf');author.pdf(path=str(pdf),prefer_css_page_size=True,print_background=True)
        reader=PdfReader(str(pdf));assert len(reader.pages)==1,(kind,len(reader.pages))
        assert abs(float(reader.pages[0].mediabox.width)-595.28)<2
        author.emulate_media(media='screen');author.set_viewport_size({'width':390,'height':844});assert not author.evaluate('document.documentElement.scrollWidth>innerWidth');author.screenshot(path=str(OUT/(kind+'-mobile.png')),full_page=True)
    fresh(author,'/mypage.html');expect(author.locator('#member-history')).to_contain_text('120,000원');assert not author.evaluate('document.documentElement.scrollWidth>innerWidth');author.screenshot(path=str(OUT/'mypage-mobile.png'),full_page=True)
    chair.set_viewport_size({'width':390,'height':844});assert not chair.evaluate('document.documentElement.scrollWidth>innerWidth');chair.screenshot(path=str(OUT/'admin-mobile.png'),full_page=True)
    record('04-three-printable-A4-documents-and-mobile')
    # Repeated/concurrent issuance is idempotent; revoked receipts cannot be printed afresh.
    def concurrent_issue(_):
        return m.request('POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'receipt'},token=tokens['author'])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: results=list(pool.map(concurrent_issue,range(4)))
    assert all(code==200 and did==receipt for code,did in results),results
    ok('chair','PATCH',f'/rest/v1/registration_billing?registration_id=eq.{rid}',{'status':'refunded'})
    fresh(author,'/document.html?id='+receipt);expect(author.locator('#document-message')).to_contain_text('발급 취소');expect(author.locator('#document-print')).to_be_disabled()
    denied('author','POST','/rest/v1/rpc/issue_registration_document',{'p_registration_id':rid,'p_kind':'receipt'},'Verified payment')
    # Transaction rolls back invalid billing and leaves original data intact.
    denied('chair','PATCH',f'/rest/v1/registration_billing?registration_id=eq.{rid}',{'amount':-1})
    assert ok('chair','GET',f'/rest/v1/registration_billing?registration_id=eq.{rid}')[0]['amount']==120000
    record('05-concurrency-refund-revocation-and-invalid-input')
    # Archived, non-public edition remains in the member's private registration history.
    m.sql("update public.conference_editions set status='archived',archive_published=false where year=2026;")
    try:
        fresh(author,'/mypage.html');expect(author.locator('#member-history')).to_contain_text('2026')
        assert author.locator('[data-registration-id]').count()==1
        fresh(author,'/document.html?id='+forged['id']);expect(author.locator('#issued-document')).to_be_visible()
    finally:
        # Archiving is deliberately irreversible in production. Restore only the isolated
        # fixture under its business-data immutability trigger; never disable RLS/Auth.
        m.sql("begin; alter table public.conference_editions disable trigger check_edition_edit; update public.conference_editions set status='current' where year=2026; alter table public.conference_editions enable trigger check_edition_edit; commit;")
        assert m.sql("select tgenabled from pg_trigger where tgrelid='public.conference_editions'::regclass and tgname='check_edition_edit';")=='O'
    record('06-private-history-after-archiving')
    # Owner cancellation automatically revokes remaining certificate, cannot bypass immutable record guards.
    denied('author','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'status':'cancelled'})
    ok('chair','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'checked_in_at':None})
    assert ok('author','GET',f'/rest/v1/registration_documents?id=eq.{forged["id"]}')[0]['state']=='revoked'
    issue('author',rid,'statement')
    ok('author','PATCH',f'/rest/v1/attendee_registrations?id=eq.{rid}',{'status':'cancelled'})
    assert not ok('author','GET',f'/rest/v1/registration_documents?registration_id=eq.{rid}&state=eq.issued')
    fresh(author,'/mypage.html');expect(author.locator('#member-history')).to_contain_text('참가 취소');author.locator('#member-signout').click();expect(author.locator('#member-workspace')).to_be_hidden();assert author.locator('#member-history').inner_text()==''
    author.locator('#member-login a').click();author.locator('#auth-email').fill(actors['author']['email']);author.locator('#auth-password').fill(m.FIXTURES['password']);author.locator('#email-auth-form button[type=submit]').click();author.wait_for_url('**/mypage.html');expect(author.locator('#member-workspace')).to_be_visible()
    record('07-cancellation-signout-and-login-return')
    for width in [390,1024,1440]:
        author.set_viewport_size({'width':width,'height':900});fresh(author,'/')
        assert not author.evaluate('document.documentElement.scrollWidth>innerWidth'),width
    record('08-home-navigation-widths')
    assert not m.ERRORS,m.ERRORS
    browser.close()
(OUT/'results.json').write_text(json.dumps({'checks':checks,'browser_errors':m.ERRORS},ensure_ascii=False,indent=2))
