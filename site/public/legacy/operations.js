import { conferenceClient, currentEdition, editionDateRange, escapeHtml, kstTime, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const CATEGORIES = { student: '학생·졸업생', faculty: '교원·연구자', industry: '기업·기관', other: '기타' };
const STATES = { applied: '확인 대기', confirmed: '참가 확정', cancelled: '취소됨' };
let client;
let speakers = [];
let sessions = [];
let links = [];
let sessionChairs = [];
let sessionPresentations = [];
let chairApplications = [];
let edition;

function notice(text, error = false) {
  $('#operations-message').textContent = text;
  $('#operations-message').classList.toggle('error', error);
}

function toInput(value) {
  if (!value) return '';
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(value));
  const part = (name) => parts.find((item) => item.type === name).value;
  return `${part('year')}-${part('month')}-${part('day')}T${part('hour')}:${part('minute')}`;
}

function toUtc(value) {
  return value ? new Date(`${value}:00+09:00`).toISOString() : null;
}

async function loadRegistrations() {
  const settings = requireData(await client.from('conference_settings')
    .select('registration_open,registration_deadline').eq('edition_year', edition.year).single());
  $('#registration-open').checked = settings.registration_open;
  $('#registration-deadline').value = toInput(settings.registration_deadline);
  $('#registration-deadline-note').textContent = settings.registration_deadline
    ? `현재 마감: ${new Intl.DateTimeFormat('ko-KR', { dateStyle: 'long', timeStyle: 'short', timeZone: 'Asia/Seoul' }).format(new Date(settings.registration_deadline))} KST.`
    : '신청을 열기 전에 마감 시각을 입력해 주세요.';
  const rows = requireData(await client.from('attendee_registrations')
    .select('id,user_id,category,attendance_days,status,checked_in_at,created_at')
    .eq('edition_year', edition.year).order('created_at', { ascending: false }));
  const users = rows.map((row) => row.user_id);
  const profiles = users.length
    ? requireData(await client.from('profiles').select('user_id,full_name,affiliation,email').in('user_id', users))
    : [];
  const profileMap = new Map(profiles.map((person) => [person.user_id, person]));
  $('#registration-list').innerHTML = rows.length ? rows.map((row) => {
    const person = profileMap.get(row.user_id) || {};
    const actions = row.status === 'applied'
      ? `<button type="button" class="operations-button" data-registration="${row.id}" data-action="confirm">참가 확정</button>`
      : row.status === 'confirmed' && !row.checked_in_at
        ? `<button type="button" class="operations-button" data-registration="${row.id}" data-action="checkin">현장 체크인</button>`
        : '';
    return `<article class="operations-item"><h3>${escapeHtml(person.full_name || '이름 미입력')}</h3>
      <p>${escapeHtml(person.affiliation || '소속 미입력')} · ${escapeHtml(person.email || '')}</p>
      <p>${escapeHtml(CATEGORIES[row.category])} · ${escapeHtml(row.attendance_days.join(', '))}</p>
      <span class="operations-meta">${escapeHtml(STATES[row.status])}${row.checked_in_at ? ' · 체크인 완료' : ''}</span>
      <div class="operations-actions">${actions}
      ${row.status !== 'cancelled' && !row.checked_in_at ? `<button type="button" class="operations-button secondary" data-registration="${row.id}" data-action="cancel">신청 취소</button>` : ''}</div>
    </article>`;
  }).join('') : '<p class="operations-empty">접수된 참가 신청이 없습니다.</p>';
}

async function loadProgram() {
  speakers = requireData(await client.from('program_speakers')
    .select('id,full_name,affiliation,bio,is_published')
    .eq('edition_year', edition.year).order('full_name'));
  sessions = requireData(await client.from('program_sessions')
    .select('id,title,session_type,starts_at,ends_at,room,description,moderator,is_published')
    .eq('edition_year', edition.year).order('starts_at', { nullsFirst: false }));
  links = sessions.length
    ? requireData(await client.from('program_session_speakers')
      .select('session_id,speaker_id,sort_order').in('session_id', sessions.map((row) => row.id)))
    : [];
  $('#speaker-list').innerHTML = speakers.length ? speakers.map((row) => `<article class="operations-item">
    <h3>${escapeHtml(row.full_name)}</h3><p>${escapeHtml(row.affiliation)}</p>
    <span class="operations-meta">${row.is_published ? '공개' : '초안'}</span>
    <div class="operations-actions"><button type="button" class="operations-button secondary" data-edit-speaker="${row.id}">수정</button>
    <button type="button" class="operations-button secondary" data-delete-speaker="${row.id}">삭제</button></div></article>`).join('')
    : '<p class="operations-empty">등록된 연사가 없습니다.</p>';
  $('#session-speakers').innerHTML = speakers.length ? speakers.map((row) =>
    `<label><input type="checkbox" value="${row.id}" /> ${escapeHtml(row.full_name)}${row.is_published ? '' : ' (비공개)'}</label>`).join('')
    : '<p>먼저 연사를 등록해 주세요.</p>';
  $('#session-list').innerHTML = sessions.length ? sessions.map((row) => `<article class="operations-item">
    <h3>${escapeHtml(row.title)}</h3>
    <p>${row.starts_at ? `${escapeHtml(toInput(row.starts_at).replace('T', ' '))}–${escapeHtml(kstTime(row.ends_at))}` : '시간 미정'} · ${escapeHtml(row.room || '장소 미정')}</p>
    <span class="operations-meta">${row.is_published ? '공개' : '초안'}</span>
    <div class="operations-actions"><button type="button" class="operations-button secondary" data-edit-session="${row.id}">수정</button>
    <button type="button" class="operations-button secondary" data-delete-session="${row.id}">삭제</button></div></article>`).join('')
    : '<p class="operations-empty">등록된 세션이 없습니다.</p>';
}

async function loadSessionChairs() {
  const eligible = sessions.filter((row) => ['oral', 'poster'].includes(row.session_type));
  if (!eligible.length) {
    sessionChairs = [];
    sessionPresentations = [];
    $('#session-chair-list').innerHTML = '<p class="operations-empty">구두·포스터 세션을 먼저 만드세요.</p>';
    return;
  }
  const ids = eligible.map((row) => row.id);
  sessionChairs = requireData(await client.from('session_chairs')
    .select('session_id,user_id,report_note,report_submitted_at').in('session_id', ids));
  sessionPresentations = requireData(await client.from('session_presentations')
    .select('id,session_id,paper_id,paper_title,presenter_name,attendance,award_recommended,chair_note')
    .in('session_id', ids).order('created_at'));
  const accepted = requireData(await client.from('papers')
    .select('id,title,final_presentation').eq('edition_year', edition.year).eq('status', 'accepted').order('title'));
  const userIds = [...new Set(sessionChairs.map((row) => row.user_id))];
  const profiles = userIds.length ? requireData(await client.from('profiles')
    .select('user_id,full_name,email').in('user_id', userIds)) : [];
  const people = new Map(profiles.map((row) => [row.user_id, row]));
  const scheduled = new Set(sessionPresentations.map((row) => row.paper_id));
  $('#session-chair-list').innerHTML = eligible.map((session) => {
    const assignment = sessionChairs.find((row) => row.session_id === session.id);
    const person = assignment && people.get(assignment.user_id);
    const items = sessionPresentations.filter((row) => row.session_id === session.id);
    const available = accepted.filter((paper) => paper.final_presentation === session.session_type && !scheduled.has(paper.id));
    return `<article class="operations-item"><h3>${escapeHtml(session.title)}</h3>
      <p>${escapeHtml(session.session_type === 'oral' ? '구두발표' : '포스터')} · ${escapeHtml(session.room || '장소 미정')}</p>
      <p>좌장 계정: ${escapeHtml(person ? `${person.full_name || '이름 미입력'} (${person.email})` : '미배정')}
      ${assignment?.report_submitted_at ? ' · 보고서 제출 완료' : assignment ? ' · 보고 대기' : ''}</p>
      <form class="session-chair-assign" data-session="${session.id}"><label>좌장 계정 이메일
        <input type="email" name="email" list="approved-chair-options" required value="${escapeHtml(person?.email || '')}" placeholder="선정된 지원자 이메일" /></label>
        <div class="operations-actions"><button class="operations-button" type="submit" ${assignment?.report_submitted_at ? 'disabled' : ''}>좌장 배정·교체</button>
        ${assignment ? `<button class="operations-button secondary" type="button" data-remove-chair="${session.id}" ${assignment.report_submitted_at ? 'disabled' : ''}>배정 해제</button>` : ''}
        ${assignment?.report_submitted_at ? `<button class="operations-button secondary" type="button" data-reopen-report="${session.id}">보고서 재개</button>` : ''}</div></form>
      <p class="operations-meta">발표 ${items.length}편${assignment?.report_submitted_at ? ` · 좌장 메모: ${escapeHtml(assignment.report_note || '없음')}` : ''}</p>
      <div class="operations-list">${items.map((row) => `<div class="operations-item"><strong>${escapeHtml(row.paper_title)}</strong>
        <p>발표자 ${escapeHtml(row.presenter_name)} · ${escapeHtml({ pending: '확인 전', presented: '발표', absent: '불참' }[row.attendance])}${row.award_recommended ? ' · 우수발표 후보 추천' : ''}</p>
        ${row.chair_note ? `<p>좌장 메모: ${escapeHtml(row.chair_note)}</p>` : ''}
        <button type="button" class="operations-button secondary" data-remove-presentation="${row.id}" ${assignment?.report_submitted_at ? 'disabled' : ''}>발표 배정 해제</button></div>`).join('') || '<p class="operations-empty">배정된 발표가 없습니다.</p>'}</div>
      <form class="session-presentation-add" data-session="${session.id}"><div class="operations-form-grid">
        <label>채택 원고 <select name="paper_id" required><option value="">선택하세요</option>${available.map((paper) =>
          `<option value="${paper.id}">${escapeHtml(paper.title)}</option>`).join('')}</select></label>
        <label>실제 발표자 이름 <input name="presenter_name" maxlength="120" required /></label></div>
        <button class="operations-button secondary" type="submit" ${available.length && !assignment?.report_submitted_at ? '' : 'disabled'}>발표 배정</button></form>
    </article>`;
  }).join('');
}

async function refreshSessionChairs() {
  try {
    await loadSessionChairs();
  } catch (error) {
    if (error.code !== 'PGRST205' && error.code !== '42P01'
      && !/could not find the table|relation .* does not exist/i.test(error.message)) throw error;
    $('#session-chair-list').innerHTML = '<p class="operations-empty">좌장 운영 DB 변경이 아직 적용되지 않았습니다. 기존 참가·프로그램 관리는 계속 이용할 수 있습니다.</p>';
  }
}

async function loadChairApplications() {
  const settings = requireData(await client.from('conference_settings')
    .select('chair_applications_open,chair_application_deadline,chair_application_notice')
    .eq('edition_year', edition.year).single());
  $('#chair-applications-open').checked = settings.chair_applications_open;
  $('#chair-application-deadline').value = toInput(settings.chair_application_deadline);
  $('#chair-application-notice').value = settings.chair_application_notice;
  chairApplications = requireData(await client.from('session_chair_applications')
    .select('id,user_id,preferred_types,available_days,status,submitted_at,withdrawal_requested_at')
    .eq('edition_year', edition.year).order('submitted_at', { ascending: false }));
  const ids = chairApplications.map((row) => row.user_id);
  const applicationIds = chairApplications.map((row) => row.id);
  const profiles = ids.length ? requireData(await client.from('profiles')
    .select('user_id,full_name,affiliation,email,expertise_tracks').in('user_id', ids)) : [];
  const reviews = applicationIds.length ? requireData(await client.from('session_chair_application_reviews')
    .select('application_id,note').in('application_id', applicationIds)) : [];
  const people = new Map(profiles.map((row) => [row.user_id, row]));
  const notes = new Map(reviews.map((row) => [row.application_id, row.note]));
  const labels = { submitted: '검토 전', approved: '선정', declined: '미선정', withdrawn: '철회' };
  const types = { oral: '구두', poster: '포스터' };
  $('#approved-chair-options').innerHTML = chairApplications.filter((row) =>
    row.status === 'approved' && !row.withdrawal_requested_at && people.get(row.user_id)?.email)
    .map((row) => `<option value="${escapeHtml(people.get(row.user_id).email)}"></option>`).join('');
  $('#chair-application-list').innerHTML = chairApplications.length ? chairApplications.map((row) => {
    const person = people.get(row.user_id) || {};
    const assigned = sessionChairs.some((item) => item.user_id === row.user_id);
    const decisions = row.status === 'submitted' ?
      '<button class="operations-button" type="button" data-chair-decision="approved">선정</button><button class="operations-button secondary" type="button" data-chair-decision="declined">미선정</button>'
      : row.status === 'approved' && !assigned ?
        '<button class="operations-button secondary" type="button" data-chair-decision="submitted">선정 취소</button>'
        : row.status === 'declined' ? '<button class="operations-button secondary" type="button" data-chair-decision="submitted">재검토</button>' : '';
    const closeRequest = row.status === 'approved' && row.withdrawal_requested_at && !assigned
      ? '<button class="operations-button secondary" type="button" data-chair-decision="withdrawn">해제 요청 처리·철회</button>' : '';
    return `<article class="operations-item" data-application="${row.id}"><h3>${escapeHtml(person.full_name || '이름 미입력')}</h3>
      <p>${escapeHtml(person.affiliation || '소속 미입력')} · ${escapeHtml(person.email || '')}</p>
      <p>전문 분야: ${escapeHtml((person.expertise_tracks || []).join(', '))} · 희망: ${escapeHtml(row.preferred_types.map((type) => types[type] || type).join(', '))}</p>
      <p>참여 가능: ${escapeHtml(row.available_days.join(', '))}</p>
      <p class="operations-meta">${escapeHtml(labels[row.status] || row.status)}${assigned ? ' · 세션 배정됨' : ''}${row.withdrawal_requested_at ? ' · 배정 해제 요청' : ''}</p>
      <form class="chair-application-review"><label>내부 검토 메모 (지원자에게 비공개)
        <textarea name="note" maxlength="1000">${escapeHtml(notes.get(row.id) || '')}</textarea></label>
        <div class="operations-actions"><button class="operations-button secondary" type="submit">메모 저장</button>${decisions}${closeRequest}</div></form></article>`;
  }).join('') : '<p class="operations-empty">접수된 좌장 지원이 없습니다.</p>';
}

async function refreshChairApplications() {
  try { await loadChairApplications(); }
  catch (error) {
    if (error.code !== 'PGRST205' && error.code !== '42703' && error.code !== '42P01'
      && !/could not find the table|column .* does not exist|relation .* does not exist/i.test(error.message)) throw error;
    $('#chair-application-settings-form').hidden = true;
    $('#chair-application-list').innerHTML = '<p class="operations-empty">좌장 모집 DB 변경이 아직 적용되지 않았습니다.</p>';
  }
}

async function loadEditions() {
  const rows = requireData(await client.from('conference_editions')
    .select('year,title,start_date,end_date,venue,summary,proceedings_url,status,archive_published')
    .order('year', { ascending: false }));
  $('#edition-list').innerHTML = rows.map((row) => `<article class="operations-item">
    <h3>${escapeHtml(row.title)} <span class="operations-meta">${row.status === 'current' ? '현재' : row.status === 'archived' ? '지난 학회' : '준비 중'}</span></h3>
    <p>${escapeHtml(editionDateRange(row))} · ${escapeHtml(row.venue || '장소 미정')}</p>
    <form class="edition-form" data-edition="${row.year}">
      <label>학회명 <input name="title" required maxlength="160" value="${escapeHtml(row.title)}" ${row.status === 'archived' ? 'disabled' : ''} /></label>
      <div class="operations-form-grid">
        <label>시작일 <input name="start_date" type="date" value="${row.start_date || ''}" ${row.status === 'archived' ? 'disabled' : ''} /></label>
        <label>종료일 <input name="end_date" type="date" value="${row.end_date || ''}" ${row.status === 'archived' ? 'disabled' : ''} /></label>
      </div>
      <label>장소 <input name="venue" maxlength="240" value="${escapeHtml(row.venue)}" ${row.status === 'archived' ? 'disabled' : ''} /></label>
      <label>공개 소개 <textarea name="summary" maxlength="2000">${escapeHtml(row.summary)}</textarea></label>
      <label>승인된 자료집 URL (선택) <input name="proceedings_url" type="url" pattern="https://.*" maxlength="500" value="${escapeHtml(row.proceedings_url || '')}" /></label>
      ${row.status === 'archived' ? `<label class="inline-check"><input name="archive_published" type="checkbox" ${row.archive_published ? 'checked' : ''} /> 아카이브 공개</label>` : ''}
      <div class="operations-actions"><button type="submit" class="operations-button secondary">정보 저장</button>
      ${row.status === 'draft' ? `<button type="button" class="operations-button" data-activate="${row.year}">현재 학회로 전환</button>` : ''}
      ${row.status === 'archived' && row.archive_published ? `<a class="operations-button secondary" href="./edition.html?year=${row.year}">공개 화면</a>` : ''}
      </div>
    </form></article>`).join('');
}

function clearSpeaker() {
  $('#speaker-form').reset();
  $('#speaker-id').value = '';
}

function clearSession() {
  $('#session-form').reset();
  $('#session-id').value = '';
}

$('#registration-settings-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const deadline = toUtc($('#registration-deadline').value);
    if ($('#registration-open').checked && !deadline) throw new Error('참가 신청 마감 시각을 입력해 주세요.');
    requireData(await client.from('conference_settings')
      .update({ registration_open: $('#registration-open').checked, registration_deadline: deadline })
      .eq('edition_year', edition.year));
    await loadRegistrations();
    notice($('#registration-open').checked ? '일반 참가 신청을 열었습니다.' : '일반 참가 신청을 닫았습니다.');
  } catch (error) { notice(error.message, true); }
});

$('#chair-application-settings-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = event.submitter;
  button.disabled = true;
  try {
    const open = $('#chair-applications-open').checked;
    const deadline = toUtc($('#chair-application-deadline').value);
    const recruitmentNotice = $('#chair-application-notice').value.trim();
    if (open && (!deadline || new Date(deadline) <= new Date() || recruitmentNotice.length < 20)) {
      throw new Error('모집을 열려면 미래 마감 시각과 확정된 모집 안내를 입력해 주세요.');
    }
    requireData(await client.from('conference_settings').update({
      chair_applications_open: open, chair_application_deadline: deadline,
      chair_application_notice: recruitmentNotice,
    }).eq('edition_year', edition.year));
    await refreshChairApplications();
    notice(open ? '좌장 지원 접수를 열었습니다.' : '좌장 지원 접수를 닫았습니다.');
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
});

$('#chair-application-list').addEventListener('submit', async (event) => {
  const form = event.target.closest('.chair-application-review');
  if (!form) return;
  event.preventDefault();
  const applicationId = form.closest('[data-application]').dataset.application;
  const button = event.submitter;
  button.disabled = true;
  try {
    requireData(await client.from('session_chair_application_reviews').upsert({
      application_id: applicationId, note: form.elements.note.value.trim(),
    }, { onConflict: 'application_id' }).select('application_id').single());
    await refreshChairApplications();
    notice('비공개 검토 메모를 저장했습니다.');
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

$('#chair-application-list').addEventListener('click', async (event) => {
  const button = event.target.closest('[data-chair-decision]');
  if (!button) return;
  const applicationId = button.closest('[data-application]').dataset.application;
  const decision = button.dataset.chairDecision;
  button.disabled = true;
  try {
    requireData(await client.from('session_chair_applications')
      .update({ status: decision }).eq('id', applicationId).select('id').single());
    await refreshChairApplications();
    notice({ approved: '지원자를 선정했습니다. 세션 배정은 별도로 진행해 주세요.', declined: '미선정으로 기록했습니다.',
      submitted: '재검토 상태로 돌렸습니다.', withdrawn: '해제 요청을 처리했습니다.' }[decision]);
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

$('#registration-list').addEventListener('click', async (event) => {
  const button = event.target.closest('[data-registration]');
  if (!button) return;
  const { registration: id, action } = button.dataset;
  if (action === 'cancel' && !window.confirm('이 참가 신청을 취소할까요?')) return;
  button.disabled = true;
  try {
    const change = action === 'checkin' ? { checked_in_at: new Date().toISOString() }
      : { status: action === 'confirm' ? 'confirmed' : 'cancelled' };
    requireData(await client.from('attendee_registrations').update(change).eq('id', id));
    await loadRegistrations();
    notice(action === 'confirm' ? '참가를 확정했습니다.' : action === 'checkin' ? '현장 체크인을 기록했습니다.' : '신청을 취소했습니다.');
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

$('#speaker-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = $('#speaker-form button[type="submit"]');
  button.disabled = true;
  try {
    const values = {
      full_name: $('#speaker-name').value.trim(), affiliation: $('#speaker-affiliation').value.trim(),
      bio: $('#speaker-bio').value.trim(), is_published: $('#speaker-published').checked,
    };
    const id = $('#speaker-id').value;
    if (id) requireData(await client.from('program_speakers').update(values).eq('id', id));
    else requireData(await client.from('program_speakers').insert({ ...values, edition_year: edition.year }));
    clearSpeaker();
    await loadProgram();
    notice('연사 정보를 저장했습니다.');
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
});

$('#session-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = $('#session-form button[type="submit"]');
  button.disabled = true;
  try {
    const selected = [...document.querySelectorAll('#session-speakers input:checked')].map((input) => input.value);
    const published = $('#session-published').checked;
    if (published && selected.some((id) => !speakers.find((row) => row.id === id)?.is_published)) {
      throw new Error('공개 세션의 연사는 먼저 공개 상태로 저장해 주세요.');
    }
    const values = {
      title: $('#session-title').value.trim(), session_type: $('#session-type').value,
      room: $('#session-room').value.trim(), starts_at: toUtc($('#session-start').value),
      ends_at: toUtc($('#session-end').value), description: $('#session-description').value.trim(),
      moderator: $('#session-moderator').value.trim(), is_published: published,
    };
    if (published && (!values.starts_at || !values.ends_at || !values.room)) {
      throw new Error('공개 세션은 시작·종료 시각과 장소가 필요합니다.');
    }
    const existingId = $('#session-id').value;
    const saved = existingId
      ? requireData(await client.from('program_sessions').update(values).eq('id', existingId).select('id').single())
      : requireData(await client.from('program_sessions').insert({ ...values, edition_year: edition.year }).select('id').single());
    requireData(await client.from('program_session_speakers').delete().eq('session_id', saved.id));
    if (selected.length) requireData(await client.from('program_session_speakers').insert(
      selected.map((speakerId, index) => ({ session_id: saved.id, speaker_id: speakerId, sort_order: index + 1 }))
    ));
    clearSession();
    await loadProgram();
    await refreshSessionChairs();
    notice('세션을 저장했습니다. 공개 설정은 프로그램 페이지에 바로 반영됩니다.');
  } catch (error) { notice(error.message, true); }
  finally { button.disabled = false; }
});

$('#speaker-clear').addEventListener('click', clearSpeaker);
$('#session-clear').addEventListener('click', clearSession);

$('#create-edition-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const year = Number($('#new-edition-year').value);
  try {
    requireData(await client.rpc('create_conference_edition', { p_year: year }));
    $('#new-edition-year').value = '';
    await loadEditions();
    notice(`${year}년 학회 초안을 만들었습니다. 날짜와 장소가 확정되면 입력해 주세요.`);
  } catch (error) { notice(error.message, true); }
});

$('#edition-list').addEventListener('submit', async (event) => {
  const form = event.target.closest('.edition-form');
  if (!form) return;
  event.preventDefault();
  const values = {
    summary: form.elements.summary.value.trim(),
    proceedings_url: form.elements.proceedings_url.value.trim() || null,
  };
  if (!form.elements.title.disabled) values.title = form.elements.title.value.trim();
  if (!form.elements.start_date.disabled) {
    values.start_date = form.elements.start_date.value || null;
    values.end_date = form.elements.end_date.value || null;
    values.venue = form.elements.venue.value.trim();
  }
  if (form.elements.archive_published) values.archive_published = form.elements.archive_published.checked;
  try {
    requireData(await client.from('conference_editions').update(values).eq('year', Number(form.dataset.edition)));
    await loadEditions();
    notice('학회 정보를 저장했습니다.');
  } catch (error) { notice(error.message, true); }
});

$('#edition-list').addEventListener('click', async (event) => {
  const button = event.target.closest('[data-activate]');
  if (!button) return;
  const year = Number(button.dataset.activate);
  if (!window.confirm(`${year}년 학회를 현재 회차로 전환할까요? 기존 회차의 투고·심사·참가 신청은 닫히고 지난 학회로 이동합니다.`)) return;
  button.disabled = true;
  try {
    requireData(await client.rpc('activate_conference_edition', { p_year: year }));
    location.reload();
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

$('#speaker-list').addEventListener('click', async (event) => {
  const edit = event.target.closest('[data-edit-speaker]');
  const remove = event.target.closest('[data-delete-speaker]');
  if (edit) {
    const row = speakers.find((item) => item.id === edit.dataset.editSpeaker);
    $('#speaker-id').value = row.id;
    $('#speaker-name').value = row.full_name;
    $('#speaker-affiliation').value = row.affiliation;
    $('#speaker-bio').value = row.bio;
    $('#speaker-published').checked = row.is_published;
    $('#speaker-form').scrollIntoView({ behavior: 'smooth' });
  }
  if (remove && window.confirm('연사를 삭제하면 세션과의 연결도 제거됩니다. 삭제할까요?')) {
    try {
      requireData(await client.from('program_speakers').delete().eq('id', remove.dataset.deleteSpeaker));
      await loadProgram(); notice('연사를 삭제했습니다.');
    } catch (error) { notice(error.message, true); }
  }
});

$('#session-list').addEventListener('click', async (event) => {
  const edit = event.target.closest('[data-edit-session]');
  const remove = event.target.closest('[data-delete-session]');
  if (edit) {
    const row = sessions.find((item) => item.id === edit.dataset.editSession);
    $('#session-id').value = row.id;
    $('#session-title').value = row.title;
    $('#session-type').value = row.session_type;
    $('#session-room').value = row.room;
    $('#session-start').value = toInput(row.starts_at);
    $('#session-end').value = toInput(row.ends_at);
    $('#session-description').value = row.description;
    $('#session-moderator').value = row.moderator;
    $('#session-published').checked = row.is_published;
    const linked = new Set(links.filter((link) => link.session_id === row.id).map((link) => link.speaker_id));
    document.querySelectorAll('#session-speakers input').forEach((input) => { input.checked = linked.has(input.value); });
    $('#session-form').scrollIntoView({ behavior: 'smooth' });
  }
  if (remove && window.confirm('세션을 삭제할까요? 공개 프로그램에서도 사라집니다.')) {
    try {
      requireData(await client.from('program_sessions').delete().eq('id', remove.dataset.deleteSession));
      await loadProgram(); await refreshSessionChairs(); notice('세션을 삭제했습니다.');
    } catch (error) { notice(error.message, true); }
  }
});

$('#session-chair-list').addEventListener('submit', async (event) => {
  const assign = event.target.closest('.session-chair-assign');
  const add = event.target.closest('.session-presentation-add');
  if (!assign && !add) return;
  event.preventDefault();
  const form = assign || add;
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    if (assign) {
      const email = assign.elements.email.value.trim();
      const profile = requireData(await client.from('profiles').select('user_id').eq('email', email).maybeSingle());
      if (!profile) throw new Error('가입된 계정을 찾을 수 없습니다. 좌장이 먼저 로그인했는지 확인해 주세요.');
      const existing = sessionChairs.find((row) => row.session_id === assign.dataset.session);
      if (existing?.user_id !== profile.user_id) {
        const application = chairApplications.find((row) => row.user_id === profile.user_id
          && row.status === 'approved' && !row.withdrawal_requested_at);
        const session = sessions.find((row) => row.id === assign.dataset.session);
        if (!application) throw new Error('이 계정은 선정된 좌장 지원자가 아닙니다. 지원 내역을 먼저 확인해 주세요.');
        if (!session?.starts_at || !application.preferred_types.includes(session.session_type)
          || !application.available_days.includes(toInput(session.starts_at).slice(0, 10))) {
          throw new Error('지원자의 희망 발표 형태와 참여 가능 날짜가 세션 일정과 맞지 않습니다.');
        }
      }
      if (existing) requireData(await client.from('session_chairs').update({ user_id: profile.user_id })
        .eq('session_id', assign.dataset.session).select('session_id').single());
      else requireData(await client.from('session_chairs').insert({
        session_id: assign.dataset.session, user_id: profile.user_id,
      }).select('session_id').single());
      notice('좌장 계정을 배정했습니다. 공개용 좌장 표기는 세션 편집에서 별도로 확인해 주세요.');
    } else {
      requireData(await client.from('session_presentations').insert({
        session_id: add.dataset.session,
        paper_id: add.elements.paper_id.value,
        presenter_name: add.elements.presenter_name.value.trim(),
      }).select('id').single());
      notice('발표를 세션에 배정했습니다.');
    }
    await refreshSessionChairs();
    await refreshChairApplications();
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

$('#session-chair-list').addEventListener('click', async (event) => {
  const removeChair = event.target.closest('[data-remove-chair]');
  const removePresentation = event.target.closest('[data-remove-presentation]');
  const reopen = event.target.closest('[data-reopen-report]');
  const button = removeChair || removePresentation || reopen;
  if (!button) return;
  if ((removeChair || removePresentation) && !window.confirm('이 배정을 해제할까요? 기존 좌장 기록도 함께 삭제됩니다.')) return;
  button.disabled = true;
  try {
    if (removeChair) requireData(await client.from('session_chairs').delete()
      .eq('session_id', removeChair.dataset.removeChair));
    else if (removePresentation) requireData(await client.from('session_presentations').delete()
      .eq('id', removePresentation.dataset.removePresentation));
    else requireData(await client.from('session_chairs').update({ report_submitted_at: null })
      .eq('session_id', reopen.dataset.reopenReport).select('session_id').single());
    await refreshSessionChairs();
    await refreshChairApplications();
    notice(reopen ? '좌장 보고서를 다시 열었습니다.' : '배정을 해제했습니다.');
  } catch (error) { notice(error.message, true); button.disabled = false; }
});

async function start() {
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
    const user = auth.data?.user;
    if (!user) throw new Error('위원장 계정으로 로그인해 주세요. 상단의 투고·심사 관리에서 로그인할 수 있습니다.');
    const role = requireData(await client.from('staff_roles').select('role,is_super_admin').eq('user_id', user.id).maybeSingle());
    if (role?.role !== 'chair') throw new Error('위원장 계정만 이 화면을 이용할 수 있습니다.');
    $('#operations-monitor-link').hidden = !role.is_super_admin;
    edition = await currentEdition(client);
    $('#operations-edition-label').textContent = `CO-R&BD ${edition.year} / CHAIR DESK`;
    $('#operations-intro').textContent = `${edition.title} 운영 화면입니다. 참가 신청, 프로그램 공개와 연도별 학회 기록을 관리합니다.`;
    document.title = `참가·프로그램 관리 | ${edition.title}`;
    if (edition.start_date && edition.end_date) {
      $('#session-start').min = `${edition.start_date}T00:00`;
      $('#session-start').max = `${edition.end_date}T23:59`;
      $('#session-end').min = `${edition.start_date}T00:00`;
      $('#session-end').max = `${edition.end_date}T23:59`;
    }
    await Promise.all([loadRegistrations(), loadProgram(), loadEditions()]);
    await refreshSessionChairs();
    await refreshChairApplications();
    $('#operations-workspace').hidden = false;
    notice('운영 데이터를 불러왔습니다. 공개 설정을 변경하면 사이트에 바로 반영됩니다.');
  } catch (error) { notice(error.message, true); }
}
start();
