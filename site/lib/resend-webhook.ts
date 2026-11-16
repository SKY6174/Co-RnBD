import { createHmac, timingSafeEqual } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOLERANCE_SECONDS = 5 * 60;
export const MAX_BODY_BYTES = 64 * 1024;
export const FEEDBACK_TYPES = ['email.delivered', 'email.delivery_delayed', 'email.bounced', 'email.complained', 'email.suppressed'] as const;
type FeedbackType = typeof FEEDBACK_TYPES[number];

export type FeedbackEvent = {
  type: FeedbackType; emailId: string; notificationId?: string;
  bounceType?: string; bounceSubType?: string; occurredAt?: string;
};

/** Svix manual verification: HMAC-SHA256 over `${id}.${timestamp}.${body}` with the base64 key after `whsec_`. */
export function verifySignature(
  secret: string | undefined, id: string | null, timestamp: string | null, signature: string | null,
  body: string, nowSeconds = Math.floor(Date.now() / 1000),
): boolean {
  if (!secret || !secret.startsWith('whsec_') || !id || !timestamp || !signature) return false;
  if (id.length > 100 || !/^\d{1,12}$/.test(timestamp)) return false;
  if (Math.abs(nowSeconds - Number(timestamp)) > TOLERANCE_SECONDS) return false;
  let key: Buffer;
  try { key = Buffer.from(secret.slice(6), 'base64'); } catch { return false; }
  if (key.length < 16) return false;
  const expected = createHmac('sha256', key).update(`${id}.${timestamp}.${body}`).digest();
  return signature.split(' ').some(entry => {
    const [version, value] = entry.split(',', 2);
    if (version !== 'v1' || !value) return false;
    const received = Buffer.from(value, 'base64');
    return received.length === expected.length && timingSafeEqual(received, expected);
  });
}

function shortText(value: unknown): string | undefined {
  return typeof value === 'string' && value.length <= 60 && !/[\u0000-\u001f]/.test(value) ? value : undefined;
}

/** Keep only what the database needs; addresses, subject and body never leave this function. */
export function parseFeedback(value: unknown): FeedbackEvent | 'unsupported' | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const e = value as Record<string, unknown>;
  if (typeof e.type !== 'string') return null;
  if (!(FEEDBACK_TYPES as readonly string[]).includes(e.type)) return 'unsupported';
  const data = e.data as Record<string, unknown> | undefined;
  if (!data || typeof data !== 'object' || typeof data.email_id !== 'string' || !UUID.test(data.email_id)) return null;
  const tags = data.tags && typeof data.tags === 'object' && !Array.isArray(data.tags) ? data.tags as Record<string, unknown> : {};
  const notificationId = typeof tags.notification_id === 'string' && UUID.test(tags.notification_id) ? tags.notification_id : undefined;
  const bounce = data.bounce && typeof data.bounce === 'object' ? data.bounce as Record<string, unknown> : {};
  const occurredAt = typeof e.created_at === 'string' && Number.isFinite(Date.parse(e.created_at)) ? e.created_at : undefined;
  return {
    type: e.type as FeedbackType, emailId: data.email_id, notificationId,
    bounceType: shortText(bounce.type), bounceSubType: shortText(bounce.subType), occurredAt,
  };
}
