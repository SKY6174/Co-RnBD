import { timingSafeEqual } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PORTAL = 'https://co-rnbd.org/submission.html';
const DECISIONS: Record<string, string> = { accepted: 'Accept · 채택', revision: '수정 후 채택 검토 · 수정본 요청', rejected: 'Reject · 반려' };
const TRACKS: Record<string, string> = { master_eng: '전문기술석사 공학', master_sci: '전문기술석사 자연과학', industry_joint: '산학공동기술개발과제', convergence_etc: '기타 산학융합과제', applied: '전문기술석사 응용연구', industry: '산학공동기술개발', convergence: '산업융합기술', education: 'T-VET 정책·교육연구' };

type MailEvent = {
  version: 1; eventId: string; kind: 'reviewer_assignment' | 'decision';
  recipient: string; recipientName: string; paperId: string; paperTitle: string;
  conferenceTitle: string; editionYear: number; track: string;
  decision?: string | null; note: string; exceptionReason?: string; test?: boolean;
};

export function authorized(bearer: string | null, secret: string | undefined): boolean {
  if (!secret || secret.length < 32 || !bearer) return false;
  const expected = Buffer.from('Bearer ' + secret);
  const received = Buffer.from(bearer);
  return expected.length === received.length && timingSafeEqual(expected, received);
}

function text(value: unknown, max: number, min = 0): value is string {
  return typeof value === 'string' && value.length >= min && value.length <= max && !value.includes('\u0000');
}

export function parseMailEvent(value: unknown): MailEvent | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const e = value as Record<string, unknown>;
  if (e.version !== 1 || !text(e.eventId, 36, 36) || !UUID.test(e.eventId)
    || !text(e.paperId, 36, 36) || !UUID.test(e.paperId)
    || !['reviewer_assignment', 'decision'].includes(String(e.kind))
    || !text(e.recipient, 254, 3) || !EMAIL.test(e.recipient)
    || !text(e.recipientName, 120, 1) || !text(e.paperTitle, 250, 5)
    || !text(e.conferenceTitle, 250, 1) || !text(e.track, 50, 1) || !Object.hasOwn(TRACKS, e.track)
    || !Number.isInteger(e.editionYear) || Number(e.editionYear) < 2020 || Number(e.editionYear) > 2200
    || !text(e.note, 5000) || (e.exceptionReason !== undefined && !text(e.exceptionReason, 1000))
    || (e.test !== undefined && typeof e.test !== 'boolean')
    || (e.kind === 'decision' && (!text(e.decision, 20) || !Object.hasOwn(DECISIONS, e.decision)))) return null;
  return e as MailEvent;
}

const esc = (v: string) => v.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// Keep version 1 rendering stable across retries; a future format uses a new version.
export function renderMail(e: MailEvent) {
  const assigned = e.kind === 'reviewer_assignment';
  const heading = assigned ? '논문 심사 배정 요청' : DECISIONS[e.decision!];
  const subject = `${e.test ? '[테스트] ' : ''}[Co-R&BD ${e.editionYear}] ${heading}`.replace(/[\r\n]/g, ' ');
  const instruction = assigned
    ? '논문 심사가 배정되었습니다. 포털에 로그인한 뒤 ‘심사 배정’에서 원고를 확인해 주세요. 저자·소속·과제의 이해관계를 확인하고, 이해관계가 있으면 사유와 함께 배정을 거절해 주세요.'
    : e.decision === 'revision'
      ? '수정 요청 내용을 확인하고 같은 원고에서 수정 PDF를 올려 다시 제출해 주세요. 수정 후 채택 검토는 최종 채택이 아니며 재심과 판정이 필요합니다.'
      : e.decision === 'accepted'
        ? '원고가 채택되었습니다. 최종본 제출 단계와 후속 안내는 포털에서 확인해 주세요.'
        : '심사 결과 원고가 반려되었습니다. 공개된 판정 사유와 심사의견은 포털에서 확인해 주세요.';
  const lines = [e.test ? '이 메일은 자동 발송 연결 확인용 테스트입니다. 실제 원고 배정·판정·수정 요청이 아니며 조치하지 않으셔도 됩니다.' : '',
    `${e.recipientName}님,`, e.conferenceTitle, heading, `원고: ${e.paperTitle}`,
    `접수번호: ${e.paperId.slice(0, 8).toUpperCase()} · ${TRACKS[e.track]}`, instruction,
    !assigned && e.note ? `판정 사유\n${e.note}` : '',
    e.exceptionReason ? `심사위원장 예외 판정 사유\n${e.exceptionReason}` : '',
    `투고·심사 포털: ${PORTAL}`, 'PDF와 상세 심사의견은 권한이 있는 계정으로 포털에서 확인해 주세요. 이 주소는 자동 발송용입니다.'].filter(Boolean);
  return { subject, text: lines.join('\n\n'), html: '<!doctype html><html lang="ko"><head><meta charset="UTF-8"></head><body><main style="font-family:Arial,sans-serif;max-width:640px;margin:auto;line-height:1.7;color:#14382e">'
    + `<h1 style="font-size:22px">${esc(heading)}</h1>`
    + lines.map(line => `<p style="white-space:pre-wrap">${esc(line)}</p>`).join('')
    + `<p><a href="${PORTAL}">투고·심사 포털 열기</a></p></main></body></html>` };
}

export function providerEndpoint(): string | null {
  if (process.env.VERCEL_ENV === 'production') return 'https://api.resend.com/emails';
  // A local, isolated test can only use a loopback mail collector, never Resend.
  try {
    const db = new URL(process.env.SUPABASE_URL || '');
    const provider = new URL(process.env.REVIEW_MAIL_LOCAL_PROVIDER || '');
    if (!process.env.VERCEL_ENV && process.env.REVIEW_MAIL_LOCAL_TEST === 'true'
      && ['localhost', '127.0.0.1'].includes(db.hostname)
      && provider.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(provider.hostname)
      && provider.pathname === '/emails') return provider.href;
  } catch { /* Missing local settings disable the endpoint. */ }
  return null;
}
