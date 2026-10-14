"""Regression checks for lazy details and auth refresh using real isolated local fixtures.
uv run --with playwright python scripts/verify-portal-performance.py
"""
import importlib.util
import json
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect

spec = importlib.util.spec_from_file_location('lifecycle', Path(__file__).with_name('verify-submission-lifecycle.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
out = m.ROOT / 'outputs/db-response-optimization'; out.mkdir(parents=True, exist_ok=True)
checks = []

with sync_playwright() as p:
    browser = p.chromium.launch(channel='chrome', headless=True)
    page = m.login(browser, 'chair')
    with page.expect_response(lambda r: '/rest/v1/papers?' in r.url) as overview:
        page.goto(m.BASE + '/chair.html')
    expect(page.locator('#chair-workspace')).to_be_visible()
    rows = overview.value.json()
    assert rows and all('abstract' not in r and 'contact_email' not in r for r in rows)
    assert all('comments' not in review for r in rows for review in r['reviews'])
    assert all('storage_path' not in file for r in rows for file in r['paper_files'])
    paper_id = rows[0]['id']
    checks.append('Overview excludes manuscript/review bodies and private file paths')
    def fail_detail(route):
        if 'id' in parse_qs(urlparse(route.request.url).query):
            route.fulfill(status=503, content_type='application/json', body=json.dumps({'message': '검증용 상세 조회 실패'}))
        else:
            route.continue_()
    page.route('**/rest/v1/papers?*', fail_detail)
    page.locator(f'[data-open="{paper_id}"]').click()
    expect(page.locator('#chair-message')).to_contain_text('검증용 상세 조회 실패')
    expect(page.locator('#chair-overview')).to_be_visible()
    expect(page.locator('#chair-detail')).to_be_hidden()
    page.unroute('**/rest/v1/papers?*', fail_detail)
    with page.expect_response(lambda r: '/rest/v1/papers?' in r.url and 'id' in parse_qs(urlparse(r.url).query)) as detail:
        page.locator(f'[data-open="{paper_id}"]').click()
    expect(page.locator('#chair-detail')).to_be_visible()
    full = detail.value.json()
    assert full['id'] == paper_id and 'abstract' in full
    assert all('comments' in review for review in full['reviews'])
    expect(page.locator('#chair-paper-abstract')).to_have_text(full['abstract'])
    checks.append('Failed detail restores overview; retry fetches full current snapshot')
    for width in [1440, 390]:
        page.set_viewport_size({'width': width, 'height': 1000})
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        page.screenshot(path=str(out / f'chair-detail-{width}.png'), full_page=True)
    for route, ready, field, value in [
        ('registration', '#registration-account', '#registration-category', 'industry'),
        ('submission', '#account-email', '#profile-name', '저장하지 않은 입력'),
    ]:
        page.goto(m.BASE + '/' + route + '.html')
        expect(page.locator(ready)).to_contain_text(m.FIXTURES['actors']['chair']['email'])
        if route == 'registration': page.locator(field).select_option(value)
        else:
            page.locator('[data-tab="profile"]').click()
            page.locator(field).fill(value)
        page.wait_for_timeout(200)
        requests = []
        def capture(request):
            if '/rest/v1/' in request.url: requests.append(urlparse(request.url).path)
        page.on('request', capture)
        result = page.evaluate("""async () => {
            const {conferenceClient} = await import('/legacy/conference-client.js');
            const client = await conferenceClient();
            const result = await client.auth.refreshSession();
            return { error: result.error?.message || null };
        }""")
        assert not result['error'], result
        page.wait_for_timeout(300)
        page.remove_listener('request', capture)
        assert requests == [], requests
        expect(page.locator(field)).to_have_value(value)
        checks.append(route + ': token refresh preserves unsaved fields and sends no DB reads')
    page.locator('#sign-out').click()
    expect(page.locator('#auth-panel')).to_be_visible()
    expect(page.locator('#workspace')).to_be_hidden()
    page.goto(m.BASE + '/registration.html')
    expect(page.locator('#registration-login')).to_be_visible()
    expect(page.locator('#registration-form')).to_be_hidden()
    assert not m.ERRORS, m.ERRORS
    checks.append('Logout hides private workspaces; no browser exceptions; desktop/mobile fit')
    browser.close()
(out / 'regressions.json').write_text(json.dumps(checks, ensure_ascii=False, indent=2))
print(json.dumps(checks, ensure_ascii=False, indent=2))
