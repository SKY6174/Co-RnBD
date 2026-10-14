"""Read-only production smoke checks after deploying the local source revision.
uv run --with playwright python scripts/verify-portal-production.py
Never signs in, submits a paper, or sends email.
"""
import hashlib
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://co-rnbd.org'
OUT = ROOT / 'outputs/db-response-optimization'
OUT.mkdir(parents=True, exist_ok=True)
checks, errors, config_requests = [], [], []
with sync_playwright() as p:
    browser = p.chromium.launch(channel='chrome', headless=True)
    context = browser.new_context(viewport={'width': 1440, 'height': 1000})
    response = context.request.get(BASE + '/api/config')
    assert response.status == 200
    # Vercel consumes/strips s-maxage; the browser receives its separate max-age.
    # https://vercel.com/docs/caching/cache-control-headers
    assert 'public' in response.headers['cache-control'] and 'max-age=60' in response.headers['cache-control']
    config = response.json()
    assert 'lvtdnrmwunahgwutafhv' in config['url']
    assert set(config) == {'url', 'publishableKey', 'naverEnabled'}
    headers = {'apikey': config['publishableKey'], 'Content-Type': 'application/json'}
    for name in ['chair', 'conference-client', 'registration', 'submission']:
        deployed = context.request.get(BASE + '/legacy/' + name + '.js')
        assert deployed.status == 200
        assert hashlib.sha256(deployed.body()).digest() == hashlib.sha256((ROOT / 'site/public/legacy' / (name + '.js')).read_bytes()).digest(), name
    checks.append('All four deployed scripts match verified source')
    for table, query in [('conference_editions', 'select=year,status&status=eq.current'),
                         ('conference_settings', 'select=edition_year,submissions_open,registration_open&edition_year=eq.2026')]:
        result = context.request.get(config['url'] + '/rest/v1/' + table + '?' + query, headers=headers)
        assert result.status == 200 and len(result.json()) == 1
    checks.append('Production client-safe configuration and public database reads succeed')
    for table in ['papers', 'profiles', 'reviews', 'paper_files', 'paper_events', 'paper_final_checks', 'attendee_registrations']:
        denied = context.request.get(config['url'] + '/rest/v1/' + table + '?select=*&limit=1', headers=headers)
        assert denied.status in [401, 403], (table, denied.status)
    for rpc, payload in [('chair_assign_reviewer', {'p_paper_id': None, 'p_reviewer_id': None}),
                         ('chair_publish_decision', {'p_paper_id': None, 'p_status': 'accepted', 'p_note': '', 'p_presentation': None, 'p_session': None, 'p_exception_reason': '', 'p_expected_updated_at': None, 'p_expected_reviews': []})]:
        denied = context.request.post(config['url'] + '/rest/v1/rpc/' + rpc, headers=headers, data=json.dumps(payload))
        assert denied.status in [401, 403], (rpc, denied.status)
    checks.append('Anonymous access to seven private tables and both chair RPCs denied')
    page = context.new_page()
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.on('request', lambda request: config_requests.append(request.url) if request.url.endswith('/api/config') else None)
    for width in [1440, 390]:
        page.set_viewport_size({'width': width, 'height': 1000})
        for route, ready, private in [('chair', '#chair-access', '#chair-workspace'),
                                     ('registration', '#registration-login', '#registration-form'),
                                     ('submission', '#auth-panel', '#workspace')]:
            response = page.goto(BASE + '/' + route + '.html', wait_until='networkidle')
            assert response.status == 200
            expect(page.locator(ready)).to_be_visible()
            expect(page.locator(private)).to_be_hidden()
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), (route, width)
            page.screenshot(path=str(OUT / f'production-{route}-{width}.png'), full_page=True)
    assert len(config_requests) == 1, len(config_requests)
    assert errors == [], errors
    checks.append('Desktop/mobile public views: six visits, one config request, no overflow or browser exceptions')
    browser.close()
(OUT / 'production-verification.json').write_text(json.dumps({'checks': checks, 'browser_errors': errors}, ensure_ascii=False, indent=2))
print(json.dumps(checks, ensure_ascii=False, indent=2))
