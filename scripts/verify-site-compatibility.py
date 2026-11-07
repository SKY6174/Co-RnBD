"""Read-only checks of every registered page; never signs in or writes participant data.
uv run --with playwright python scripts/verify-site-compatibility.py \
  --base https://co-rnbd.org --output /tmp/co-rnbd-compatibility
Install browsers once: uv run --with playwright playwright install chromium webkit
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / 'site/lib/pages.ts').read_text().split('export const PAGE_IDS = [', 1)[1].split('] as const', 1)[0]
PAGES = re.findall(r'"([a-z-]+)"', registry)
assert PAGES and len(PAGES) == len(set(PAGES))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base', default='https://co-rnbd.org')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--browsers', nargs='+', choices=['chromium', 'firefox', 'webkit'], default=['chromium', 'webkit'])
args = parser.parse_args()
BASE = args.base.rstrip('/')
assert urlparse(BASE).scheme in ('http', 'https') and urlparse(BASE).netloc
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
RESULT = {'base': BASE, 'pages': PAGES, 'checks': [], 'visits': [], 'errors': [], 'blocked_writes': []}


def save():
    (OUT / 'results.json').write_text(json.dumps(RESULT, ensure_ascii=False, indent=2))


def ready(page, slug):
    if slug == 'program':
        expect(page.locator('#program-message')).to_contain_text('공개')
        expect(page.locator('#program-message')).not_to_have_class(re.compile(r'\berror\b'))
    elif slug == 'archive':
        expect(page.locator('#archive-message')).to_contain_text(re.compile('기록|공개 승인'))
        expect(page.locator('#archive-message')).not_to_have_class(re.compile(r'\berror\b'))
    elif slug == 'edition':
        expect(page.locator('#edition-content')).to_be_visible()
    elif slug == 'submission':
        expect(page.locator('#auth-panel')).to_be_visible()
        expect(page.locator('#workspace')).to_be_hidden()
    elif slug == 'registration':
        expect(page.locator('#registration-login')).to_be_visible()
        expect(page.locator('#registration-form')).to_be_hidden()
    elif slug == 'chair':
        expect(page.locator('#chair-access')).to_be_visible()
        expect(page.locator('#chair-message')).to_contain_text('로그인')
        expect(page.locator('#chair-workspace')).to_be_hidden()
    elif slug == 'mypage':
        expect(page.locator('#member-login')).to_be_visible()
        expect(page.locator('#member-message')).to_contain_text('로그인')
        expect(page.locator('#member-workspace')).to_be_hidden()
    elif slug == 'document-admin':
        expect(page.locator('#documents-message')).to_contain_text('로그인')
        expect(page.locator('#documents-workspace')).to_be_hidden()
    elif slug in ('operations', 'monitor'):
        expect(page.locator(f'#{slug}-message')).to_contain_text('로그인')
        expect(page.locator(f'#{slug}-workspace')).to_be_hidden()
    elif slug == 'session-chair':
        expect(page.locator('#session-chair-message')).to_contain_text('로그인')
        expect(page.locator('#session-chair-list')).to_be_empty()
    elif slug == 'document':
        expect(page.locator('#document-message')).to_contain_text('올바른 문서 주소')
        expect(page.locator('#issued-document')).to_be_hidden()
        expect(page.locator('#document-print')).to_be_disabled()


def interactions(page, slug, width):
    if slug in ('index', 'cfp') and width == 390:
        toggle = page.locator('.menu-toggle')
        toggle.focus()
        page.keyboard.press('Enter')
        expect(toggle).to_have_attribute('aria-expanded', 'true')
        page.keyboard.press('Escape')
        expect(toggle).to_have_attribute('aria-expanded', 'false')
        expect(toggle).to_be_focused()
    if slug == 'index':
        page.locator('#day-one-tab').focus()
        page.keyboard.press('ArrowRight')
        expect(page.locator('#day-two-tab')).to_have_attribute('aria-selected', 'true')
        expect(page.locator('#day-two-panel')).to_be_visible()
        expect(page.locator('#day-one-panel')).to_be_hidden()
        page.keyboard.press('Home')
        expect(page.locator('#day-one-tab')).to_have_attribute('aria-selected', 'true')


def check_http(request):
    response = request.get(BASE + '/api/config')
    assert response.status == 200, ('config', response.status)
    config = response.json()
    assert set(config) == {'url', 'publishableKey', 'naverEnabled'}
    assert isinstance(config['naverEnabled'], bool)
    assert config['publishableKey'] and not config['publishableKey'].startswith('sb_secret_')
    headers = {'apikey': config['publishableKey']}
    api = config['url'].rstrip('/')
    current = request.get(api + '/rest/v1/conference_editions?select=year&status=eq.current', headers=headers)
    assert current.status == 200 and len(current.json()) == 1
    year = current.json()[0]['year']
    for table, query in [
        ('conference_settings', f'select=edition_year&edition_year=eq.{year}'),
        ('program_sessions', f'select=id&is_published=eq.true&edition_year=eq.{year}'),
    ]:
        response = request.get(f'{api}/rest/v1/{table}?{query}', headers=headers)
        assert response.status == 200 and isinstance(response.json(), list), (table, response.status)
    for table in ['papers', 'profiles', 'reviews', 'paper_files', 'paper_events', 'paper_final_checks', 'attendee_registrations']:
        response = request.get(f'{api}/rest/v1/{table}?select=*&limit=1', headers=headers)
        assert response.status in (401, 403) or (response.status == 200 and response.json() == []), (table, response.status)
    RESULT['checks'].append('Client-safe API config, public DB reads, seven private table anonymous denials')
    assert request.get(BASE + '/api/naver-userinfo').status == 401
    for endpoint in ['config', 'naver-userinfo']:
        assert request.post(BASE + '/api/' + endpoint, data={}).status == 405
    assert request.get(BASE + '/compatibility-page-does-not-exist').status == 404
    for slug in PAGES:
        for route in (['/', '/index.html'] if slug == 'index' else [f'/{slug}', f'/{slug}.html']):
            response = request.get(BASE + route)
            assert response.status == 200 and '<main' in response.text(), (route, response.status)
    RESULT['checks'].append('All clean and HTML URLs, API 401/405 and page 404')
    for asset in sorted((ROOT / 'site/public/legacy').glob('*')):
        if asset.is_file():
            response = request.get(BASE + '/legacy/' + asset.name)
            assert response.status == 200, (asset.name, response.status)
            assert hashlib.sha256(response.body()).digest() == hashlib.sha256(asset.read_bytes()).digest(), asset.name
    RESULT['checks'].append('Every deployed legacy asset matches checked-out source')
    return year


def readonly(route):
    if route.request.method not in ('GET', 'HEAD', 'OPTIONS'):
        RESULT['blocked_writes'].append({'method': route.request.method, 'path': urlparse(route.request.url).path})
        route.abort()
    else:
        route.continue_()


try:
    with sync_playwright() as p:
        request = p.request.new_context(timeout=30000)
        year = check_http(request)
        request.dispose()
        save()
        for browser_name in args.browsers:
            browser = getattr(p, browser_name).launch(headless=True)
            for width in [1440, 390]:
                context = browser.new_context(viewport={'width': width, 'height': 1000}, service_workers='block')
                context.route('**/*', readonly)
                for slug in PAGES:
                    page = context.new_page()
                    failures, exceptions = [], []
                    page.on('pageerror', lambda error: exceptions.append(str(error)))
                    page.on('response', lambda response: failures.append({'path': urlparse(response.url).path, 'status': response.status}) if response.status >= 400 else None)
                    route = '/index.html' if slug == 'index' else f'/{slug}.html'
                    if slug == 'edition':
                        route += f'?year={year}'
                    response = page.goto(BASE + route, wait_until='networkidle', timeout=45000)
                    assert response.status == 200, (route, response.status)
                    expect(page.locator('main')).to_be_visible()
                    # A document's heading is rendered only after an authorized
                    # document loads; the no-ID view is intentionally an error state.
                    if slug != 'document':
                        assert page.locator('h1').count() >= 1, route
                    ready(page, slug)
                    interactions(page, slug, width)
                    page.evaluate('document.fonts.ready')
                    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), (route, width, 'horizontal overflow')
                    assert not exceptions, (route, exceptions)
                    assert not failures, (route, failures)
                    assert not RESULT['blocked_writes'], RESULT['blocked_writes']
                    name = f'{browser_name}-{slug}-{width}'
                    page.screenshot(path=str(OUT / (name + '.png')), full_page=True)
                    RESULT['visits'].append({'browser': browser_name, 'page': slug, 'width': width, 'status': 'PASS'})
                    print('PASS: ' + name, flush=True)
                    save()
                    page.close()
                context.close()
            browser.close()
    RESULT['status'] = 'PASS'
except Exception as error:
    RESULT['status'] = 'FAIL'
    RESULT['errors'].append(str(error))
    raise
finally:
    save()
print(f"PASS: {len(PAGES)} pages, {len(RESULT['visits'])} browser/viewport visits; API, DB, routes and assets")
