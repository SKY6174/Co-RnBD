import { authorized, parseMailEvent, providerEndpoint, renderMail } from '../../../lib/review-email';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;
const headers = { 'Cache-Control': 'no-store' };

export async function POST(request: Request) {
  if (!authorized(request.headers.get('authorization'), process.env.REVIEW_MAIL_WEBHOOK_SECRET)) {
    return Response.json({ error: 'Unauthorized' }, { status: 401, headers });
  }
  const endpoint = providerEndpoint();
  const apiKey = process.env.RESEND_API_KEY;
  if (!endpoint || !apiKey) return Response.json({ error: 'Delivery not configured' }, { status: 503, headers });
  if (Number(request.headers.get('content-length')) > 32000) return new Response(null, { status: 413, headers });
  let event;
  try {
    const body = await request.text();
    if (Buffer.byteLength(body) > 32000) return new Response(null, { status: 413, headers });
    event = parseMailEvent(JSON.parse(body));
  } catch { return Response.json({ error: 'Invalid event' }, { status: 400, headers }); }
  if (!event) return Response.json({ error: 'Invalid event' }, { status: 400, headers });
  try {
    const result = await fetch(endpoint, {
      method: 'POST', headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json', 'Idempotency-Key': 'co-rnbd-review/' + event.eventId },
      body: JSON.stringify({ from: 'Co-R&BD 2026 <no-reply@co-rnbd.org>', to: [event.recipient], ...renderMail(event), tags: [{ name: 'notification_id', value: event.eventId }] }),
      signal: AbortSignal.timeout(8000), cache: 'no-store',
    });
    const payload = await result.json().catch(() => ({}));
    if (!result.ok) {
      console.error('Review email provider rejected event', { eventId: event.eventId, status: result.status });
      const status = result.status === 409 && payload.name === 'concurrent_idempotent_requests' ? 503 : result.status;
      return Response.json({ error: 'Provider rejected request' }, { status: [400,401,403,409,422,429].includes(status) ? status : 503, headers });
    }
    if (typeof payload.id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.id)) throw new Error('Provider response missing ID');
    return Response.json({ id: payload.id }, { headers });
  } catch {
    console.error('Review email delivery unavailable', { eventId: event.eventId });
    return Response.json({ error: 'Delivery unavailable' }, { status: 503, headers });
  }
}
