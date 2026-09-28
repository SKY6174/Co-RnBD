import { conferenceClient, currentEdition, escapeHtml, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const STATES = { submitted: '접수 완료 · 선정 검토 전', approved: '선정 완료 · 세션 배정 대기', declined: '이번 회차 미선정', withdrawn: '지원 철회' };
let client;
let edition;
let user;
let settings;
let application;
let assigned = false;

function notice(text, error = false) {
  $('#application-message').textContent = text;
  $('#application-message').classList.toggle('error', error);
}

function conferenceDays(start, end) {
  const first = new Date(`${start}T00:00:00Z`);
  const last = new Date(`${end}T00:00:00Z`);
  if (Number.isNaN(first.valueOf()) || Number.isNaN(last.valueOf())) return [];
  const days = [];
  for (let day = first; day <= last && days.length < 31; day = new Date(day.valueOf() + 86400000)) {
    days.push(day.toISOString().slice(0, 10));
  }
  return days;
}

async function loadApplication() {
  settings = requireData(await client.from('conference_settings')
    .select('chair_applications_open,chair_application_deadline,chair_application_notice')
    .eq('edition_year', edition.year).single());
  application = requireData(await client.from('session_chair_applications')
    .select('id,preferred_types,available_days,status,submitted_at,withdrawal_requested_at')
    .eq('edition_year', edition.year).eq('user_id', user.id).maybeSingle());
  const profile = requireData(await client.from('profiles')
    .select('full_name,affiliation,expertise_tracks').eq('user_id', user.id).single());
  const assignments = requireData(await client.from('session_chairs')
    .select('session_id').eq('user_id', user.id));
  assigned = assignments.length > 0;
  const open = settings.chair_applications_open && settings.chair_application_deadline
    && new Date(settings.chair_application_deadline) > new Date();
  const complete = profile.full_name?.trim() && profile.affiliation?.trim() && profile.expertise_tracks?.length;
  const days = conferenceDays(edition.start_date, edition.end_date);
  $('#application-profile').textContent = `계정 정보: ${profile.full_name || '이름 미입력'} · ${profile.affiliation || '소속 미입력'} · 전문 분야 ${profile.expertise_tracks?.length || 0}개`;
  $('#application-notice').textContent = open ? settings.chair_application_notice : '좌장 모집은 아직 열리지 않았거나 마감됐습니다. 확정된 모집 안내가 게시되면 지원할 수 있습니다.';
  $('#application-status').textContent = application
    ? `${STATES[application.status] || application.status}${assigned ? ' · 세션 배정 완료' : ''}${application.withdrawal_requested_at ? ' · 배정 해제 요청 접수' : ''}`
    : '이번 회차 지원 내역이 없습니다.';
  $('#application-days').innerHTML = days.map((day) => `<label class="inline-check"><input type="checkbox" name="available_day" value="${day}" ${application?.available_days.includes(day) ? 'checked' : ''} /> ${escapeHtml(day)}</label>`).join('');
  for (const field of $('#application-form').querySelectorAll('[name="presentation_type"]')) {
    field.checked = application?.preferred_types.includes(field.value) || false;
  }
  const editable = open && complete && days.length > 0 && (!application || ['submitted', 'withdrawn'].includes(application.status));
  $('#application-form').hidden = !editable;
  $('#application-form').querySelector('button[type="submit"]').textContent = application?.status === 'submitted' ? '지원 내용 저장' : '좌장 지원 접수';
  const withdraw = $('#application-withdraw');
  withdraw.hidden = !application || application.status === 'withdrawn' || application.status === 'declined'
    || (assigned && Boolean(application.withdrawal_requested_at));
  withdraw.textContent = assigned ? '배정 해제 요청' : '지원 철회';
  $('#application-workspace').hidden = false;
  notice(!complete ? '지원 전 투고·심사 화면의 내 정보에서 이름·소속·전문 분야를 입력해 주세요.'
    : open ? '좌장 지원 상태를 확인했습니다.' : '현재 좌장 지원을 접수하지 않습니다.');
}

$('#application-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const preferredTypes = [...$('#application-form').querySelectorAll('[name="presentation_type"]:checked')]
    .map((field) => field.value);
  const availableDays = [...$('#application-form').querySelectorAll('[name="available_day"]:checked')]
    .map((field) => field.value);
  if (!preferredTypes.length || !availableDays.length) {
    notice('희망 발표 형태와 현장 참여 가능한 날짜를 각각 하나 이상 선택해 주세요.', true);
    return;
  }
  const button = event.submitter;
  button.disabled = true;
  try {
    const values = { preferred_types: preferredTypes, available_days: availableDays };
    if (application) requireData(await client.from('session_chair_applications')
      .update({ ...values, status: 'submitted' }).eq('id', application.id).select('id').single());
    else requireData(await client.from('session_chair_applications')
      .insert({ ...values, edition_year: edition.year, user_id: user.id }).select('id').single());
    await loadApplication();
    notice('좌장 지원을 접수했습니다. 선정 결과는 이 화면에서 확인할 수 있습니다.');
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
});

$('#application-withdraw').addEventListener('click', async () => {
  if (!application || !window.confirm(assigned ? '위원장에게 세션 배정 해제를 요청할까요?' : '좌장 지원을 철회할까요?')) return;
  const button = $('#application-withdraw');
  button.disabled = true;
  try {
    requireData(await client.from('session_chair_applications').update(assigned
      ? { withdrawal_requested_at: new Date().toISOString() } : { status: 'withdrawn' })
      .eq('id', application.id).select('id').single());
    await loadApplication();
    notice(assigned ? '배정 해제 요청을 접수했습니다. 위원장이 세션 운영 영향을 확인합니다.' : '지원을 철회했습니다.');
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

async function start() {
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
    user = auth.data?.user;
    if (!user) throw new Error('먼저 투고·심사 화면에서 로그인해 주세요.');
    edition = await currentEdition(client);
    $('#application-edition').textContent = `CO-R&BD ${edition.year} / CHAIR APPLICATION`;
    document.title = `세션 좌장 지원 | ${edition.title}`;
    await loadApplication();
  } catch (error) {
    notice(error.code === 'PGRST205' || /could not find the table|column .* does not exist/i.test(error.message)
      ? '좌장 지원 기능을 준비 중입니다.' : error.message, true);
  }
}

start();
