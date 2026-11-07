import { timingSafeEqual } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PORTAL = 'https://co-rnbd.org/submission.html';
const DECISIONS: Record<string, string> = { accepted: 'Accept · 채택', revision: '수정 후 채택 검토 · 수정본 요청', rejected: 'Reject · 반려' };
const TRACKS: Record<string, string> = { master_eng: '전문기술석사 공학', master_sci: '전문기술석사 자연과학', industry_joint: '산학공동기술개발과제', convergence_etc: '기타 산학융합과제', applied: '전문기술석사 응용연구', industry: '산학공동기술개발', convergence: '산업융합기술', education: 'T-VET 정책·교육연구' };

type MailEvent = {
  version: 1 | 2 | 3 | 4; eventId: string; kind: 'reviewer_assignment' | 'decision' | 'review_submitted' | 'paper_submitted' | 'paper_resubmitted' | 'author_submission_receipt' | 'author_resubmission_receipt';
  recipient: string; recipientName: string; paperId: string; paperTitle: string;
  conferenceTitle: string; editionYear: number; track: string;
  submissionEventId?: string; manuscriptAt?: string; reviewId?: string; reviewFingerprint?: string; decision?: string | null; note: string; exceptionReason?: string; test?: boolean;
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
  const paperSubmission = e.kind === 'paper_submitted' || e.kind === 'paper_resubmitted';
  const authorReceipt = e.kind === 'author_submission_receipt' || e.kind === 'author_resubmission_receipt';
  if (e.version !== (authorReceipt ? 4 : paperSubmission ? 3 : e.kind === 'review_submitted' ? 2 : 1) || !text(e.eventId, 36, 36) || !UUID.test(e.eventId)
    || !text(e.paperId, 36, 36) || !UUID.test(e.paperId)
    || !['reviewer_assignment', 'decision', 'review_submitted', 'paper_submitted', 'paper_resubmitted', 'author_submission_receipt', 'author_resubmission_receipt'].includes(String(e.kind))
    || !text(e.recipient, 254, 3) || !EMAIL.test(e.recipient)
    || !text(e.recipientName, 120, 1) || !text(e.paperTitle, 250, 5)
    || !text(e.conferenceTitle, 250, 1) || !text(e.track, 50, 1) || !Object.hasOwn(TRACKS, e.track)
    || !Number.isInteger(e.editionYear) || Number(e.editionYear) < 2020 || Number(e.editionYear) > 2200
    || !text(e.note, 5000) || (e.exceptionReason !== undefined && !text(e.exceptionReason, 1000))
    || (e.test !== undefined && typeof e.test !== 'boolean')
    || (e.kind === 'review_submitted' && (!text(e.reviewId, 36, 36) || !UUID.test(e.reviewId)
      || !text(e.reviewFingerprint, 32, 32) || !/^[0-9a-f]{32}$/.test(e.reviewFingerprint) || e.note !== '' || (e.exceptionReason !== undefined && e.exceptionReason !== '')))
    || ((paperSubmission || authorReceipt) && (!text(e.manuscriptAt, 40, 20) || !Number.isFinite(Date.parse(e.manuscriptAt))
      || e.note !== '' || (e.exceptionReason !== undefined && e.exceptionReason !== '')))
    || (authorReceipt && (!text(e.submissionEventId, 36, 36) || !UUID.test(e.submissionEventId)
      || !text(e.manuscriptAt, 40, 20) || !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(e.manuscriptAt)))
    || (e.kind === 'decision' && (!text(e.decision, 20) || !Object.hasOwn(DECISIONS, e.decision)))) return null;
  return e as MailEvent;
}

const esc = (v: string) => v.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// Keep version 1 rendering stable across retries; a future format uses a new version.
export function renderMail(e: MailEvent) {
  if (e.kind === 'author_submission_receipt' || e.kind === 'author_resubmission_receipt') return renderAuthorReceipt(e);
  if (e.kind === 'review_submitted') return renderReviewSubmitted(e);
  if (e.kind === 'paper_submitted' || e.kind === 'paper_resubmitted') return renderPaperSubmitted(e);
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

// v2 is independent so in-flight v1 provider payloads remain byte-for-byte stable.
function renderReviewSubmitted(e: MailEvent) {
  const portal = 'https://co-rnbd.org/chair.html';
  const heading = '심사의견 제출 알림';
  const subject = `${e.test ? '[테스트] ' : ''}[Co-R&BD ${e.editionYear}] ${heading}`;
  const lines = [e.test ? '이 메일은 심사의견 제출 알림 연결 확인용 테스트입니다. 실제 원고나 심사 제출을 의미하지 않으며 조치하지 않으셔도 됩니다.' : '',
    `${e.recipientName}님,`, e.conferenceTitle, '담당 원고의 심사의견이 제출되었습니다.',
    `원고: ${e.paperTitle}`, `접수번호: ${e.paperId.slice(0, 8).toUpperCase()} · ${TRACKS[e.track]}`,
    '원고 심사 관리에 로그인하여 최신 진행 상태와 제출된 심사의견을 확인해 주세요. 판정 전에는 현재 제출본의 심사 완료 요건을 확인해 주세요.',
    `원고 심사 관리: ${portal}`, '심사의견 본문과 심사위원 정보는 권한이 있는 계정으로 포털에서 확인해 주세요. 이 주소는 자동 발송용입니다.'].filter(Boolean);
  return { subject, text: lines.join('\n\n'), html: '<!doctype html><html lang="ko"><head><meta charset="UTF-8"></head><body><main style="font-family:Arial,sans-serif;max-width:640px;margin:auto;line-height:1.7;color:#14382e">'
    + `<h1 style="font-size:22px">${heading}</h1>` + lines.map(line => `<p style="white-space:pre-wrap">${esc(line)}</p>`).join('')
    + `<p><a href="${portal}">원고 심사 관리 열기</a></p></main></body></html>` };
}

// v3 leaves prior v1/v2 retry payloads unchanged.
function renderPaperSubmitted(e: MailEvent) {
  const portal = 'https://co-rnbd.org/chair.html';
  const revision = e.kind === 'paper_resubmitted';
  const heading = revision ? '수정본 재제출 알림' : '신규 논문 투고 알림';
  const subject = `${e.test ? '[테스트] ' : ''}[Co-R&BD ${e.editionYear}] ${heading}`;
  const lines = [e.test ? '이 메일은 투고 알림 연결 확인용 테스트입니다. 실제 논문 투고·수정본 재제출이 아니며 조치하지 않으셔도 됩니다.' : '',
    `${e.recipientName}님,`, e.conferenceTitle, revision ? '담당 원고의 수정본이 재제출되었습니다.' : '담당 분야에 새 논문이 투고되었습니다.',
    `원고: ${e.paperTitle}`, `접수번호: ${e.paperId.slice(0, 8).toUpperCase()} · ${TRACKS[e.track]}`,
    '원고 심사 관리에 로그인하여 현재 제출본과 진행 상태를 확인해 주세요.',
    `원고 심사 관리: ${portal}`, '원고 PDF와 저자 정보는 권한이 있는 계정으로 포털에서 확인해 주세요. 이 주소는 자동 발송용입니다.'].filter(Boolean);
  return { subject, text: lines.join('\n\n'), html: '<!doctype html><html lang="ko"><head><meta charset="UTF-8"></head><body><main style="font-family:Arial,sans-serif;max-width:640px;margin:auto;line-height:1.7;color:#14382e">'
    + `<h1 style="font-size:22px">${heading}</h1>` + lines.map(line => `<p style="white-space:pre-wrap">${esc(line)}</p>`).join('')
    + `<p><a href="${portal}">원고 심사 관리 열기</a></p></main></body></html>` };
}

// v4 confirms the stored submission snapshot; prior mail versions remain unchanged.
function renderAuthorReceipt(e: MailEvent) {
  const revision = e.kind === 'author_resubmission_receipt';
  const heading = revision ? '수정본 재제출 접수 확인' : '신규 투고 접수 확인';
  const subject = `${e.test ? '[테스트] ' : ''}[Co-R&BD ${e.editionYear}] ${heading}`;
  const receivedAt = new Date(new Date(e.manuscriptAt!).getTime() + 9 * 60 * 60 * 1000).toISOString().slice(0, 19).replace('T', ' ') + ' KST';
  const lines = [e.test ? '이 메일은 투고자 접수 확인 연결 테스트입니다. 실제 논문 투고·수정본 재제출이 아니며 조치하지 않으셔도 됩니다.' : '',
    `${e.recipientName}님,`, e.conferenceTitle, revision ? '수정본 재제출이 접수되었습니다.' : '신규 논문 투고가 접수되었습니다.',
    `원고: ${e.paperTitle}`, `접수번호: ${e.paperId.slice(0, 8).toUpperCase()} · ${TRACKS[e.track]}`, `접수 시각: ${receivedAt}`,
    '이 메일은 위 접수 시각에 저장된 제출본의 접수 확인입니다. 내 원고에서 현재 제출본, 심사 진행과 판정을 확인해 주세요.',
    `내 원고: ${PORTAL}`, '접수 확인은 투고 계정의 인증된 이메일로 보냅니다. 이 주소는 자동 발송용입니다.'].filter(Boolean);
  return { subject, text: lines.join('\n\n'), html: '<!doctype html><html lang="ko"><head><meta charset="UTF-8"></head><body><main style="font-family:Arial,sans-serif;max-width:640px;margin:auto;line-height:1.7;color:#14382e">'
    + `<h1 style="font-size:22px">${heading}</h1>` + lines.map(line => `<p style="white-space:pre-wrap">${esc(line)}</p>`).join('')
    + `<p><a href="${PORTAL}">내 원고 확인하기</a></p></main></body></html>` };
}
