import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/+esm';

const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const TRACKS = { applied: '전문기술석사 응용연구', industry: '산학공동기술개발 성과', convergence: '산업융합기술', education: '전문기술석사 교육·운영' };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const STATUSES = { draft: '초안', submitted: '제출 완료', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려', declined: '배정 거절' };
const RECOMMENDATIONS = { accept: '채택 권고', revise: '수정 권고', reject: '반려 권고' };
const REVIEW_STATES = { assigned: '심사 대기', draft: '임시저장', submitted: '심사 제출', declined: '배정 거절' };
let client;
let user;
let profile;
let isChair = false;
let submissionsOpen = false;
let reviewsOpen = false;
let finalUploadsOpen = false;
let settings;
let myPapers = [];
let reviewRows = [];
let chairPapers = [];
let selectedChairReviews = [];
let isRecovery = new URLSearchParams(location.hash.slice(1)).get('type') === 'recovery'
  || new URLSearchParams(location.search).get('type') === 'recovery';

function message(text, error = false) {
  const target = $('#message');
  target.textContent = text;
  target.classList.toggle('error', error);
  target.hidden = !text;
  if (text) target.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function check(result) {
  if (result.error) throw result.error;
  return result.data;
}

function hasCompleteProfile() {
  return Boolean(profile?.full_name?.trim() && profile?.affiliation?.trim());
}

function parseKeywords(value, forSubmission = false) {
  const words = value.split(',').map((word) => word.trim()).filter(Boolean);
  const unique = new Set(words.map((word) => word.toLocaleLowerCase()));
  if (words.length > 5 || unique.size !== words.length || words.some((word) => word.length > 50)) {
    throw new Error('키워드는 중복 없이 50자 이하로 최대 5개 입력해 주세요.');
  }
  if (forSubmission && words.length === 1) throw new Error('키워드를 입력할 경우 2~5개 적어 주세요. 비워두어도 제출할 수 있습니다.');
  return words;
}

function showTab(name) {
  document.querySelectorAll('[data-tab]').forEach((button) => {
    const active = button.dataset.tab === name;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });
  document.querySelectorAll('.tab-panel').forEach((panel) => { panel.hidden = panel.id !== `tab-${name}`; });
  message('');
}

function beforeDeadline(value) {
  return !value || Date.now() <= new Date(value).getTime();
}

function formatKst(value) {
  if (!value) return '마감 시각 미설정';
  return `${new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))} KST`;
}

function kstInputValue(value) {
  if (!value) return '';
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(value));
  const get = (type) => parts.find((part) => part.type === type).value;
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}`;
}

function deadlineValue(selector) {
  const value = $(selector).value;
  return value ? new Date(`${value}:00+09:00`).toISOString() : null;
}

function phaseCard(title, configured, deadline) {
  const open = configured && beforeDeadline(deadline);
  const status = open ? '진행 중' : configured && deadline ? '마감' : '닫힘';
  return `<article><strong>${title}</strong><span class="${open ? 'phase-open' : 'phase-closed'}">${status}</span><br><span>${esc(formatKst(deadline))}</span></article>`;
}

async function loadSettings() {
  settings = check(await client.from('conference_settings').select('submissions_open,submission_deadline,reviews_open,review_deadline,final_uploads_open,final_deadline,notice').single());
  submissionsOpen = settings.submissions_open && beforeDeadline(settings.submission_deadline);
  reviewsOpen = settings.reviews_open && beforeDeadline(settings.review_deadline);
  finalUploadsOpen = settings.final_uploads_open && beforeDeadline(settings.final_deadline);
  $('#notice').textContent = settings.submissions_open && !submissionsOpen
    ? '투고 접수 기간이 종료되었습니다.'
    : settings.notice || (submissionsOpen ? '투고 접수 중입니다.' : '투고 접수 준비 중입니다.');
  $('#phase-overview').innerHTML = phaseCard('원고 접수', settings.submissions_open, settings.submission_deadline)
    + phaseCard('심사 입력', settings.reviews_open, settings.review_deadline)
    + phaseCard('최종본 제출', settings.final_uploads_open, settings.final_deadline);
  $('#new-paper').disabled = !submissionsOpen;
  $('#phase-submissions').checked = settings.submissions_open;
  $('#phase-reviews').checked = settings.reviews_open;
  $('#phase-final').checked = settings.final_uploads_open;
  $('#phase-submission-deadline').value = kstInputValue(settings.submission_deadline);
  $('#phase-review-deadline').value = kstInputValue(settings.review_deadline);
  $('#phase-final-deadline').value = kstInputValue(settings.final_deadline);
}

async function loadAuthAvailability(config) {
  let settings = {};
  try {
    const response = await fetch(`${config.url}/auth/v1/settings`, {
      headers: { apikey: config.publishableKey }, cache: 'no-store',
    });
    if (response.ok) settings = await response.json();
  } catch { /* Leave providers disabled; the rest of the portal can still load. */ }
  const googleReady = settings.external?.google === true;
  const naverReady = config.naverEnabled === true;
  $('[data-login="google"]').disabled = !googleReady;
  $('[data-login="custom:naver"]').disabled = !naverReady;
  $('#auth-availability').textContent = googleReady || naverReady
    ? '이메일 로그인과 연결된 소셜 계정을 이용할 수 있습니다.'
    : '소셜 로그인은 연동 준비 중입니다. 이메일로 가입하거나 로그인할 수 있습니다.';
}

async function loadWorkspace() {
  const sessionResult = await client.auth.getSession();
  let session = sessionResult.data?.session;
  if (sessionResult.error) {
    if (!/Auth session missing/i.test(sessionResult.error.message)) throw sessionResult.error;
    await client.auth.signOut({ scope: 'local' });
    message('로그인 세션이 만료되었습니다. 다시 로그인해 주세요.');
    session = null;
  }
  let current = null;
  if (session) {
    const result = await client.auth.getUser();
    if (result.error) {
      if (!/Auth session missing/i.test(result.error.message)) throw result.error;
      await client.auth.signOut({ scope: 'local' });
      message('로그인 세션이 만료되었습니다. 다시 로그인해 주세요.');
    } else current = result.data.user;
  }
  user = current;
  $('#recovery-panel').hidden = !isRecovery;
  $('#auth-panel').hidden = Boolean(user) || isRecovery;
  $('#workspace').hidden = !user || isRecovery;
  if (!user || isRecovery) return;
  profile = check(await client.from('profiles').select('*').eq('user_id', user.id).single());
  const role = check(await client.from('staff_roles').select('role').eq('user_id', user.id).maybeSingle());
  isChair = role?.role === 'chair';
  $('#welcome').textContent = `${profile.full_name || '회원'}님의 작업 공간`;
  $('#account-email').textContent = profile.email || user.email || '이메일 정보 없음';
  $('#profile-name').value = profile.full_name || '';
  $('#profile-affiliation').value = profile.affiliation || '';
  $('#profile-department').value = profile.department || '';
  $('#profile-position').value = profile.position_title || '';
  $('#profile-orcid').value = profile.orcid || '';
  $('#profile-email').value = profile.email || user.email || '';
  $('#profile-listing-consent').checked = Boolean(profile.committee_listing_consent);
  document.querySelectorAll('[name="expertise-track"]').forEach((input) => {
    input.checked = (profile.expertise_tracks || []).includes(input.value);
  });
  $('[data-tab="chair"]').hidden = !isChair;
  await Promise.all([loadMyPapers(), loadReviews(), isChair ? loadChairPapers() : Promise.resolve()]);
}

function paperCard(paper, action, label) {
  const submitted = paper.submitted_at ? new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium' }).format(new Date(paper.submitted_at)) : '아직 제출하지 않음';
  const detail = paper.status === 'declined' ? '원고 열람 권한이 종료됐습니다.' : `${TRACKS[paper.track] || '분야 미지정'} · ${submitted}`;
  return `<article class="paper-card"><div class="paper-card-top"><span class="status status-${esc(paper.status)}">${STATUSES[paper.status] || esc(paper.status)}</span><span class="paper-id">${esc(paper.id.slice(0, 8).toUpperCase())}</span></div><h3>${esc(paper.title)}</h3><p>${esc(detail)}</p><button type="button" class="card-action" data-action="${action}" data-id="${esc(paper.id)}">${label} <span aria-hidden="true">↗</span></button></article>`;
}

async function loadMyPapers() {
  myPapers = check(await client.from('papers').select('*').eq('owner_id', user.id).order('created_at', { ascending: false }));
  $('#my-papers').innerHTML = myPapers.length ? myPapers.map((paper) => paperCard(paper, 'author', paper.status === 'draft' || paper.status === 'revision' ? '수정·제출' : '원고 보기')).join('') : '<p class="empty-state">아직 작성한 원고가 없습니다. 접수가 시작되면 새 원고를 작성할 수 있습니다.</p>';
}

async function loadReviews() {
  reviewRows = check(await client.from('reviews').select('id,paper_id,review_state,recommendation,comments,conflict_confirmed,submitted_at,decline_reason,papers(id,title,abstract,track,status,owner_id,submitted_at)').eq('reviewer_id', user.id).order('assigned_at', { ascending: false }));
  $('[data-tab="reviewer"]').hidden = reviewRows.length === 0;
  $('#review-list').innerHTML = reviewRows.length ? reviewRows.map((review) => {
    const paper = review.papers || { id: review.paper_id, title: '배정 거절 내역', status: 'declined' };
    const label = review.review_state === 'declined' ? '거절 사유 확인' : review.review_state === 'submitted' ? '심사 확인·수정' : '심사 입력';
    return paperCard(paper, 'review', label);
  }).join('') : '<p class="empty-state">배정된 원고가 없습니다.</p>';
}

async function loadChairPapers() {
  chairPapers = check(await client.from('papers').select('*').neq('status', 'draft').order('created_at', { ascending: false }));
  const count = (statuses) => chairPapers.filter((paper) => statuses.includes(paper.status)).length;
  $('#chair-summary').innerHTML = `<span>전체 ${chairPapers.length}</span><span>심사 대기·진행 ${count(['submitted', 'under_review'])}</span><span>수정 요청 ${count(['revision'])}</span><span>채택 ${count(['accepted'])}</span><span>반려 ${count(['rejected'])}</span>`;
  $('#chair-list').innerHTML = chairPapers.length ? chairPapers.map((paper) => paperCard(paper, 'chair', '배정·판정')).join('') : '<p class="empty-state">접수된 원고가 없습니다.</p>';
}

function parseAuthors(text) {
  const authors = text.split('\n').map((line) => line.trim()).filter(Boolean).map((line, index) => {
    const [full_name, affiliation, email = ''] = line.split('|').map((part) => part.trim());
    if (!full_name || !affiliation || (email && !EMAIL_RE.test(email))) throw new Error(`${index + 1}번째 저자 정보를 확인해 주세요.`);
    return { sort_order: index + 1, full_name, affiliation, email: email || null };
  });
  if (authors.length < 1 || authors.length > 30) throw new Error('저자는 1~30명 입력해 주세요.');
  return authors;
}

async function uploadFile(paperId, file, fileStage = 'submission') {
  if (!file) return;
  if (file.type !== 'application/pdf' || !file.name.toLowerCase().endsWith('.pdf') || file.size > 20 * 1024 * 1024) throw new Error('20 MB 이하 PDF 파일만 업로드할 수 있습니다.');
  const oldFiles = check(await client.from('paper_files').select('version').eq('paper_id', paperId).order('version', { ascending: false }).limit(1));
  const version = (oldFiles[0]?.version || 0) + 1;
  const path = `${user.id}/${paperId}/${crypto.randomUUID()}.pdf`;
  check(await client.storage.from('paper-pdfs').upload(path, file, { contentType: 'application/pdf', upsert: false }));
  try {
    check(await client.from('paper_files').insert({ paper_id: paperId, storage_path: path, original_name: file.name, version, file_stage: fileStage, uploaded_by: user.id }));
  } catch (error) {
    await client.storage.from('paper-pdfs').remove([path]);
    throw error;
  }
}

async function openAuthor(paperId = '') {
  $('#paper-form').reset();
  $('#final-form').reset();
  $('#final-form').hidden = true;
  $('#paper-id').value = paperId;
  $('#paper-form-title').textContent = paperId ? '원고 수정·확인' : '새 원고';
  $('#paper-form').hidden = false;
  $('#paper-receipt').hidden = true;
  const editable = !paperId || ['draft', 'revision'].includes(myPapers.find((paper) => paper.id === paperId)?.status);
  if (paperId) {
    const paper = myPapers.find((item) => item.id === paperId);
    $('#paper-title').value = paper.title;
    $('#paper-abstract').value = paper.abstract;
    $('#paper-track').value = paper.track;
    $('#paper-type').value = paper.paper_type;
    $('#paper-presentation').value = paper.preferred_presentation;
    $('#paper-keywords').value = (paper.keywords || []).join(', ');
    $('#paper-contact-name').value = paper.contact_name || '';
    $('#paper-contact-email').value = paper.contact_email || '';
    const authors = check(await client.from('paper_authors').select('*').eq('paper_id', paperId).order('sort_order'));
    $('#paper-authors').value = authors.map((author) => [author.full_name, author.affiliation, author.email].filter(Boolean).join(' | ')).join('\n');
    const files = check(await client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }));
    showFiles(files, $('#paper-form'), 'paper-file-links');
    if (paper.submitted_at) {
      const submitted = new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(paper.submitted_at));
      $('#paper-receipt').textContent = `접수번호 ${paper.id.slice(0, 8).toUpperCase()} · 최근 제출 ${submitted} · 현재 상태 ${STATUSES[paper.status] || paper.status}. 이 화면에서 접수 상태와 PDF 버전을 다시 확인할 수 있습니다.`;
      $('#paper-receipt').hidden = false;
    }
    if (paper.decision_note) message(`위원장 메모: ${paper.decision_note}`);
    if (paper.status === 'accepted') {
      $('#final-paper-id').value = paperId;
      $('#final-status').textContent = finalUploadsOpen
        ? `최종본을 업로드할 수 있습니다. ${formatKst(settings.final_deadline)}.`
        : `최종본 제출 단계가 닫혀 있습니다. ${formatKst(settings.final_deadline)}. 위원장 안내를 확인해 주세요.`;
      $('#final-submit').disabled = !finalUploadsOpen;
      $('#final-form').hidden = false;
    }
  } else {
    $('#paper-contact-name').value = profile.full_name || '';
    $('#paper-contact-email').value = profile.email || user.email || '';
    document.getElementById('paper-file-links')?.remove();
  }
  $('#paper-form').querySelectorAll('input:not([type="hidden"]),select,textarea,button[type="submit"]').forEach((field) => { field.disabled = !editable; });
  if (editable && !submissionsOpen && myPapers.find((paper) => paper.id === paperId)?.status !== 'revision') {
    $('#paper-form').querySelector('[data-save="submitted"]').disabled = true;
  }
  $('#paper-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function showFiles(files, container, elementId) {
  document.getElementById(elementId)?.remove();
  if (!files.length) return;
  const list = document.createElement('div');
  list.id = elementId;
  list.className = 'file-list';
  list.innerHTML = `<strong>업로드된 PDF</strong>${files.map((file) => `<button type="button" data-file="${esc(file.storage_path)}">${file.file_stage === 'final' ? '최종본' : '투고본'} v${file.version} · ${esc(file.original_name)}</button>`).join('')}`;
  container.append(list);
}

async function savePaper(event) {
  event.preventDefault();
  const submit = event.submitter?.dataset.save === 'submitted';
  const paperId = $('#paper-id').value;
  try {
    const authors = parseAuthors($('#paper-authors').value);
    const keywords = parseKeywords($('#paper-keywords').value, submit);
    const input = {
      title: $('#paper-title').value.trim(), abstract: $('#paper-abstract').value.trim(),
      track: $('#paper-track').value, paper_type: $('#paper-type').value,
      preferred_presentation: $('#paper-presentation').value,
      contact_name: $('#paper-contact-name').value.trim(),
      contact_email: $('#paper-contact-email').value.trim(), keywords,
    };
    if (input.title.length < 5 || input.abstract.length < 20) throw new Error('제목과 초록을 확인해 주세요.');
    if (input.contact_email && !EMAIL_RE.test(input.contact_email)) throw new Error('연락 이메일 형식을 확인해 주세요.');
    if (submit && !hasCompleteProfile()) throw new Error('원고 제출 전에 내 정보에서 이름·소속기관을 저장해 주세요. 초안은 먼저 저장할 수 있습니다.');
    if (submit && (!input.contact_name || !input.contact_email)) throw new Error('원고 제출에는 연락 담당자 이름과 이메일이 필요합니다.');
    let id = paperId;
    if (id) {
      check(await client.from('papers').update(input).eq('id', id));
      check(await client.from('paper_authors').delete().eq('paper_id', id));
    } else {
      id = check(await client.from('papers').insert({ ...input, owner_id: user.id }).select('id').single()).id;
    }
    check(await client.from('paper_authors').insert(authors.map((author) => ({ ...author, paper_id: id }))));
    await uploadFile(id, $('#paper-file').files[0]);
    if (submit) check(await client.from('papers').update({ status: 'submitted' }).eq('id', id));
    $('#paper-form').hidden = true;
    await loadMyPapers();
    message(submit ? `원고가 제출되었습니다. 접수번호 ${id.slice(0, 8).toUpperCase()}` : '초안을 저장했습니다.');
  } catch (error) { message(error.message || '저장 중 오류가 발생했습니다.', true); }
}

async function openReview(paperId) {
  const review = reviewRows.find((row) => row.paper_id === paperId);
  if (!review) return;
  const declined = review.review_state === 'declined';
  const assigned = !declined && review.papers?.status === 'under_review';
  const editable = assigned && reviewsOpen;
  $('#review-id').value = review.id;
  $('#review-title').textContent = review.papers?.title || '배정 거절 내역';
  $('#review-paper-summary').textContent = review.papers?.abstract || '거절한 원고는 더 이상 열람할 수 없습니다.';
  $('#review-conflict').checked = review.conflict_confirmed;
  $('#review-recommendation').value = review.recommendation || '';
  $('#review-comments').value = review.comments || '';
  $('#review-decline-reason').value = review.decline_reason || '';
  $('#review-decline-panel').open = false;
  $('#review-decline-panel').hidden = !assigned;
  $('#review-state-notice').textContent = declined
    ? `배정 거절 사유: ${review.decline_reason}`
    : editable ? `현재 상태: ${REVIEW_STATES[review.review_state] || '심사 대기'}. 임시저장한 의견은 판정에 반영되지 않습니다.`
      : assigned ? `심사 입력 단계가 닫혀 있습니다. ${formatKst(settings.review_deadline)}.`
        : `현재 상태: ${REVIEW_STATES[review.review_state] || '심사 대기'}. 위원장 판정 후에는 수정할 수 없습니다.`;
  $('#review-form').querySelectorAll('#review-conflict,#review-recommendation,#review-comments,[data-review-action]').forEach((field) => { field.disabled = !editable; });
  $('[data-review-action="draft"]').disabled = !editable || review.review_state === 'submitted';
  if (declined) {
    $('#review-authors').hidden = true;
    document.getElementById('review-file-links')?.remove();
  } else {
    const authors = check(await client.from('paper_authors').select('full_name,affiliation').eq('paper_id', paperId).order('sort_order'));
    $('#review-authors').textContent = `저자·소속 확인: ${authors.map((author) => `${author.full_name} (${author.affiliation})`).join(', ') || '저자 정보 없음'}`;
    $('#review-authors').hidden = false;
    const files = check(await client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }));
    showFiles(files, $('#review-form'), 'review-file-links');
  }
  $('#review-form').hidden = false;
  $('#review-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function openChair(paperId) {
  const paper = chairPapers.find((row) => row.id === paperId);
  $('#chair-paper-id').value = paperId;
  $('#chair-title').textContent = paper.title;
  const authors = check(await client.from('paper_authors').select('full_name,affiliation,email').eq('paper_id', paperId).order('sort_order'));
  $('#chair-paper-summary').innerHTML = `<p>${esc(paper.abstract)}</p><p class="field-help">저자: ${esc(authors.map((author) => `${author.full_name} (${author.affiliation})`).join(', ') || '미입력')}<br>키워드: ${esc((paper.keywords || []).join(', ') || '미입력')}<br>연락 담당자: ${esc(paper.contact_name || '미입력')} · ${esc(paper.contact_email || '미입력')}<br>접수번호 ${esc(paperId.slice(0, 8).toUpperCase())}</p>`;
  $('#chair-status').value = paper.status;
  $('#chair-presentation').value = paper.final_presentation || '';
  $('#chair-note').value = paper.decision_note || '';
  selectedChairReviews = check(await client.from('reviews').select('id,reviewer_id,review_state,recommendation,comments,decline_reason,submitted_at,profiles(full_name,email,expertise_tracks)').eq('paper_id', paperId));
  $('#assigned-reviewers').innerHTML = selectedChairReviews.length ? selectedChairReviews.map((review) => {
    const detail = review.review_state === 'declined' ? review.decline_reason : review.review_state === 'submitted' ? review.comments : '';
    const expertise = (review.profiles?.expertise_tracks || []).map((track) => TRACKS[track] || track).join(', ');
    return `<p>${esc(review.profiles?.full_name || review.profiles?.email || '심사위원')} · ${esc(REVIEW_STATES[review.review_state] || '심사 대기')}${review.review_state === 'submitted' ? ` · ${esc(RECOMMENDATIONS[review.recommendation])}` : ''}<br><small>전문 분야: ${esc(expertise || '미입력')}</small>${detail ? `<br><small>${esc(detail)}</small>` : ''}</p>`;
  }).join('') : '<p>아직 배정된 심사위원이 없습니다. 2명 배정을 권장합니다.</p>';
  const files = check(await client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }));
  showFiles(files, $('#chair-form'), 'chair-file-links');
  $('#chair-form').hidden = false;
  $('#chair-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

document.addEventListener('click', async (event) => {
  const login = event.target.closest('[data-login]');
  if (login) {
    try { check(await client.auth.signInWithOAuth({ provider: login.dataset.login, options: { redirectTo: `${location.origin}/submission.html` } })); }
    catch (error) { message(`로그인 설정을 확인해 주세요: ${error.message}`, true); }
  }
  const tab = event.target.closest('[data-tab]');
  if (tab) showTab(tab.dataset.tab);
  const action = event.target.closest('[data-action]');
  if (action) {
    try {
      if (action.dataset.action === 'author') await openAuthor(action.dataset.id);
      if (action.dataset.action === 'review') await openReview(action.dataset.id);
      if (action.dataset.action === 'chair') await openChair(action.dataset.id);
    } catch (error) { message(error.message, true); }
  }
  const file = event.target.closest('[data-file]');
  if (file) {
    try {
      const blob = check(await client.storage.from('paper-pdfs').download(file.dataset.file));
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url; link.download = file.textContent.split(' · ').slice(1).join(' · ') || 'paper.pdf'; link.click();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
    } catch (error) { message(error.message, true); }
  }
});

$('#new-paper').addEventListener('click', () => openAuthor());
$('#cancel-paper').addEventListener('click', () => { $('#paper-form').hidden = true; $('#final-form').hidden = true; });
$('#paper-form').addEventListener('submit', savePaper);
$('#final-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const paperId = $('#final-paper-id').value;
    if (!finalUploadsOpen || myPapers.find((paper) => paper.id === paperId)?.status !== 'accepted') {
      throw new Error('채택 원고의 최종본 제출 기간을 확인해 주세요.');
    }
    await uploadFile(paperId, $('#final-file').files[0], 'final');
    await openAuthor(paperId);
    message('최종 PDF를 업로드했습니다. 원고 화면에서 버전을 확인할 수 있습니다.');
  } catch (error) { message(error.message || '최종본을 업로드하지 못했습니다.', true); }
});
$('#cancel-review').addEventListener('click', () => { $('#review-form').hidden = true; });
$('#cancel-chair').addEventListener('click', () => { $('#chair-form').hidden = true; });
$('#refresh-chair').addEventListener('click', () => loadChairPapers().catch((error) => message(error.message, true)));
$('#phase-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const submissionsRequested = $('#phase-submissions').checked;
    const submissionDeadline = deadlineValue('#phase-submission-deadline');
    const intakeActive = submissionsRequested && beforeDeadline(submissionDeadline);
    check(await client.from('conference_settings').update({
      submissions_open: submissionsRequested,
      submission_deadline: submissionDeadline,
      reviews_open: $('#phase-reviews').checked,
      review_deadline: deadlineValue('#phase-review-deadline'),
      final_uploads_open: $('#phase-final').checked,
      final_deadline: deadlineValue('#phase-final-deadline'),
      notice: intakeActive ? '논문·현장사례 투고 접수 중입니다.' : '투고 접수는 현재 닫혀 있습니다.',
    }).eq('id', true).select('id').single());
    await loadSettings();
    message('접수·심사·최종본 운영 설정을 저장했습니다.');
  } catch (error) { message(error.message, true); }
});
$('#sign-out').addEventListener('click', async () => { await client.auth.signOut(); user = null; $('#workspace').hidden = true; $('#auth-panel').hidden = false; showTab('author'); });

$('#email-auth-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = $('#auth-email').value.trim().toLowerCase();
  const password = $('#auth-password').value;
  const action = event.submitter?.dataset.emailAction || 'login';
  try {
    if (action === 'signup') {
      const result = check(await client.auth.signUp({ email, password, options: {
        emailRedirectTo: `${location.origin}/submission.html`,
      } }));
      if (result.session) {
        await loadWorkspace();
        message('회원가입이 완료되었습니다. 내 정보를 입력해 주세요.');
      } else message('확인 메일을 보냈습니다. 메일의 링크로 인증한 뒤 로그인해 주세요.');
    } else {
      check(await client.auth.signInWithPassword({ email, password }));
      await loadWorkspace();
      message('로그인했습니다.');
    }
  } catch (error) { message(error.message || '이메일 인증을 완료하지 못했습니다.', true); }
  finally { $('#auth-password').value = ''; }
});

$('#request-reset').addEventListener('click', async () => {
  const emailInput = $('#auth-email');
  if (!emailInput.reportValidity()) return;
  try {
    check(await client.auth.resetPasswordForEmail(emailInput.value.trim().toLowerCase(), {
      redirectTo: `${location.origin}/submission.html`,
    }));
    message('해당 계정이 있으면 비밀번호 재설정 메일을 보냅니다. 받은 편지함을 확인해 주세요.');
  } catch (error) { message(error.message || '재설정 메일을 보내지 못했습니다.', true); }
});

$('#recovery-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const password = $('#recovery-password').value;
  if (password !== $('#recovery-confirm').value) {
    message('새 비밀번호가 서로 다릅니다.', true);
    return;
  }
  try {
    check(await client.auth.updateUser({ password }));
    $('#recovery-form').reset();
    isRecovery = false;
    history.replaceState(null, '', `${location.pathname}${location.search}`);
    await loadWorkspace();
    message('비밀번호가 변경되었습니다.');
  } catch (error) { message(error.message || '비밀번호를 변경하지 못했습니다.', true); }
});

$('#profile-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const expertiseTracks = [...document.querySelectorAll('[name="expertise-track"]:checked')].map((input) => input.value);
    if (expertiseTracks.length > 3) throw new Error('전문 분야는 최대 3개 선택할 수 있습니다.');
    const input = {
      full_name: $('#profile-name').value.trim(), affiliation: $('#profile-affiliation').value.trim(),
      department: $('#profile-department').value.trim(), position_title: $('#profile-position').value.trim(),
      orcid: $('#profile-orcid').value.trim(), expertise_tracks: expertiseTracks,
      committee_listing_consent: $('#profile-listing-consent').checked,
    };
    if (!input.full_name || !input.affiliation) throw new Error('이름과 소속기관을 입력해 주세요.');
    if (input.orcid && !/^([0-9]{4}-){3}[0-9]{3}[0-9X]$/.test(input.orcid)) throw new Error('ORCID iD 형식을 확인해 주세요.');
    check(await client.from('profiles').update(input).eq('user_id', user.id).select('user_id').single());
    await loadWorkspace();
    message('내 정보를 저장했습니다.');
  } catch (error) { message(error.message, true); }
});

$('#review-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const draft = event.submitter?.dataset.reviewAction === 'draft';
    const comments = $('#review-comments').value.trim();
    if (!draft && (!hasCompleteProfile() || (profile.expertise_tracks || []).length === 0)) {
      throw new Error('심사 제출 전에 내 정보에서 이름·소속기관과 전문 분야 1~3개를 저장해 주세요.');
    }
    if (!draft && (!$('#review-conflict').checked || !$('#review-recommendation').value || comments.length < 10)) {
      throw new Error('이해관계 확인, 권고, 10자 이상의 의견을 입력해 주세요.');
    }
    check(await client.from('reviews').update({
      review_state: draft ? 'draft' : 'submitted',
      conflict_confirmed: $('#review-conflict').checked,
      recommendation: draft ? null : $('#review-recommendation').value,
      comments,
    }).eq('id', $('#review-id').value).select('id').single());
    $('#review-form').hidden = true;
    await loadReviews();
    message(draft ? '심사 의견을 임시저장했습니다. 아직 제출되지 않았습니다.' : '심사 의견을 제출했습니다.');
  } catch (error) { message(error.message, true); }
});

$('#decline-review').addEventListener('click', async () => {
  const reason = $('#review-decline-reason').value.trim();
  if (reason.length < 5) { message('배정 거절 사유를 5자 이상 적어 주세요.', true); return; }
  if (!window.confirm('배정을 거절하면 이 원고와 PDF를 더 이상 열람할 수 없습니다. 계속할까요?')) return;
  try {
    check(await client.from('reviews').update({ review_state: 'declined', decline_reason: reason }).eq('id', $('#review-id').value).select('id').single());
    $('#review-form').hidden = true;
    await loadReviews();
    message('배정을 거절했습니다. 위원장이 사유를 확인하고 다른 심사위원을 배정할 수 있습니다.');
  } catch (error) { message(error.message, true); }
});

$('#assign-reviewer').addEventListener('click', async () => {
  try {
    const email = $('#reviewer-email').value.trim();
    if (!email) throw new Error('심사위원 이메일을 입력해 주세요.');
    if (!EMAIL_RE.test(email)) throw new Error('심사위원 이메일 형식을 확인해 주세요.');
    const reviewer = check(await client.from('profiles').select('user_id').eq('email', email).maybeSingle());
    if (!reviewer) throw new Error('가입한 계정을 찾을 수 없습니다. 심사위원에게 먼저 로그인을 요청해 주세요.');
    const paperId = $('#chair-paper-id').value;
    check(await client.from('reviews').insert({ paper_id: paperId, reviewer_id: reviewer.user_id }));
    check(await client.from('papers').update({ status: 'under_review' }).eq('id', paperId));
    $('#reviewer-email').value = '';
    await loadChairPapers();
    await openChair(paperId);
    message('심사위원을 배정했습니다.');
  } catch (error) { message(error.message, true); }
});

$('#chair-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const status = $('#chair-status').value;
    if (!status) throw new Error('판정을 선택해 주세요.');
    const paperId = $('#chair-paper-id').value;
    check(await client.from('papers').update({ status, decision_note: $('#chair-note').value.trim(), final_presentation: $('#chair-presentation').value || null, decided_at: ['accepted', 'rejected'].includes(status) ? new Date().toISOString() : null }).eq('id', paperId));
    $('#chair-form').hidden = true;
    await loadChairPapers();
    message('원고 상태를 저장했습니다. 저자는 대시보드에서 결과를 확인할 수 있습니다.');
  } catch (error) { message(error.message, true); }
});

async function start() {
  try {
    const response = await fetch('/api/config', { cache: 'no-store' });
    if (!response.ok) throw new Error('Supabase 공개 설정이 연결되지 않았습니다. Vercel 환경변수를 확인해 주세요.');
    const config = await response.json();
    client = createClient(config.url, config.publishableKey);
    client.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY') {
        isRecovery = true;
        $('#recovery-panel').hidden = false;
        $('#auth-panel').hidden = true;
        $('#workspace').hidden = true;
      } else if (!isRecovery && session?.user?.id !== user?.id) {
        setTimeout(() => loadWorkspace().catch((error) => message(error.message, true)), 0);
      }
    });
    await loadAuthAvailability(config);
    await loadSettings();
    await loadWorkspace();
  } catch (error) { $('#notice').textContent = error.message; message(error.message, true); }
}
start();
