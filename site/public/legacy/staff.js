import { conferenceClient, currentEdition, escapeHtml, requireData } from './conference-client.js';

// Read-only lists for the organizing committee. Data comes only from the staff_list_* functions,
// which check the grant, return a fixed column set and log each read.
const $ = (selector) => document.querySelector(selector);
const ROLES = { chair: '위원장', organizing_chair: '조직위원장', program_chair: '학술위원장', secretariat: '사무국' };
const CATEGORIES = { student: '학생·졸업생', faculty: '교원·연구자', industry: '기업·기관', other: '기타', presenter: '논문·사례 발표자' };
const REG_STATES = { applied: '확인 대기', confirmed: '참가 확정', cancelled: '취소됨' };
const PAY = { unpaid: '납부 확인 전', paid: '납부 확인', waived: '면제', refunded: '환불' };
const METHODS = { transfer: '계좌이체', cash: '현금', other: '기타' };
const won = (v) => v == null ? '' : new Intl.NumberFormat('ko-KR').format(v) + '원';
const PAPER_STATES = { submitted: '접수', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려', withdrawn: '철회' };
const TRACKS = { master_eng: '전문기술석사 (공학)', master_sci: '전문기술석사 (자연과학)', industry_joint: '산학공동기술개발과제', convergence_etc: '기타 산학융합과제' };
const COMMITTEE = { reviewer: '심사위원', associate_editor: '분야위원장' };
const SESSION_TYPES = { oral: '구두', poster: '포스터' };

const dateTime = (v) => v ? new Intl.DateTimeFormat('ko-KR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'Asia/Seoul' }).format(new Date(v)) : '';
const day = (v) => { const [, m, d] = v.split('-').map(Number); return `${m}/${d}`; };

const LISTS = {
  registrations: {
    title: '등록자', rpc: 'staff_list_registrations',
    columns: [['등록번호', r => r.registration_no], ['이름', r => r.full_name], ['소속', r => [r.affiliation, r.department, r.position_title].filter(Boolean).join(' · ')],
      ['이메일', r => r.email], ['구분', r => CATEGORIES[r.category] || r.category], ['참가일', r => (r.attendance_days || []).map(day).join(', ')],
      ['신청 상태', r => REG_STATES[r.status] || r.status], ['납부', r => PAY[r.payment_status] || r.payment_status], ['등록비', r => won(r.fee_amount)],
      ['납부 방법', r => METHODS[r.payment_method] || ''], ['납부일', r => dateTime(r.paid_at)], ['체크인', r => dateTime(r.checked_in_at)], ['신청일', r => dateTime(r.applied_at)]],
    summary: (rows) => {
      const live = rows.filter(r => r.status !== 'cancelled');
      const count = (list, f) => list.filter(f).length;
      const paidSum = rows.filter(r => r.payment_status === 'paid').reduce((t, r) => t + (r.fee_amount || 0), 0);
      return [`신청 ${rows.length}명 (확인 대기 ${count(rows, r => r.status === 'applied')} · 참가 확정 ${count(rows, r => r.status === 'confirmed')} · 취소 ${count(rows, r => r.status === 'cancelled')})`,
        `유효 신청 ${live.length}명 중 납부 확인 ${count(live, r => r.payment_status === 'paid')} · 납부 확인 전 ${count(live, r => r.payment_status === 'unpaid')} · 면제 ${count(live, r => r.payment_status === 'waived')} · 환불 ${count(rows, r => r.payment_status === 'refunded')}`,
        `납부 확인 금액 합계 ${won(paidSum)} · 체크인 ${count(rows, r => r.checked_in_at)}명`];
    },
  },
  submissions: {
    title: '논문 제출자', rpc: 'staff_list_submissions',
    columns: [['접수번호', r => r.paper_no], ['제목', r => r.title], ['분야', r => TRACKS[r.track] || r.track], ['상태', r => PAPER_STATES[r.status] || r.status],
      ['제출자', r => r.submitter_name], ['제출자 소속', r => r.submitter_affiliation], ['제출자 이메일', r => r.submitter_email], ['저자', r => r.authors],
      ['심사', r => `${r.reviews_submitted}/${r.reviewers_assigned}`], ['제출일', r => dateTime(r.submitted_at)]],
  },
  reviewers: {
    title: '심사위원', rpc: 'staff_list_reviewers',
    columns: [['분야', r => TRACKS[r.track] || r.track], ['역할', r => COMMITTEE[r.committee_role] || r.committee_role], ['이름', r => r.display_name],
      ['소속', r => r.affiliation], ['이메일', r => r.email], ['계정', r => r.has_account ? '연결됨' : '미가입'], ['활성', r => r.active ? '예' : '아니오'],
      ['배정·제출·거절', r => `${r.assigned}·${r.submitted}·${r.declined}`]],
  },
  session_chairs: {
    title: '좌장', rpc: 'staff_list_session_chairs',
    columns: [['세션', r => r.session_title], ['유형', r => SESSION_TYPES[r.session_type] || r.session_type], ['시간', r => r.starts_at ? `${dateTime(r.starts_at)}–${dateTime(r.ends_at).split(' ').pop()}` : '미정'],
      ['장소', r => r.room], ['좌장', r => r.chair_name], ['소속', r => r.chair_affiliation], ['이메일', r => r.chair_email], ['발표', r => r.presentations],
      ['보고서', r => r.report_submitted_at ? `제출 ${dateTime(r.report_submitted_at)}` : '미제출'], ['공개', r => r.is_published ? '공개' : '비공개']],
  },
};

let client, edition, current = null, rows = [];

function notice(text, error = false) {
  $('#staff-message').textContent = text;
  $('#staff-message').classList.toggle('error', error);
}

function render() {
  const spec = LISTS[current];
  const search = $('#staff-search').value.trim().toLocaleLowerCase();
  const cells = rows.map(r => spec.columns.map(([, get]) => String(get(r) ?? '')));
  const shown = cells.filter(c => !search || c.join(' ').toLocaleLowerCase().includes(search));
  $('#staff-head').innerHTML = `<tr>${spec.columns.map(([label]) => `<th scope="col">${escapeHtml(label)}</th>`).join('')}</tr>`;
  $('#staff-body').innerHTML = shown.map(c => `<tr>${c.map(v => `<td>${escapeHtml(v)}</td>`).join('')}</tr>`).join('')
    || `<tr><td colspan="${spec.columns.length}">${rows.length ? '검색 조건에 맞는 항목이 없습니다.' : '아직 등록된 항목이 없습니다.'}</td></tr>`;
  $('#staff-count').textContent = `${shown.length}건 표시 · 전체 ${rows.length}건`;
  $('#staff-summary').hidden = !spec.summary;
  $('#staff-summary').innerHTML = spec.summary ? spec.summary(rows).map(line => `<p>${escapeHtml(line)}</p>`).join('') : '';
}

async function open(list) {
  current = list;
  document.querySelectorAll('[data-list]').forEach(b => b.setAttribute('aria-selected', String(b.dataset.list === list)));
  $('#staff-panel').hidden = false;
  $('#staff-list-title').textContent = LISTS[list].title;
  $('#staff-body').innerHTML = '';
  $('#staff-count').textContent = '불러오는 중입니다.';
  try {
    rows = requireData(await client.rpc(LISTS[list].rpc, { p_year: edition.year })) || [];
    render();
  } catch (error) { rows = []; $('#staff-count').textContent = ''; notice(error.message, true); }
}

document.querySelectorAll('[data-list]').forEach(b => b.addEventListener('click', () => open(b.dataset.list)));
$('#staff-search').addEventListener('input', () => current && render());

async function start() {
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (!auth.data?.user) throw new Error('운영진 계정으로 로그인해 주세요. 로그인은 투고·심사 화면에서 할 수 있습니다.');
    edition = await currentEdition(client);
    $('#staff-edition-label').textContent = `CO-R&BD ${edition.year} / ORGANIZING COMMITTEE`;
    const access = (requireData(await client.rpc('staff_my_access', { p_year: edition.year })) || [])[0];
    if (!access) throw new Error('명단 조회 권한이 없습니다. 위원장에게 운영진 권한을 요청해 주세요.');
    $('#staff-access').textContent = `${ROLES[access.staff_role] || access.staff_role} 권한${access.expires_at ? ` · ${dateTime(access.expires_at)}까지` : ''}`;
    $('#staff-workspace').hidden = false;
    notice('조회할 명단을 선택하세요.');
  } catch (error) { notice(error.message, true); }
}

start();
