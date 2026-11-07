"""Review notification integration test. Disposable LOCAL Supabase only.
uv run --with playwright --with pymupdf python scripts/verify-review-email.py --environment /tmp/new-run
Runs the real editorial browser workflow, pg_net/cron, Next API and a loopback Resend stand-in.
Never reads production credentials or sends an external email.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--environment', type=Path, required=True)
OUT = parser.parse_args().environment.resolve()
META = json.loads((OUT / 'environment.json').read_text())
assert META['project'].startswith('co-rnbd-e2e-')
assert urlparse(META['api']).hostname == urlparse(META['base']).hostname == '127.0.0.1'
assert not (Path(META['local']) / 'supabase/.temp/project-ref').exists()
TOKEN = secrets.token_urlsafe(48)
RECEIPTS, REQUESTS, ERRORS, CHECKS = {}, [], [], []
LOCK = threading.Lock()
LOST_RESPONSES = set()
STOP = threading.Event()


def sql(statement):
    result = subprocess.run(['docker', 'exec', '-i', 'supabase_db_' + META['project'], 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'], input=statement, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def record(name):
    CHECKS.append(name)
    print('PASS: ' + name, flush=True)


class Collector(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global LOST_RESPONSES
        try:
            assert self.path == '/emails'
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert len(body['to']) == 1 and body['to'][0].endswith('@example.test')
            assert body['from'] == 'Co-R&BD 2026 <no-reply@co-rnbd.org>'
            assert not body.get('attachments') and 'signedUrl' not in json.dumps(body)
            key = self.headers['Idempotency-Key']
            assert key.startswith('co-rnbd-review/')
            with LOCK:
                if key in RECEIPTS:
                    assert RECEIPTS[key]['body'] == body, 'Retry changed provider payload'
                else:
                    RECEIPTS[key] = {'id': str(uuid.uuid4()), 'body': body}
                REQUESTS.append(key)
                # Emulate acceptance with a lost acknowledgment, then idempotent recovery.
                family = 3 if '논문 투고 알림' in body['subject'] or '재제출 알림' in body['subject'] else 2 if '심사의견 제출 알림' in body['subject'] else 1
                fail = family not in LOST_RESPONSES and '[테스트]' not in body['subject']
                if fail:
                    LOST_RESPONSES.add(family)
                result = {'id': RECEIPTS[key]['id']}
            self.send_response(503 if fail else 200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        except Exception as error:
            ERRORS.append(str(error))
            self.send_response(500)
            self.end_headers()


def hook(payload, token=TOKEN):
    request = urllib.request.Request(META['base'] + '/api/review-notifications', data=json.dumps(payload).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, None


def reconcile():
    try:
        while not STOP.wait(.3):
            # Accelerate only local retry delays; retain the real async request/ack path.
            sql("update app_private.review_email_outbox set next_attempt_at=now() where status='retry'; select app_private.process_review_email_queue();")
    except Exception as error:
        ERRORS.append(str(error))


collector = ThreadingHTTPServer(('127.0.0.1', 8790), Collector)
threading.Thread(target=collector.serve_forever, daemon=True).start()
worker = threading.Thread(target=reconcile, daemon=True)
child = None
try:
    # The disposable environment has applied every repository migration.
    sql("select vault.create_secret('" + TOKEN + "','review_email_webhook_token'); update app_private.review_email_config set enabled=true,endpoint='http://host.docker.internal:8786/api/review-notifications';")
    assert sql("select count(*) from cron.job where jobname='co-rnbd-review-email' and active") == '1'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SUPABASE_', 'PG', 'S3_', 'OPENAI_', 'VERCEL'))}
    env.update(REVIEW_MAIL_WEBHOOK_SECRET=TOKEN, REVIEW_MAIL_LOCAL_TEST='true', REVIEW_MAIL_LOCAL_PROVIDER='http://127.0.0.1:8790/emails', RESEND_API_KEY='local-collector-only')
    worker.start()
    child = subprocess.Popen([sys.executable, str(ROOT / 'scripts/verify-field-editor-review.py'), '--environment', str(OUT)], cwd=ROOT, env=env)
    for _ in range(150):
        if child.poll() is not None:
            raise RuntimeError('Editorial workflow exited before hook checks')
        try:
            if hook({}, 'wrong')[0] == 401:
                break
        except urllib.error.URLError:
            pass
        time.sleep(.2)
    else:
        raise RuntimeError('Local mail API not ready')
    sql("update app_private.review_email_config set paper_submitted_enabled=true,review_submitted_enabled=true,review_submitted_chair_ids=array(select id from auth.users where email='chief@example.test');")
    assert hook({})[0] == 400
    assert hook({'note': 'x' * 33000})[0] == 413
    event = {'version': 1, 'eventId': str(uuid.uuid4()), 'paperId': str(uuid.uuid4()), 'kind': 'decision', 'recipient': 'chief@example.test', 'recipientName': '합성 위원장', 'paperTitle': '합성 원고 <script>alert(1)</script>', 'conferenceTitle': 'Co-R&BD Conference 2026', 'editionYear': 2026, 'track': 'master_eng', 'decision': 'revision', 'note': '<img src=x onerror=alert(1)> 수정해 주세요.', 'test': True}
    assert hook({**event, 'recipient': 'a@example.test\r\nBcc:b@example.test'})[0] == 400
    first = hook(event)
    assert first[0] == 200 and hook(event) == first
    body = RECEIPTS['co-rnbd-review/' + event['eventId']]['body']
    assert '<script>' not in body['html'] and '<img src=x' not in body['html']
    assert '&lt;script&gt;' in body['html'] and '&lt;img' in body['html']
    assert '실제 원고 배정·판정·수정 요청이 아니며' in body['text']
    v2 = {**event, 'version': 2, 'eventId': str(uuid.uuid4()), 'kind': 'review_submitted', 'reviewId': str(uuid.uuid4()), 'reviewFingerprint': '0' * 32, 'note': ''}
    assert hook({**v2, 'version': 1})[0] == 400
    assert hook({**v2, 'note': 'PRIVATE REVIEW CONTENT'})[0] == 400
    assert hook(v2)[0] == 200
    assert '&lt;script&gt;' in RECEIPTS['co-rnbd-review/' + v2['eventId']]['body']['html']
    for kind in ['paper_submitted', 'paper_resubmitted']:
        v3 = {**event, 'version': 3, 'eventId': str(uuid.uuid4()), 'kind': kind, 'manuscriptAt': '2026-11-08T00:00:00.000+09:00', 'note': ''}
        assert hook({**v3, 'version': 2})[0] == 400
        assert hook({**v3, 'manuscriptAt': 'not-a-date'})[0] == 400
        assert hook({**v3, 'note': 'PRIVATE ABSTRACT'})[0] == 400
        assert hook(v3)[0] == 200
        assert '&lt;script&gt;' in RECEIPTS['co-rnbd-review/' + v3['eventId']]['body']['html']
    record('v1-v2-v3-hook-auth-input-limits-header-injection-HTML-escaping-provider-idempotency')
    assert child.wait(timeout=240) == 0, 'Editorial browser workflow failed'
    for _ in range(20):
        if sql("select count(*) from app_private.review_email_outbox where status in ('queued','sending','retry')") == '0':
            break
        time.sleep(.3)
    STOP.set()
    worker.join(timeout=5)
    assert not ERRORS, ERRORS
    rows = json.loads(sql("select json_agg(json_build_object('kind',kind,'status',status,'recipient',recipient_email,'attempts',attempts,'id',id,'review_id',review_id,'track',payload->>'track')) from app_private.review_email_outbox"))
    assert len(rows) == 27, rows
    assert all(r['status'] == 'sent' for r in rows), rows
    assert sum(r['kind'] == 'reviewer_assignment' for r in rows) == 6
    assert {r['recipient'] for r in rows if r['kind'] == 'reviewer_assignment'} == {'reviewer1@example.test', 'reviewer2@example.test'}
    assert {r['recipient'] for r in rows if r['kind'] == 'decision'} == {'author@example.test'}
    assert sum(r['attempts'] > 1 for r in rows) == 3 and LOST_RESPONSES == {1, 2, 3}
    assert len(RECEIPTS) == 31 and len(REQUESTS) == 35
    assert all('reviewer1' not in r['body']['text'] and 'reviewer2' not in r['body']['text'] for r in RECEIPTS.values() if r['body']['to'] == ['author@example.test'])
    submitted = [r for r in rows if r['kind'] == 'review_submitted']
    assert len(submitted) == 12
    for rid in {r['review_id'] for r in submitted}:
        notifications = [r for r in submitted if r['review_id'] == rid]
        assert len(notifications) == 2
        ae = 'reviewer1@example.test' if notifications[0]['track'] == 'master_eng' else 'reviewer2@example.test'
        assert {r['recipient'] for r in notifications} == {'chief@example.test', ae}, notifications
        for r in notifications:
            body = RECEIPTS['co-rnbd-review/' + r['id']]['body']
            assert '심사의견 제출 알림' in body['subject'] and 'https://co-rnbd.org/chair.html' in body['text']
            assert '합성 심사의견:' not in body['text']
    receipts = [r for r in rows if r['kind'] in ['paper_submitted', 'paper_resubmitted']]
    assert len(receipts) == 6 and sum(r['kind'] == 'paper_resubmitted' for r in receipts) == 2
    for kind in ['paper_submitted', 'paper_resubmitted']:
        for track in {r['track'] for r in receipts if r['kind'] == kind}:
            grouped = [r for r in receipts if r['kind'] == kind and r['track'] == track]
            assert len(grouped) == 2
            ae = 'reviewer1@example.test' if track == 'master_eng' else 'reviewer2@example.test'
            assert {r['recipient'] for r in grouped} == {'chief@example.test', ae}
            for r in grouped:
                b = RECEIPTS['co-rnbd-review/' + r['id']]['body']
                assert 'https://co-rnbd.org/chair.html' in b['text'] and not b.get('attachments')
                assert ('수정본 재제출 알림' if kind == 'paper_resubmitted' else '신규 논문 투고 알림') in b['subject']
    record('twenty-seven-workflow-events-paper-and-review-recipients-all-version-idempotent-retries')
    chief = sql("select id from auth.users where email='chief@example.test'")
    author = sql("select id from auth.users where email='author@example.test'")
    pid = sql("select id from public.papers where track='master_eng'")
    # Identical event cannot create a second notification; transaction rollback leaves none.
    before = sql('select count(*) from app_private.review_email_outbox')
    sql("begin; insert into public.paper_events(paper_id,actor_id,actor_label,action,after_data) select paper_id,actor_id,actor_label,action,after_data from public.paper_events where action='review_assigned' limit 1; commit;")
    assert sql('select count(*) from app_private.review_email_outbox') == before
    sql("begin; insert into public.paper_events(paper_id,actor_id,actor_label,action,after_data) select paper_id,actor_id,actor_label,action,after_data from public.paper_events where action='decision_published' limit 1; rollback;")
    assert sql('select count(*) from app_private.review_email_outbox') == before
    sql("begin; set local role authenticated; select set_config('request.jwt.claim.sub','" + chief + "',true); select * from public.review_email_status('" + pid + "'); rollback;")
    for role, user in [('authenticated', author), ('anon', '')]:
        try:
            sql("begin; set local role " + role + "; select set_config('request.jwt.claim.sub','" + user + "',true); select * from public.review_email_status('" + pid + "'); rollback;")
            raise AssertionError('Unauthorized status access allowed')
        except RuntimeError:
            pass
    assert sql("select has_table_privilege('authenticated','app_private.review_email_outbox','select') or has_function_privilege('authenticated','app_private.process_review_email_queue()','execute')") == 'f'
    record('deduplicated-event-transaction-rollback-and-status-permission-boundaries')
    # Clone already sent snapshots only inside rollback transactions, never re-send them.
    assignment = sql("select id from app_private.review_email_outbox where kind='reviewer_assignment' order by created_at limit 1")
    def guard(name, updates, expected):
        result = sql("begin; update app_private.review_email_outbox set status='retry',next_attempt_at=now()," + updates + " where id='" + assignment + "'; select app_private.process_review_email_queue(); select status||':'||last_error from app_private.review_email_outbox where id='" + assignment + "'; rollback;")
        assert expected in result, (name, result)
    guard('obsolete assignment', "attempts=0,first_attempt_at=null", 'cancelled:assignment_obsolete')
    guard('recipient changed', "attempts=0,first_attempt_at=null,recipient_email='different@example.test'", 'cancelled:recipient_changed')
    guard('cutoff', "attempts=1,first_attempt_at=now()-interval '23 hours 1 minute'", 'uncertain:idempotency_window')
    guard('attempts', "attempts=8,first_attempt_at=now()", 'failed:attempt_limit')
    decision = sql("select id from app_private.review_email_outbox where kind='decision' order by created_at limit 1")
    result = sql("begin; update app_private.review_email_outbox set status='retry',attempts=1,next_attempt_at=now(),first_attempt_at=now() where id='" + decision + "'; select app_private.process_review_email_queue(); select status||':'||last_error from app_private.review_email_outbox where id='" + decision + "'; rollback;")
    assert 'cancelled:decision_obsolete' in result, result
    for code, expected in [(422, 'failed:http_422'), (429, 'retry:http_429')]:
        result = sql("begin; update app_private.review_email_config set enabled=false; insert into net._http_response(id,status_code,content,timed_out) values(-999," + str(code) + ",'{}',false); update app_private.review_email_outbox set status='sending',request_id=-999,attempts=1,first_attempt_at=now(),attempted_at=now() where id='" + assignment + "'; select app_private.process_review_email_queue(); select status||':'||last_error from app_private.review_email_outbox where id='" + assignment + "'; rollback;")
        assert expected in result, result
    result = sql("begin; update app_private.review_email_config set enabled=false; update app_private.review_email_outbox set status='sending',request_id=null,attempts=1,first_attempt_at=now(),attempted_at=now()-interval '3 minutes' where id='" + assignment + "'; select app_private.process_review_email_queue(); select status||':'||last_error from app_private.review_email_outbox where id='" + assignment + "'; rollback;")
    assert 'retry:response_timeout' in result, result
    # Re-enable a field editor inside rollback to check scope without altering the fixture.
    ae = sql("select id from auth.users where email='reviewer1@example.test'")
    sql("begin; update public.review_committee set active=true where committee_role='associate_editor' and track='master_eng'; set local role authenticated; select set_config('request.jwt.claim.sub','" + ae + "',true); select * from public.review_email_status('" + pid + "'); rollback;")
    record('stale-assignment-decision-address-cutoff-attempt-limit-4xx-429-lease-and-AE-status-access')
    count_before = sql('select count(*) from app_private.review_email_outbox')
    sql((ROOT / 'scripts/verify-review-submitted.sql').read_text())
    assert sql('select count(*) from app_private.review_email_outbox') == count_before
    record('draft-identical-edited-submissions-role-conflict-dedupe-and-obsolete-rollback-checks')
    sql((ROOT / 'scripts/verify-paper-submitted.sql').read_text())
    assert sql('select count(*) from app_private.review_email_outbox') == count_before
    record('initial-revision-draft-failure-replay-pause-role-snapshot-rollback-checks')
    record('all-mail-left-local-db-only-and-no-live-provider-credentials')
    (OUT / 'email-results.json').write_text(json.dumps({'status': 'PASS', 'checks': CHECKS, 'events': rows, 'provider_receipts': len(RECEIPTS), 'requests': len(REQUESTS)}, ensure_ascii=False, indent=2))
finally:
    STOP.set()
    if child and child.poll() is None:
        child.terminate()
        child.wait(timeout=15)
    collector.shutdown()
