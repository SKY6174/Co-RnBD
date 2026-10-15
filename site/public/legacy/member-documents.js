import { escapeHtml as esc, requireData } from './conference-client.js';
export const KINDS = { attendance: '참가확인증', receipt: '영수증', statement: '거래명세서' };
export const BILLING = { unpaid: '납부 확인 전', paid: '납부 확인', waived: '등록비 면제', refunded: '환불 확인' };
export const METHODS = { transfer: '계좌이체', cash: '현금', other: '기타' };
export const STATES = { applied: '참가 확인 대기', confirmed: '참가 확정', cancelled: '참가 취소' };
export const money = (value) => new Intl.NumberFormat('ko-KR').format(value) + '원';
export const date = (value) => value ? new Intl.DateTimeFormat('ko-KR', {timeZone:'Asia/Seoul',dateStyle:'medium'}).format(new Date(value)) : '—';
export const one = (value) => Array.isArray(value) ? value[0] : value;
export const REGISTRATION_COLUMNS = 'id,user_id,edition_year,category,attendance_days,status,checked_in_at,created_at,conference_editions(title,start_date,end_date,venue),registration_billing(amount,status,payment_method,paid_at),registration_documents(id,kind,document_no,state,issued_at,revocation_reason)';
export function unavailable(row, kind, issuer) {
  if (row.status !== 'confirmed') return '참가 확정 후 발급';
  if (!issuer?.enabled) return '운영자 발급 설정 준비 중';
  if (kind === 'attendance') return row.checked_in_at ? '' : '현장 체크인 확인 후 발급';
  const bill = one(row.registration_billing);
  if (!bill) return '등록비 내역 설정 후 발급';
  if (kind === 'receipt' && bill.status !== 'paid') return bill.status === 'waived' ? '등록비 면제 · 영수증 대상 아님' : '실제 납부 확인 후 발급';
  return '';
}
export function cards(row, issuer) {
  return `<div class="document-card-grid">${Object.entries(KINDS).map(([kind,label])=>{
    const doc=(row.registration_documents||[]).find(d=>d.kind===kind&&d.state==='issued');
    const reason=unavailable(row,kind,issuer);
    return `<article class="document-card"><span class="document-icon" aria-hidden="true">${kind==='attendance'?'01':kind==='receipt'?'02':'03'}</span><h3>${label}</h3><p>${doc?esc(doc.document_no):esc(reason||'등록정보로 바로 발급할 수 있습니다.')}</p>${doc?`<a class="operations-button secondary" href="./document.html?id=${doc.id}">보기·인쇄 / PDF</a>`:`<button class="operations-button secondary" data-issue="${row.id}" data-kind="${kind}" ${reason?'disabled':''}>발급·인쇄 / PDF</button>`}</article>`;
  }).join('')}</div>`;
}
export function friendly(error) {
  const message=error?.message||'처리하지 못했습니다. 다시 시도해 주세요.';
  const entries=[['Issuer configuration','발급기관 설정이 완료되지 않았습니다.'],['Confirmed registration','참가 확정 후 발급할 수 있습니다.'],['Attendance check-in','현장 체크인 확인 후 참가확인증을 발급할 수 있습니다.'],['Verified payment','운영자의 실제 납부 확인 후 영수증을 발급할 수 있습니다.'],['fee configuration','등록비 내역을 먼저 설정해 주세요.'],['Chair permission','위원장 권한이 필요합니다.'],['Registration permission','본인의 참가 내역만 이용할 수 있습니다.'],['Payment date','납부 일시는 현재보다 미래일 수 없습니다.'],['immutable','발급된 문서는 수정할 수 없습니다. 발급 취소 후 다시 발급해 주세요.'],['Document changed','문서 상태가 변경되었습니다. 새로고침해 주세요.']];
  return entries.find(([key])=>message.includes(key))?.[1]||message;
}
export async function issue(client, registration, kind) {
  return requireData(await client.rpc('issue_registration_document',{p_registration_id:registration,p_kind:kind}));
}
