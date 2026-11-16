import { MAX_BODY_BYTES, parseFeedback, verifySignature } from '../../../lib/resend-webhook';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 15;
const headers = { 'Cache-Control': 'no-store' };

// Resend delivery feedback (delivered / delayed / bounced / complained / suppressed) for outbox mail.
export async function POST(request: Request) {
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  const token = process.env.REVIEW_MAIL_WEBHOOK_SECRET;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (process.env.VERCEL_ENV !== 'production' || !secret || !token || token.length < 32 || !url || !key) {
    return Response.json({ error: 'Feedback not configured' }, { status: 503, headers });
  }
  if (Number(request.headers.get('content-length')) > MAX_BODY_BYTES) return new Response(null, { status: 413, headers });
  const body = await request.text();
  if (Buffer.byteLength(body) > MAX_BODY_BYTES) return new Response(null, { status: 413, headers });

  const id = request.headers.get('svix-id');
  if (!verifySignature(secret, id, request.headers.get('svix-timestamp'), request.headers.get('svix-signature'), body)) {
    return Response.json({ error: 'Invalid signature' }, { status: 401, headers });
  }
  let event;
  try { event = parseFeedback(JSON.parse(body)); } catch { event = null; }
  if (event === 'unsupported') return Response.json({ result: 'ignored' }, { headers });
  if (!event) return Response.json({ error: 'Invalid event' }, { status: 400, headers });

  try {
    const result = await fetch(new URL('/rest/v1/rpc/record_email_feedback', url), {
      method: 'POST',
      headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_token: token, p_message_id: id, p_event: event }),
      signal: AbortSignal.timeout(8000), cache: 'no-store',
    });
    if (!result.ok) {
      console.error('Delivery feedback was not recorded', { type: event.type, status: result.status });
      // 503 makes Resend retry; a stored event is never applied twice.
      return Response.json({ error: 'Feedback not recorded' }, { status: 503, headers });
    }
    return Response.json({ result: await result.json().catch(() => 'recorded') }, { headers });
  } catch {
    console.error('Delivery feedback store unavailable', { type: event.type });
    return Response.json({ error: 'Feedback not recorded' }, { status: 503, headers });
  }
}
