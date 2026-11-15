"""Read-only production checks. No sign-in, document issuance, payment or email."""
import hashlib
import json
from pathlib import Path
from playwright.sync_api import sync_playwright,expect
ROOT=Path(__file__).resolve().parents[1]
BASE='https://co-rnbd.org'
OUT=ROOT/'outputs/member-documents';OUT.mkdir(parents=True,exist_ok=True)
checks=[]
with sync_playwright() as p:
    browser=p.chromium.launch(channel='chrome',headless=True)
    context=browser.new_context();page=context.new_page();errors=[]
    page.on('pageerror',lambda error:errors.append(str(error)))
    config=context.request.get(BASE+'/api/config').json()
    assert 'lvtdnrmwunahgwutafhv' in config['url']
    for name in ['member-documents','mypage','document-admin','document','submission']:
        response=context.request.get(BASE+'/legacy/'+name+'.js')
        assert response.status==200
        assert hashlib.sha256(response.body()).digest()==hashlib.sha256((ROOT/'site/public/legacy'/f'{name}.js').read_bytes()).digest(),name
    checks.append('Five deployed scripts match source')
    headers={'apikey':config['publishableKey'],'Content-Type':'application/json'}
    for table in ['document_issuers','registration_billing','registration_documents']:
        response=context.request.get(config['url']+'/rest/v1/'+table+'?select=*&limit=1',headers=headers)
        assert response.status in [401,403],(table,response.status)
    for name,data in [('issue_registration_document',{'p_registration_id':None,'p_kind':'receipt'}),('revoke_registration_document',{'p_id':None,'p_reason':'anonymous-denial-check'})]:
        response=context.request.post(config['url']+'/rest/v1/rpc/'+name,headers=headers,data=json.dumps(data))
        assert response.status in [401,403],(name,response.status)
    checks.append('Anonymous reads and issuance/revocation RPCs denied')
    for width in [390,1440]:
        page.set_viewport_size({'width':width,'height':900})
        for route,ready,hidden in [('mypage','#member-login','#member-workspace'),('document-admin','#documents-access','#documents-workspace'),('document','#document-message','#issued-document')]:
            response=page.goto(BASE+'/'+route+'.html',wait_until='networkidle');assert response.status==200
            expect(page.locator(ready)).to_be_visible();expect(page.locator(hidden)).to_be_hidden()
            assert not page.evaluate('document.documentElement.scrollWidth>innerWidth')
        page.goto(BASE+'/',wait_until='networkidle')
        assert page.locator('#primary-nav a[href="./mypage.html"]').count()==1
    assert errors==[],errors
    checks.append('Desktop/mobile login guards, My Page navigation, no overflow or browser exceptions')
    browser.close()
(OUT/'production-results.json').write_text(json.dumps({'checks':checks},ensure_ascii=False,indent=2))
print(json.dumps(checks,ensure_ascii=False,indent=2))
