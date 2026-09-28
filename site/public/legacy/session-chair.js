import { conferenceClient, currentEdition, escapeHtml, kstTime, requireData } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const ATTENDANCE = { pending: '확인 전', presented: '발표', absent: '불참' };
let client;
let edition;
let user;

function notice(text, error = false) {
  $('#session-chair-message').textContent = text;
  $('#session-chair-message').classList.toggle('error', error);
}

async function loadAssignments() {
  const assignments = requireData(await client.from('session_chairs')
    .select('session_id,report_note,report_submitted_at').eq('user_id', user.id));
  if (!assignments.length) {
    $('#session-chair-list').innerHTML = '<p class="operations-empty">현재 배정된 구두·포스터 세션이 없습니다. 배정은 위원장이 진행합니다.</p>';
    $('#session-chair-list').hidden = false;
    notice('좌장 배정 내역이 없습니다.');
    return;
  }
  const ids = assignments.map((row) => row.session_id);
  const sessions = requireData(await client.from('program_sessions')
    .select('id,title,session_type,starts_at,ends_at,room,edition_year')
    .in('id', ids).eq('edition_year', edition.year).order('starts_at'));
  const presentations = requireData(await client.from('session_presentations')
    .select('id,session_id,paper_title,presenter_name,attendance,award_recommended,chair_note')
    .in('session_id', ids).order('created_at'));
  $('#session-chair-list').innerHTML = sessions.map((session) => {
    const assignment = assignments.find((row) => row.session_id === session.id);
    const rows = presentations.filter((row) => row.session_id === session.id);
    const submitted = Boolean(assignment.report_submitted_at);
    const disabled = submitted ? 'disabled' : '';
    return `<section class="operations-card" aria-label="${escapeHtml(session.title)}">
      <h2>${escapeHtml(session.title)}</h2>
      <p>${escapeHtml(session.session_type === 'oral' ? '구두발표' : '포스터')} · ${escapeHtml(session.room || '장소 미정')}
      ${session.starts_at && session.ends_at ? ` · ${escapeHtml(kstTime(session.starts_at))}–${escapeHtml(kstTime(session.ends_at))}` : ''}</p>
      <p class="operations-meta">${submitted ? '좌장 보고서 제출 완료' : '발표 여부를 모두 확인한 뒤 보고서를 제출하세요.'}</p>
      <div class="operations-list">${rows.map((row) => `<form class="operations-item session-chair-presentation" data-presentation="${row.id}">
        <h3>${escapeHtml(row.paper_title)}</h3><p>발표자: ${escapeHtml(row.presenter_name)}</p>
        <label>발표 여부 <select name="attendance" ${disabled}>
          ${Object.entries(ATTENDANCE).map(([value, label]) => `<option value="${value}" ${row.attendance === value ? 'selected' : ''}>${label}</option>`).join('')}
        </select></label>
        <label class="inline-check"><input type="checkbox" name="award_recommended" ${row.award_recommended ? 'checked' : ''} ${disabled} /> 우수발표 후보 추천</label>
        <label>진행 메모 (선택) <textarea name="chair_note" maxlength="500" ${disabled}>${escapeHtml(row.chair_note)}</textarea></label>
        <button class="operations-button secondary" type="submit" ${disabled}>이 발표 기록 저장</button>
      </form>`).join('') || '<p class="operations-empty">배정된 발표가 없습니다. 위원장에게 발표 목록 배정을 요청해 주세요.</p>'}</div>
      <form class="session-chair-report" data-session="${session.id}">
        <label>세션 보고 메모 (선택) <textarea name="report_note" maxlength="1000" ${disabled}>${escapeHtml(assignment.report_note)}</textarea></label>
        <p class="operations-meta">우수발표 후보를 추천하지 않아도 보고서를 제출할 수 있습니다. 제출 후 수정이 필요하면 위원장에게 재개를 요청하세요.</p>
        <button class="operations-button" type="submit" ${disabled || !rows.length ? 'disabled' : ''}>좌장 보고서 제출</button>
      </form>
    </section>`;
  }).join('') || '<p class="operations-empty">현재 회차에 배정된 세션이 없습니다.</p>';
  $('#session-chair-list').hidden = false;
  notice('담당 세션을 불러왔습니다. 기록은 발표별로 저장한 뒤 보고서를 제출하세요.');
}

$('#session-chair-list').addEventListener('submit', async (event) => {
  const presentation = event.target.closest('.session-chair-presentation');
  const report = event.target.closest('.session-chair-report');
  if (!presentation && !report) return;
  event.preventDefault();
  const form = presentation || report;
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    if (presentation) {
      const attendance = form.elements.attendance.value;
      const awardRecommended = form.elements.award_recommended.checked;
      if (attendance !== 'presented' && awardRecommended) {
        throw new Error('발표한 논문만 우수발표 후보로 추천할 수 있습니다.');
      }
      requireData(await client.from('session_presentations').update({
        attendance,
        award_recommended: awardRecommended,
        chair_note: form.elements.chair_note.value.trim(),
      }).eq('id', presentation.dataset.presentation).select('id').single());
      notice('발표 기록을 저장했습니다.');
    } else {
      if ([...report.closest('section').querySelectorAll('.session-chair-presentation select[name="attendance"]')]
        .some((select) => select.value === 'pending')) {
        throw new Error('모든 발표의 출석 여부를 저장한 뒤 보고서를 제출해 주세요.');
      }
      requireData(await client.from('session_chairs').update({
        report_note: form.elements.report_note.value.trim(),
        report_submitted_at: new Date().toISOString(),
      }).eq('session_id', report.dataset.session).eq('user_id', user.id).select('session_id').single());
      await loadAssignments();
      notice('좌장 보고서를 제출했습니다. 위원장이 제출 결과를 확인할 수 있습니다.');
    }
  } catch (error) {
    notice(error.message === 'Record every presentation before submitting the report'
      ? '모든 발표의 출석 여부를 저장한 뒤 보고서를 제출해 주세요.' : error.message, true);
    button.disabled = false;
  } finally { if (presentation) button.disabled = false; }
});

async function start() {
  try {
    client = await conferenceClient();
    const auth = await client.auth.getUser();
    if (auth.error && !/Auth session missing/i.test(auth.error.message)) throw auth.error;
    user = auth.data?.user;
    if (!user) throw new Error('먼저 투고·심사 화면에서 로그인해 주세요.');
    edition = await currentEdition(client);
    $('#session-chair-edition').textContent = `CO-R&BD ${edition.year} / SESSION CHAIR`;
    document.title = `세션 좌장 업무 | ${edition.title}`;
    await loadAssignments();
  } catch (error) { notice(error.message, true); }
}

start();
