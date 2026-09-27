import { conferenceClient, currentEdition, escapeHtml, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const REGISTRATION_STATES = { applied: '확인 대기', confirmed: '참가 확정', cancelled: '취소됨' };
const PAPER_STATES = { draft: '초안', submitted: '접수', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려' };
const CATEGORIES = { student: '학생·졸업생', faculty: '교원·연구자', industry: '기업·기관', other: '기타' };
const TRACKS = { applied: '전문기술석사 응용연구', industry: '산학공동기술개발 성과', convergence: '산업융합기술', education: '전문기술석사 교육·운영' };
const PAGE_SIZE = 500;
let client;
let edition;
let registrations = [];
let papers = [];

function notice(value, error = false) {
  $('#monitor-message').textContent = value;
  $('#monitor-message').classList.toggle('error', error);
}

function dateTime(value) {
  return value ? new Intl.DateTimeFormat('ko-KR', {
    dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Seoul',
  }).format(new Date(value)) : '기록 없음';
}

async function allRows(table, columns, year) {
  const rows = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const page = requireData(await client.from(table).select(columns)
      .eq('edition_year', year).order('created_at', { ascending: false })
      .range(offset, offset + PAGE_SIZE - 1));
    rows.push(...page);
    if (page.length < PAGE_SIZE) return rows;
  }
}

async function registrationProfiles(rows) {
  const ids = [...new Set(rows.map((row) => row.user_id))];
  const profiles = [];
  for (let offset = 0; offset < ids.length; offset += 200) {
    profiles.push(...requireData(await client.from('profiles')
      .select('user_id,full_name,affiliation,email').in('user_id', ids.slice(offset, offset + 200))));
  }
  return new Map(profiles.map((profile) => [profile.user_id, profile]));
}

function stat(label, value) {
  return `<div class="monitor-stat"><strong>${value}</strong><span>${label}</span></div>`;
}

function renderRegistrations() {
  const search = $('#monitor-registration-search').value.trim().toLocaleLowerCase();
  const status = $('#monitor-registration-status').value;
  const category = $('#monitor-registration-category').value;
  const day = $('#monitor-registration-day').value;
  const visible = registrations.filter((row) => {
    const person = row.person;
    const matches = [person.full_name, person.affiliation, person.email]
      .some((value) => String(value || '').toLocaleLowerCase().includes(search));
    return matches && (status === 'all' || row.status === status)
      && (category === 'all' || row.category === category)
      && (day === 'all' || row.attendance_days?.includes(day));
  });
  const count = (key) => registrations.filter((row) => row.status === key).length;
  const days = [...new Set(registrations.flatMap((row) => row.attendance_days || []))].sort();
  $('#monitor-registration-stats').innerHTML = [
    stat('전체 신청', registrations.length), stat('확인 대기', count('applied')),
    stat('참가 확정', count('confirmed')),
    stat('체크인', registrations.filter((row) => row.checked_in_at).length),
    stat('취소', count('cancelled')),
    ...days.map((value) => stat(`${value.slice(5)} 참가 예정`, registrations.filter((row) => row.status === 'confirmed' && row.attendance_days?.includes(value)).length)),
  ].join('');
  $('#monitor-registration-count').textContent = `${visible.length}건 표시 / 전체 ${registrations.length}건`;
  $('#monitor-registration-list').innerHTML = visible.length ? visible.map((row) => `<article class="operations-item">
    <h3>${escapeHtml(row.person.full_name || '이름 미입력')} <span class="operations-meta">${escapeHtml(REGISTRATION_STATES[row.status] || row.status)}</span></h3>
    <p>${escapeHtml(row.person.affiliation || '소속 미입력')} · ${escapeHtml(row.person.email || '이메일 미입력')}</p>
    <p>${escapeHtml(CATEGORIES[row.category] || row.category)} · ${escapeHtml((row.attendance_days || []).join(', '))}</p>
    <p class="operations-meta">신청 ${escapeHtml(dateTime(row.created_at))}${row.checked_in_at ? ` · 체크인 ${escapeHtml(dateTime(row.checked_in_at))}` : ''}</p>
  </article>`).join('') : '<p class="operations-empty">조건에 맞는 참가 신청이 없습니다.</p>';
}

function renderPapers() {
  const search = $('#monitor-paper-search').value.trim().toLocaleLowerCase();
  const status = $('#monitor-paper-status').value;
  const track = $('#monitor-paper-track').value;
  const visible = papers.filter((row) => [row.title, row.contact_name, row.contact_email]
    .some((value) => String(value || '').toLocaleLowerCase().includes(search))
    && (status === 'all' || row.status === status)
    && (track === 'all' || row.track === track));
  const count = (key) => papers.filter((row) => row.status === key).length;
  $('#monitor-paper-stats').innerHTML = [
    stat('전체 원고', papers.length), stat('초안', count('draft')),
    stat('제출된 원고', papers.length - count('draft')),
    stat('접수·심사 중', count('submitted') + count('under_review')),
    stat('수정 요청', count('revision')), stat('채택', count('accepted')),
    stat('반려', count('rejected')),
  ].join('');
  $('#monitor-paper-count').textContent = `${visible.length}건 표시 / 전체 ${papers.length}건`;
  $('#monitor-paper-list').innerHTML = visible.length ? visible.map((row) => `<article class="operations-item">
    <h3>${escapeHtml(row.title)} <span class="operations-meta">${escapeHtml(PAPER_STATES[row.status] || row.status)}</span></h3>
    <p>${escapeHtml(TRACKS[row.track] || row.track)} · 접수번호 ${escapeHtml(row.id.slice(0, 8).toUpperCase())}</p>
    <p>연락 담당자 ${escapeHtml(row.contact_name || '미입력')} · ${escapeHtml(row.contact_email || '이메일 미입력')}</p>
    <p class="operations-meta">작성 ${escapeHtml(dateTime(row.created_at))} · 제출 ${escapeHtml(dateTime(row.submitted_at))}</p>
  </article>`).join('') : '<p class="operations-empty">조건에 맞는 논문이 없습니다.</p>';
}

async function refresh() {
  const button = $('#monitor-refresh');
  button.disabled = true;
  notice('현황을 불러오는 중입니다.');
  try {
    const [applicationRows, paperRows] = await Promise.all([
      allRows('attendee_registrations', 'user_id,category,attendance_days,status,checked_in_at,created_at', edition.year),
      allRows('papers', 'id,title,track,status,contact_name,contact_email,created_at,submitted_at', edition.year),
    ]);
    const profiles = await registrationProfiles(applicationRows);
    registrations = applicationRows.map((row) => ({ ...row, person: profiles.get(row.user_id) || {} }));
    papers = paperRows;
    const dayFilter = $('#monitor-registration-day');
    const selectedDay = dayFilter.value;
    const days = [...new Set(registrations.flatMap((row) => row.attendance_days || []))].sort();
    dayFilter.innerHTML = '<option value="all">전체</option>' + days.map((day) => `<option value="${escapeHtml(day)}">${escapeHtml(day.slice(5))}</option>`).join('');
    dayFilter.value = days.includes(selectedDay) ? selectedDay : 'all';
    renderRegistrations();
    renderPapers();
    $('#monitor-updated').textContent = `갱신: ${dateTime(new Date())}`;
    notice('현재 회차의 신청·투고 현황을 불러왔습니다.');
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
}

$('#monitor-refresh').addEventListener('click', refresh);
$('#monitor-registration-search').addEventListener('input', renderRegistrations);
$('#monitor-registration-status').addEventListener('change', renderRegistrations);
$('#monitor-registration-category').addEventListener('change', renderRegistrations);
$('#monitor-registration-day').addEventListener('change', renderRegistrations);
$('#monitor-paper-search').addEventListener('input', renderPapers);
$('#monitor-paper-status').addEventListener('change', renderPapers);
$('#monitor-paper-track').addEventListener('change', renderPapers);

async function start() {
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
    if (!auth.data?.user) throw new Error('슈퍼 관리자 계정으로 로그인해 주세요. 투고·심사 화면에서 로그인할 수 있습니다.');
    const role = requireData(await client.from('staff_roles').select('role,is_super_admin')
      .eq('user_id', auth.data.user.id).maybeSingle());
    if (role?.role !== 'chair' || !role.is_super_admin) throw new Error('슈퍼 관리자 계정만 현황을 볼 수 있습니다.');
    edition = await currentEdition(client);
    $('#monitor-edition-label').textContent = `CO-R&BD ${edition.year} / SUPER ADMIN`;
    $('#monitor-intro').textContent = `${edition.title}의 참가신청과 논문투고를 모니터링합니다.`;
    document.title = `참가·투고 현황 | ${edition.title}`;
    $('#monitor-workspace').hidden = false;
    await refresh();
  } catch (error) { notice(error.message, true); }
}

start();
