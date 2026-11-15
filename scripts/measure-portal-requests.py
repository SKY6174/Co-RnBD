"""Measure real local portal requests without recording credentials or response bodies.
Requires the isolated fixtures from verify-submission-lifecycle.py.
uv run --with playwright python scripts/measure-portal-requests.py before
"""
import collections
import importlib.util
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright, expect

spec = importlib.util.spec_from_file_location('lifecycle', Path(__file__).with_name('verify-submission-lifecycle.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out = m.ROOT / 'outputs/db-response-optimization'
out.mkdir(parents=True, exist_ok=True)
label = sys.argv[1] if len(sys.argv) > 1 else 'measurement'
assert label.isalnum(), 'Use a simple measurement label'
results = []

with sync_playwright() as p:
    browser = p.chromium.launch(channel='chrome', headless=True)
    page = m.login(browser, 'chair')
    page.wait_for_timeout(500)
    for iteration in range(3):
        for route, selector in [('chair', '#chair-workspace'), ('registration', '#registration-sign-out-actions'), ('submission', '#workspace')]:
            responses = []
            def capture(response):
                if response.url.startswith(m.API) or urlparse(response.url).path == '/api/config':
                    responses.append(response)
            page.on('response', capture)
            started = time.perf_counter()
            page.goto(m.BASE + '/' + route + '.html', wait_until='domcontentloaded')
            expect(page.locator(selector)).to_be_visible()
            if route == 'registration':
                expect(page.locator('#registration-account')).to_contain_text('검증')
            ready_ms = round((time.perf_counter() - started) * 1000)
            # Include queued auth callbacks after the visible workspace becomes ready.
            page.wait_for_timeout(800)
            page.remove_listener('response', capture)
            counts, sizes = collections.Counter(), collections.Counter()
            statuses = collections.Counter()
            for response in responses:
                path = urlparse(response.url).path
                counts[path] += 1
                statuses[str(response.status)] += 1
                sizes[path] += len(response.body())
            results.append({'route': route, 'iteration': iteration, 'ready_ms': ready_ms,
                            'requests': dict(counts), 'decoded_bytes': dict(sizes), 'statuses': dict(statuses)})
    browser.close()
assert not m.ERRORS, m.ERRORS
(out / f'{label}.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
