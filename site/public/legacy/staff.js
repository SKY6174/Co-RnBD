import { conferenceClient, currentEdition, escapeHtml, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const ROLES = { chair: '위원장', organizing_chair: '조직위원장', program_chair: '학술위원장', secretariat: '사무국' };
const CATEGORIES = { student: '학생·졸업생', faculty: '교원·연구자', industry: '기업·기관', other: '기타', presenter: '논문·사례 발표자' };
const REG_STATES = { applied: '확인 대기', confirmed: '참가 확정', cancelled: '취소' };
const PAYMENT = { unpaid: '납부 확인 전', paid: '납부 확인', waived: '면제', refunded: '환불' };
const METHODS = { transfer: '계좌이체', cash: '현금', other: '기타' };
const PAPER_STATES = { submitted: '접수', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려', withdrawn: '철회' };
const STAGES = { waiting: '심사 전', reviewing: '심사 중', deciding: '판정 대기', decided: '심사 후', withdrawn: '철회' };
const TRACKS = { master_eng: '전문기술석사 (공학)', master_sci: '전문기술석사 (자연과학)', industry_joint: '산학공동기술개발과제', convergence_etc: '기타 산학융합과제' };
const LEGACY_TRACKS = { applied: 'master_eng', industry: 'industry_joint', convergence: 'convergence_etc', education: 'convergence_etc' };
const COMMITTEE = { reviewer: '심사위원', associate_editor: '분야위원장' };
const PRESENTATIONS = { oral: '구두', poster: '포스터', demo: '시연' };
const FINAL_TYPES = { ...PRESENTATIONS, pending: '미확정' };
const BATCH_SIZE = 500;
const PAGE_SIZE = 25;
const DATE_TIME = new Intl.DateTimeFormat('ko-KR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'Asia/Seoul' });
const NUMBER = new Intl.NumberFormat('ko-KR');
const dateTime = (value) => value ? DATE_TIME.format(new Date(value)) : '';
const day = (value) => value.slice(5);
const won = (value) => value == null ? '' : NUMBER.format(value) + '원';
const count = (rows, match) => rows.filter(match).length;
const dates = (rows) => [...new Set(rows.flatMap((row) => row.attendance_days || []))].sort();
const track = (row) => LEGACY_TRACKS[row.track] || row.track;
const finalType = (row) => row.status === 'accepted' ? row.final_presentation || 'pending' : '';
const label = (map, value) => map[value] || value;
const display = (value) => escapeHtml(value == null || value === '' ? '—' : value);
const detail = (...values) => values.filter(Boolean).join(' · ');

function stage(row) {
  if (row.status === 'withdrawn') return 'withdrawn';
  if (['revision', 'accepted', 'rejected'].includes(row.status)) return 'decided';
  if (row.reviews_submitted >= 2) return 'deciding';
  return row.reviewers_assigned ? 'reviewing' : 'waiting';
}

const LISTS = {
  registrations: {
    title: '등록 현황',
    description: '참가 신청, 등록비 납부, 행사일별 참가 확정 인원을 확인합니다.',
    rpc: 'staff_list_registrations',
    search: '등록번호, 이름, 소속, 이메일',
    filters: [
      ['status', '등록 상태', REG_STATES, (row) => row.status],
      ['category', '참가 구분', { general: '일반 참가 전체', ...CATEGORIES }, (row) => row.category],
      ['payment', '납부 상태', PAYMENT, (row) => row.payment_status],
      ['day', '참가일', null, (row) => row.attendance_days || []],
    ],
    columns: [
      ['등록자', (r) => r.full_name || '이름 미입력', (r) => detail(r.registration_no, r.affiliation, r.department, r.position_title, r.email)],
      ['등록 상태', (r) => label(REG_STATES, r.status), null, (r) => r.status],
      ['참가 구분·일자', (r) => label(CATEGORIES, r.category), (r) => (r.attendance_days || []).map(day).join(', ')],
      ['납부', (r) => label(PAYMENT, r.payment_status), (r) => detail(won(r.fee_amount), METHODS[r.payment_method], dateTime(r.paid_at)), (r) => r.payment_status],
      ['체크인', (r) => dateTime(r.checked_in_at)],
      ['신청일', (r) => dateTime(r.applied_at)],
    ],
    summary(rows) {
      const active = rows.filter((r) => r.status !== 'cancelled');
      const confirmed = active.filter((r) => r.status === 'confirmed');
      const paid = active.filter((r) => r.payment_status === 'paid');
      const paidAmount = paid.reduce((sum, r) => sum + (r.fee_amount || 0), 0);
      return metrics([
        ['유효 등록', active.length, '명', `취소 ${count(rows, (r) => r.status === 'cancelled')}명`],
        ['확인 대기', count(active, (r) => r.status === 'applied'), '명', '신청 접수'],
        ['참가 확정', confirmed.length, '명', `발표자 ${count(confirmed, (r) => r.category === 'presenter')}명`],
        ['체크인', count(confirmed, (r) => r.checked_in_at), '명', '확정 인원 기준'],
      ]) + breakdowns(
        breakdown('등록비 납부', `유효 등록 기준 · 납부 확인 ${won(paidAmount)}`,
          Object.entries(PAYMENT).map(([key, text]) => [text, count(active, (r) => r.payment_status === key)]), active.length, '명'),
        breakdown('일자별 참가 확정', '양일 참가자는 각 날짜에 한 번씩 집계합니다.',
          dates(active).map((value) => [day(value), count(confirmed, (r) => r.attendance_days?.includes(value))]), confirmed.length, '명'),
      );
    },
  },
  submissions: {
    title: '논문 제출 현황',
    description: '현재 제출본의 심사 진행과 판정, 희망·확정 발표 유형을 확인합니다.',
    rpc: 'staff_list_submissions',
    search: '접수번호, 원고 제목, 제출자, 저자',
    filters: [
      ['stage', '심사 단계', STAGES, stage],
      ['status', '원고 상태', PAPER_STATES, (row) => row.status],
      ['track', '모집 분야', TRACKS, track],
      ['preferred', '희망 발표', PRESENTATIONS, (row) => row.preferred_presentation],
      ['final', '확정 발표', FINAL_TYPES, finalType],
    ],
    columns: [
      ['원고', (r) => r.title, (r) => detail(r.paper_no, label(TRACKS, track(r)))],
      ['심사 단계', (r) => STAGES[stage(r)], (r) => r.reviewers_assigned ? `의견 제출 ${r.reviews_submitted}/${r.reviewers_assigned}` : '', stage],
      ['원고 상태', (r) => label(PAPER_STATES, r.status), null, (r) => r.status],
      ['희망 발표', (r) => label(PRESENTATIONS, r.preferred_presentation)],
      ['확정 발표', (r) => label(FINAL_TYPES, finalType(r))],
      ['제출자·저자', (r) => r.submitter_name, (r) => detail(r.submitter_affiliation, r.submitter_email, r.authors)],
      ['제출일', (r) => dateTime(r.submitted_at)],
    ],
    summary(rows) {
      const active = rows.filter((r) => r.status !== 'withdrawn');
      const accepted = active.filter((r) => r.status === 'accepted');
      const byStage = (key) => count(rows, (r) => stage(r) === key);
      const byStatus = (key) => count(rows, (r) => r.status === key);
      return metrics([
        ['유효 투고', active.length, '편', `철회 ${byStage('withdrawn')}편`],
        ['심사 전', byStage('waiting'), '편', '심사위원 배정 대기'],
        ['심사 중', byStage('reviewing'), '편', '심사의견 제출 진행'],
        ['판정 대기', byStage('deciding'), '편', '심사의견 2건 이상 제출'],
        ['심사 후', byStage('decided'), '편', '수정 요청 · 채택 · 반려'],
      ]) + breakdowns(
        breakdown('판정 결과', '현재 원고 상태 기준',
          ['revision', 'accepted', 'rejected'].map((key) => [PAPER_STATES[key], byStatus(key)]), byStage('decided'), '편'),
        breakdown('희망 발표 유형', '철회를 제외한 제출 원고 기준',
          Object.entries(PRESENTATIONS).map(([key, text]) => [text, count(active, (r) => r.preferred_presentation === key)]), active.length, '편'),
        breakdown('확정 발표 유형', '채택 원고 기준',
          Object.entries(FINAL_TYPES).map(([key, text]) => [text, count(accepted, (r) => finalType(r) === key)]), accepted.length, '편'),
      );
    },
  },
  reviewers: {
    title: '심사위원',
    description: '분야별 심사위원·분야위원장과 심사 건수를 확인합니다.',
    rpc: 'staff_list_reviewers',
    search: '이름, 소속, 이메일, 분야',
    columns: [
      ['이름', (r) => r.display_name, (r) => detail(r.affiliation, r.email)],
      ['분야', (r) => label(TRACKS, track(r))],
      ['역할', (r) => label(COMMITTEE, r.committee_role)],
      ['계정', (r) => r.has_account ? '연결됨' : '미가입'],
      ['활성', (r) => r.active ? '예' : '아니오'],
      ['배정·제출·거절', (r) => `${r.assigned} · ${r.submitted} · ${r.declined}`],
    ],
  },
  session_chairs: {
    title: '좌장',
    description: '발표 세션별 좌장과 보고서 제출 여부를 확인합니다.',
    rpc: 'staff_list_session_chairs',
    search: '세션명, 좌장 이름, 소속, 이메일',
    columns: [
      ['세션', (r) => r.session_title, (r) => detail(label(PRESENTATIONS, r.session_type), r.room)],
      ['시간', (r) => dateTime(r.starts_at), (r) => r.ends_at ? `종료 ${dateTime(r.ends_at)}` : ''],
      ['좌장', (r) => r.chair_name, (r) => detail(r.chair_affiliation, r.chair_email)],
      ['발표', (r) => `${r.presentations}편`],
      ['보고서', (r) => r.report_submitted_at ? `제출 ${dateTime(r.report_submitted_at)}` : '미제출'],
      ['공개', (r) => r.is_published ? '공개' : '비공개'],
    ],
  },
};

let client;
let edition;
let current;
let rows = [];
let page = 1;
let request;

function metrics(items) {
  return `<dl class="staff-metrics">${items.map(([text, value, unit, note]) => `<div class="staff-metric">
    <dt>${text}</dt><dd>${NUMBER.format(value)}<span>${unit}</span></dd><dd class="staff-metric-note">${note}</dd>
  </div>`).join('')}</dl>`;
}

function breakdowns(...cards) {
  return `<div class="staff-breakdowns">${cards.join('')}</div>`;
}

function breakdown(title, description, items, total, unit) {
  return `<section class="staff-breakdown"><h3>${title}</h3><p>${description}</p>
    ${items.length ? `<ul>${items.map(([text, value]) => `<li><span>${escapeHtml(text)}</span><strong>${NUMBER.format(value)}${unit}</strong>
      <meter aria-hidden="true" min="0" max="${Math.max(total, 1)}" value="${value}"></meter></li>`).join('')}</ul>`
    : '<p class="staff-feedback">집계할 참가일이 없습니다.</p>'}
  </section>`;
}

function renderFilters() {
  const fields = $('#staff-filter-fields');
  const previous = new Map([...fields.querySelectorAll('select')].map((input) => [input.name, input.value]));
  fields.innerHTML = (LISTS[current].filters || []).map(([key, text, options]) => {
    const choices = options ? Object.entries(options) : dates(rows).map((value) => [value, day(value)]);
    return `<label>${text}<select name="${key}"><option value="">전체</option>${choices.map(([value, option]) =>
      `<option value="${escapeHtml(value)}">${escapeHtml(option)}</option>`).join('')}</select></label>`;
  }).join('');
  fields.querySelectorAll('select').forEach((input) => {
    const value = previous.get(input.name);
    if ([...input.options].some((option) => option.value === value)) input.value = value;
  });
}

function render() {
  const spec = LISTS[current];
  const search = $('#staff-search').value.trim().toLocaleLowerCase();
  const activeFilters = (spec.filters || []).map(([key, , , get]) =>
    [$(`#staff-filter-fields [name="${key}"]`).value, get]).filter(([value]) => value);
  const visible = rows.filter((row) => activeFilters.every(([value, get]) => {
    const actual = get(row);
    if (value === 'general') return actual !== 'presenter';
    return Array.isArray(actual) ? actual.includes(value) : value === actual;
  }) && (!search || spec.columns.some(([, main, sub]) =>
    detail(main(row), sub?.(row)).toLocaleLowerCase().includes(search))));
  const pages = Math.max(1, Math.ceil(visible.length / PAGE_SIZE));
  page = Math.min(page, pages);
  const startIndex = (page - 1) * PAGE_SIZE;
  $('#staff-head').innerHTML = `<tr>${spec.columns.map(([title]) => `<th scope="col">${title}</th>`).join('')}</tr>`;
  $('#staff-body').innerHTML = visible.slice(startIndex, startIndex + PAGE_SIZE).map((row) => `<tr>${
    spec.columns.map(([, main, sub, tone], index) => {
      const extra = sub?.(row);
      const value = tone ? `<span class="staff-status" data-state="${escapeHtml(tone(row))}">${display(main(row))}</span>` : display(main(row));
      const cell = `${value}${extra ? `<span class="staff-cell-detail">${escapeHtml(extra)}</span>` : ''}`;
      return index === 0 ? `<th scope="row">${cell}</th>` : `<td>${cell}</td>`;
    }).join('')
  }</tr>`).join('') || `<tr><td colspan="${spec.columns.length}">${rows.length ? '검색 조건에 맞는 항목이 없습니다.' : '아직 등록된 항목이 없습니다.'}</td></tr>`;
  $('#staff-count').textContent = visible.length
    ? `전체 ${rows.length}건 중 ${visible.length}건 일치 · ${startIndex + 1}–${Math.min(startIndex + PAGE_SIZE, visible.length)}건 표시`
    : `전체 ${rows.length}건 중 0건 일치`;
  $('#staff-pagination').hidden = pages === 1;
  $('#staff-page').textContent = `${page} / ${pages}`;
  $('#staff-prev').disabled = page === 1;
  $('#staff-next').disabled = page === pages;
  $('#staff-table-wrap').scrollTop = 0;
}

async function load(list, refresh = false) {
  if (!refresh && list === current) return;
  request?.abort();
  const controller = new AbortController();
  request = controller;
  current = list;
  const spec = LISTS[list];
  const feedback = $('#staff-loading');
  if (!refresh) {
    $('#staff-search').value = '';
    $('#staff-filter-fields').replaceChildren();
  }
  rows = [];
  page = 1;
  $('#staff-body').replaceChildren();
  $('#staff-summary').replaceChildren();
  $('#staff-results').hidden = true;
  $('#staff-updated').textContent = '';
  $('#staff-refresh').disabled = true;
  document.querySelectorAll('[data-list]').forEach((link) => {
    if (link.dataset.list === list) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  });
  $('#staff-list-title').textContent = spec.title;
  $('#staff-list-description').textContent = spec.description;
  $('#staff-search').placeholder = spec.search;
  feedback.textContent = '현황을 불러오는 중입니다.';
  feedback.classList.remove('error');
  try {
    const data = [];
    for (let offset = 0; ; offset += BATCH_SIZE) {
      const batch = requireData(await client.rpc(spec.rpc, { p_year: edition.year })
        .range(offset, offset + BATCH_SIZE - 1).abortSignal(controller.signal)) || [];
      data.push(...batch);
      if (batch.length < BATCH_SIZE) break;
    }
    if (controller.signal.aborted) return;
    rows = data;
    renderFilters();
    $('#staff-summary').innerHTML = spec.summary?.(rows) || '';
    render();
    $('#staff-results').hidden = false;
    $('#staff-updated').textContent = `갱신 ${dateTime(new Date())} KST`;
    feedback.textContent = '';
  } catch (error) {
    if (controller.signal.aborted) return;
    feedback.classList.add('error');
    feedback.textContent = error.message === 'Staff list access required'
      ? '현재 회차의 열람 권한이 없습니다. 위원장에게 권한을 확인해 주세요.'
      : '현황을 불러오지 못했습니다. 새로고침을 눌러 다시 시도해 주세요.';
  } finally {
    if (request === controller) $('#staff-refresh').disabled = false;
  }
}

function openSelectedList() {
  const list = location.hash.slice(1);
  if (Object.hasOwn(LISTS, list)) return load(list);
  if (!list || !current) return load('registrations');
}

$('#staff-refresh').addEventListener('click', () => load(current, true));
function applyFilters() {
  page = 1;
  render();
}
$('#staff-search').addEventListener('input', applyFilters);
$('#staff-filter-fields').addEventListener('change', applyFilters);
$('#staff-reset').addEventListener('click', () => {
  $('#staff-search').value = '';
  $('#staff-filter-fields').querySelectorAll('select').forEach((input) => { input.selectedIndex = 0; });
  applyFilters();
  $('#staff-search').focus();
});
$('#staff-prev').addEventListener('click', () => { page -= 1; render(); });
$('#staff-next').addEventListener('click', () => { page += 1; render(); });
$('#staff-table-wrap').addEventListener('keydown', (event) => {
  const table = event.currentTarget;
  if (event.target !== table || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
  if (table.scrollWidth <= table.clientWidth || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
  event.preventDefault();
  table.scrollBy(event.key === 'ArrowRight' ? 40 : -40, 0);
});

async function start() {
  const message = $('#staff-message');
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
    const user = auth.data?.user;
    if (!user) {
      message.textContent = '운영 현황을 보려면 운영진 계정으로 로그인해 주세요.';
      $('#staff-login').hidden = false;
      return;
    }

    client.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT' || (event === 'SIGNED_IN' && session?.user?.id !== user.id)) {
        request?.abort();
        rows = [];
        $('#staff-body').replaceChildren();
        $('#staff-workspace').hidden = true;
        $('#staff-access-card').hidden = true;
        location.reload();
      }
    });

    edition = await currentEdition(client);
    const access = requireData(await client.rpc('staff_my_access', { p_year: edition.year }))?.[0];
    if (!access) {
      message.textContent = '현재 회차의 열람 권한이 없습니다. 위원장에게 운영진 권한을 요청해 주세요.';
      return;
    }
    $('#staff-edition-label').textContent = `CO-R&BD ${edition.year}`;
    $('#staff-access').textContent = ROLES[access.staff_role] || access.staff_role;
    $('#staff-access-period').textContent = access.expires_at ? `열람 기한 · ${dateTime(access.expires_at)} KST` : '현재 회차 열람 권한';
    $('#staff-access-card').hidden = false;
    $('#staff-operations').hidden = access.staff_role !== 'chair';
    if (access.staff_role === 'chair') {
      const { data } = await client.from('staff_roles').select('is_super_admin').eq('user_id', user.id).maybeSingle();
      $('#staff-admin-monitor').hidden = !data?.is_super_admin;
    }
    message.hidden = true;
    $('#staff-workspace').hidden = false;
    window.addEventListener('hashchange', openSelectedList);
    await openSelectedList();
  } catch {
    message.textContent = '권한을 확인하지 못했습니다. 페이지를 새로고침해 주세요.';
    message.classList.add('error');
  }
}

start();
