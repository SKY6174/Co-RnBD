import { conferenceClient, escapeHtml, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const DAYS = { '2026-12-17': '12월 17일', '2026-12-18': '12월 18일' };
const STATES = { applied: '확인 대기', confirmed: '참가 확정', cancelled: '취소됨' };
const CATEGORIES = { student: '학생·졸업생', faculty: '교원·연구자', industry: '기업·기관', other: '기타' };
let client;
let user;
let registration;
let open = false;

function notice(text, error = false) {
  $('#registration-message').textContent = text;
  $('#registration-message').classList.toggle('error', error);
}

async function load() {
  const settings = requireData(await client.from('conference_settings')
    .select('registration_open,registration_deadline').single());
  open = settings.registration_open && Date.now() <= new Date(settings.registration_deadline).getTime();
  const auth = await client.auth.getUser();
  if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
  user = auth.data?.user;
  $('#registration-login').hidden = Boolean(user);
  if (!user) {
    $('#registration-account').textContent = '참가 신청에는 계정 로그인이 필요합니다.';
    notice(open ? '신청을 받는 중입니다. 로그인 후 참가 날짜를 선택해 주세요.' : '참가 신청은 현재 열려 있지 않습니다.');
    return;
  }
  const profile = requireData(await client.from('profiles')
    .select('full_name,affiliation,email').eq('user_id', user.id).single());
  const complete = Boolean(profile.full_name?.trim() && profile.affiliation?.trim());
  $('#registration-account').innerHTML = complete
    ? `<strong>${escapeHtml(profile.full_name)}</strong> · ${escapeHtml(profile.affiliation)}<br><small>${escapeHtml(profile.email || user.email)}</small>`
    : '이름과 소속기관을 입력해야 참가 신청을 할 수 있습니다. <a href="./submission.html">내 정보 입력하기 →</a>';
  registration = requireData(await client.from('attendee_registrations')
    .select('id,category,attendance_days,status,checked_in_at,created_at').eq('user_id', user.id).maybeSingle());
  const current = $('#registration-current');
  current.hidden = !registration;
  if (registration) {
    const days = registration.attendance_days.map((day) => DAYS[day] || day).join(' · ');
    current.innerHTML = `<div class="operations-note"><strong>${escapeHtml(STATES[registration.status])}</strong><br>${escapeHtml(days)} · ${escapeHtml(CATEGORIES[registration.category])}</div>`
      + (registration.status !== 'cancelled' && !registration.checked_in_at
        ? '<div class="operations-actions"><button id="cancel-registration" type="button" class="operations-button secondary">신청 취소</button></div>' : '');
    $('#cancel-registration')?.addEventListener('click', cancelRegistration);
    $('#registration-category').value = registration.category;
    document.querySelectorAll('[name="attendance-day"]').forEach((input) => {
      input.checked = registration.attendance_days.includes(input.value);
    });
  }
  $('#registration-form').hidden = !open || !complete || (registration && registration.status === 'confirmed');
  $('#registration-form button[type="submit"]').textContent = registration?.status === 'cancelled' ? '다시 신청' : registration ? '신청 내용 변경' : '참가 신청 제출';
  notice(!open ? '참가 신청은 현재 열려 있지 않습니다. 기존 신청 상태는 아래에서 확인할 수 있습니다.'
    : !complete ? '이름과 소속기관을 먼저 입력해 주세요.'
      : registration?.status === 'confirmed' ? '참가가 확정되었습니다.'
        : registration?.status === 'applied' ? '신청이 접수되었습니다. 위원장 확인을 기다려 주세요.'
          : '참가 날짜와 구분을 선택해 신청해 주세요.');
}

async function cancelRegistration() {
  if (!window.confirm('참가 신청을 취소할까요?')) return;
  try {
    requireData(await client.from('attendee_registrations').update({ status: 'cancelled' }).eq('id', registration.id));
    await load();
  } catch (error) { notice(error.message, true); }
}

$('#registration-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const days = [...document.querySelectorAll('[name="attendance-day"]:checked')].map((input) => input.value);
  if (!days.length) { notice('참가 날짜를 한 개 이상 선택해 주세요.', true); return; }
  const button = $('#registration-form button[type="submit"]');
  button.disabled = true;
  try {
    const values = { category: $('#registration-category').value, attendance_days: days, status: 'applied' };
    if (registration) {
      requireData(await client.from('attendee_registrations').update(values).eq('id', registration.id));
    } else {
      requireData(await client.from('attendee_registrations').insert({ ...values, user_id: user.id }));
    }
    await load();
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
});

async function start() {
  try {
    client = await conferenceClient();
    await load();
    client.auth.onAuthStateChange(() => setTimeout(() => load().catch((error) => notice(error.message, true)), 0));
  } catch (error) {
    const preparing = ['PGRST204', 'PGRST205', '42703'].includes(error.code)
      || /could not find (the table|the .*column)/i.test(error.message);
    $('#registration-account').textContent = preparing ? '참가 신청 시스템을 준비 중입니다.' : '신청 정보를 불러오지 못했습니다.';
    notice(preparing ? '참가 신청은 운영 준비 후 시작됩니다.' : '신청 정보를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.', !preparing);
  }
}
start();
