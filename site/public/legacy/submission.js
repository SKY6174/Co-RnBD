import { conferenceClient, conferenceConfig } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
// 모집 분야 코드와 화면 표시명 매핑 (신규 4개 분야 및 기존 데이터 호환 코드)
const TRACKS = {
  master_eng: '전문기술석사 (공학 분야)',
  master_sci: '전문기술석사 (자연과학 분야)',
  industry_joint: '산학공동기술개발과제',
  convergence_etc: '기타 산학융합과제',
  applied: '전문기술석사 응용연구',
  industry: '산학공동기술개발과제 성과발표',
  convergence: '산업융합기술',
  education: 'T-VET 정책·교육연구',
};
const ACTIVE_TRACK_KEYS = ['master_eng', 'master_sci', 'industry_joint', 'convergence_etc'];
const LEGACY_TRACK_MAP = {
  applied: 'master_eng',
  industry: 'industry_joint',
  convergence: 'convergence_etc',
  education: 'convergence_etc',
};
const PRESENTATIONS = { oral: '구두', poster: '포스터', demo: '데모' };
const SESSIONS = {
  oral_1: 'Oral Session 1',
  oral_2: 'Oral Session 2',
  oral_3: 'Oral Session 3',
  poster_1: 'Poster Session 1',
};
const ORAL_MIN_TARGET = 20;
const POSTER_MIN_TARGET = 30;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const STATUSES = { draft: '초안', submitted: '제출 완료', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려', declined: '배정 거절' };
const RECOMMENDATIONS = { accept: '채택 권고', revise: '수정 권고', reject: '반려 권고' };
const REVIEW_STATES = { assigned: '심사 대기', draft: '임시저장', submitted: '심사 제출', declined: '배정 거절' };
const EMAIL_LINK_TYPES = { 'auth-signup': 'email', 'auth-magiclink': 'magiclink', 'auth-recovery': 'recovery' };

// 반복 호출되는 날짜 포매터를 싱글톤으로 생성하여 렌더링 속도 최적화
const kstMediumDateTimeFormatter = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  dateStyle: 'medium',
  timeStyle: 'short',
});
const kstMediumDateFormatter = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  dateStyle: 'medium',
});
const emailLinkParams = new URLSearchParams(location.hash.slice(1));
const emailLink = Object.entries(EMAIL_LINK_TYPES)
  .map(([name, type]) => ({ token_hash: emailLinkParams.get(name), type }))
  .find(({ token_hash }) => token_hash);
let client;
let user;
let profile;
let isChair = false;
let submissionsOpen = false;
let reviewsOpen = false;
let finalUploadsOpen = false;
let settings;
let edition;
let myPapers = [];
let reviewRows = [];
let chairPapers = [];
let selectedChairReviews = [];
let isRecovery = new URLSearchParams(location.hash.slice(1)).get('type') === 'recovery'
  || new URLSearchParams(location.search).get('type') === 'recovery'
  || emailLink?.type === 'recovery';

function message(text, error = false) {
  const target = $('#message');
  target.textContent = text;
  target.classList.toggle('error', error);
  target.hidden = !text;
  if (text) target.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function showAuthMode(mode) {
  if (mode === 'signup' && !$('#signup-email').value) $('#signup-email').value = $('#auth-email').value.trim();
  if (mode === 'login' && $('#signup-email').value) $('#auth-email').value = $('#signup-email').value.trim();
  $('#email-auth-form').hidden = mode !== 'login';
  $('#signup-form').hidden = mode !== 'signup';
  $('#signup-pending').hidden = mode !== 'pending';
  $('#auth-title').textContent = mode === 'signup' ? '이메일 회원가입' : mode === 'pending' ? '이메일 확인 대기' : '계정으로 시작하기';
  $('#auth-description').textContent = mode === 'signup'
    ? '이메일과 비밀번호를 설정하고 확인 메일을 받아 주세요.'
    : mode === 'pending' ? '받은 편지함의 확인 링크를 열면 가입이 완료됩니다.'
      : '이메일로 가입하거나 로그인해 원고를 관리하세요. 심사위원에게는 배정된 원고가 추가로 표시됩니다.';
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
  return `${kstMediumDateTimeFormatter.format(new Date(value))} KST`;
}

function phaseCard(title, configured, deadline) {
  const open = configured && beforeDeadline(deadline);
  const status = open ? '진행 중' : configured && deadline ? '마감' : '닫힘';
  return `<article><strong>${title}</strong><span class="${open ? 'phase-open' : 'phase-closed'}">${status}</span><br><span>${esc(formatKst(deadline))}</span></article>`;
}

async function loadSettings() {
  settings = check(await client.from('conference_settings')
    .select('submissions_open,submission_deadline,reviews_open,review_deadline,final_uploads_open,final_deadline,notice')
    .eq('edition_year', edition.year).single());
  submissionsOpen = settings.submissions_open && beforeDeadline(settings.submission_deadline);
  reviewsOpen = settings.reviews_open && beforeDeadline(settings.review_deadline);
  finalUploadsOpen = settings.final_uploads_open && beforeDeadline(settings.final_deadline);
  const publicNotice = settings.notice?.trim() || (submissionsOpen ? '투고 접수 중입니다.' : '투고 접수 준비 중입니다.');
  $('#notice').textContent = settings.submissions_open && !submissionsOpen
    ? `투고 접수 기간이 종료되었습니다. ${publicNotice}`
    : publicNotice;
  $('#submission-pilot-status').textContent = edition.year === 2026
    ? `투고 시스템 시범 운영 · 현재 원고 접수가 ${submissionsOpen ? '열려 있습니다.' : '닫혀 있습니다.'}`
    : `원고 접수가 ${submissionsOpen ? '열려 있습니다.' : '닫혀 있습니다.'}`;
  $('#phase-overview').innerHTML = phaseCard('원고 접수', settings.submissions_open, settings.submission_deadline)
    + phaseCard('심사 입력', settings.reviews_open, settings.review_deadline)
    + phaseCard('최종본 제출', settings.final_uploads_open, settings.final_deadline);
  $('#new-paper').disabled = !submissionsOpen;
}

async function loadAuthAvailability(config) {
  let authSettings = {};
  try {
    const response = await fetch(`${config.url}/auth/v1/settings`, {
      headers: { apikey: config.publishableKey },
    });
    if (response.ok) authSettings = await response.json();
  } catch { /* Leave providers disabled; the rest of the portal can still load. */ }
  const googleReady = authSettings.external?.google === true;
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
  if (!user || isRecovery) {
    $('#submission-operations-link').hidden = true;
    return;
  }
  // 프로필(profiles)과 운영진 권한(staff_roles)을 병렬(Promise.all)로 동시에 조회하여 대기 시간 단축
  const [profileResult, roleResult] = await Promise.all([
    client.from('profiles').select('*').eq('user_id', user.id).single(),
    client.from('staff_roles').select('role,is_super_admin').eq('user_id', user.id).maybeSingle(),
  ]);
  profile = check(profileResult);
  const role = check(roleResult);
  isChair = role?.role === 'chair';
  $('#submission-operations-link').hidden = !isChair;
  $('#submission-monitor-link').hidden = !role?.is_super_admin;
  $('#welcome').textContent = `${profile.full_name || '회원'}님의 작업 공간`;
  $('#account-email').textContent = profile.email || user.email || '이메일 정보 없음';
  $('#profile-name').value = profile.full_name || '';
  $('#profile-affiliation').value = profile.affiliation || '';
  $('#profile-department').value = profile.department || '';
  $('#profile-position').value = profile.position_title || '';
  $('#profile-orcid').value = profile.orcid || '';
  $('#profile-email').value = profile.email || user.email || '';
  $('#profile-listing-consent').checked = Boolean(profile.committee_listing_consent);
  const normalizedExpertise = (profile.expertise_tracks || []).map((track) => LEGACY_TRACK_MAP[track] || track);
  document.querySelectorAll('[name="expertise-track"]').forEach((input) => {
    input.checked = normalizedExpertise.includes(input.value);
  });
  $('[data-tab="chair"]').hidden = !isChair;
  await Promise.all([loadMyPapers(), loadReviews(), isChair ? loadChairPapers() : Promise.resolve()]);
  if (isChair && location.hash === '#chair') showTab('chair');
}

function paperCard(paper, action, label) {
  const submitted = paper.submitted_at ? kstMediumDateFormatter.format(new Date(paper.submitted_at)) : '아직 제출하지 않음';
  const sessionLabel = paper.assigned_session
    ? ` · ${SESSIONS[paper.assigned_session] || paper.assigned_session}`
    : paper.final_presentation
      ? ` · ${PRESENTATIONS[paper.final_presentation] || paper.final_presentation} 확정`
      : '';
  const detail = paper.status === 'declined' ? '원고 열람 권한이 종료됐습니다.' : `${TRACKS[paper.track] || '분야 미지정'} · ${submitted}${sessionLabel}`;
  return `<article class="paper-card"><div class="paper-card-top"><span class="status status-${esc(paper.status)}">${STATUSES[paper.status] || esc(paper.status)}</span><span class="paper-id">${esc(paper.id.slice(0, 8).toUpperCase())}</span></div><h3>${esc(paper.title)}</h3><p>${esc(detail)}</p><button type="button" class="card-action" data-action="${action}" data-id="${esc(paper.id)}">${label} <span aria-hidden="true">↗</span></button></article>`;
}

async function loadMyPapers() {
  myPapers = check(await client.from('papers').select('*')
    .eq('edition_year', edition.year).eq('owner_id', user.id).order('created_at', { ascending: false }));
  $('#my-papers').innerHTML = myPapers.length ? myPapers.map((paper) => paperCard(paper, 'author', paper.status === 'draft' || paper.status === 'revision' ? '수정·제출' : '원고 보기')).join('') : '<p class="empty-state">아직 작성한 원고가 없습니다. 접수가 시작되면 새 원고를 작성할 수 있습니다.</p>';
}

async function loadReviews() {
  reviewRows = check(await client.from('reviews').select('id,paper_id,review_state,recommendation,comments,conflict_confirmed,submitted_at,decline_reason,papers(id,title,abstract,track,status,owner_id,submitted_at,edition_year)').eq('reviewer_id', user.id).order('assigned_at', { ascending: false }))
    .filter((review) => review.papers?.edition_year === edition.year);
  $('[data-tab="reviewer"]').hidden = reviewRows.length === 0;
  $('#review-list').innerHTML = reviewRows.length ? reviewRows.map((review) => {
    const paper = review.papers || { id: review.paper_id, title: '배정 거절 내역', status: 'declined' };
    const label = review.review_state === 'declined' ? '거절 사유 확인' : review.review_state === 'submitted' ? '심사 확인·수정' : '심사 입력';
    return paperCard(paper, 'review', label);
  }).join('') : '<p class="empty-state">배정된 원고가 없습니다.</p>';
}

function renderChairQuotaBoard() {
  const board = $('#chair-quota-board');
  if (!board) return;
  const preferredOral = chairPapers.filter((paper) => paper.preferred_presentation === 'oral').length;
  const preferredPoster = chairPapers.filter((paper) => paper.preferred_presentation === 'poster').length;
  const acceptedPapers = chairPapers.filter((paper) => paper.status === 'accepted');
  const acceptedOral = acceptedPapers.filter((paper) => (paper.final_presentation || paper.preferred_presentation) === 'oral').length;
  const acceptedPoster = acceptedPapers.filter((paper) => (paper.final_presentation || paper.preferred_presentation) === 'poster').length;
  const sessionCount = (sessionKey) => acceptedPapers.filter((paper) => paper.assigned_session === sessionKey).length;
  const trackRows = ACTIVE_TRACK_KEYS.map((key) => {
    const inTrack = chairPapers.filter((paper) => (LEGACY_TRACK_MAP[paper.track] || paper.track) === key);
    const acceptedInTrack = inTrack.filter((paper) => paper.status === 'accepted').length;
    return `<li><span>${esc(TRACKS[key])}</span><strong>접수 ${inTrack.length}편 · 채택 ${acceptedInTrack}편</strong></li>`;
  }).join('');
  board.innerHTML = `
    <article class="quota-card">
      <span class="portal-kicker">ORAL SESSIONS (3개 세션)</span>
      <strong>구두 채택 ${acceptedOral}편 / 최소 ${ORAL_MIN_TARGET}편 목표</strong>
      <p>구두 희망 접수 ${preferredOral}편 · ${acceptedOral >= ORAL_MIN_TARGET ? '목표 달성' : `${ORAL_MIN_TARGET - acceptedOral}편 추가 확보 필요`}</p>
      <div class="quota-sublist">
        <span>Oral 1: ${sessionCount('oral_1')}편</span>
        <span>Oral 2: ${sessionCount('oral_2')}편</span>
        <span>Oral 3: ${sessionCount('oral_3')}편</span>
      </div>
    </article>
    <article class="quota-card">
      <span class="portal-kicker">POSTER SESSION (1개 세션)</span>
      <strong>포스터 채택 ${acceptedPoster}편 / 최소 ${POSTER_MIN_TARGET}편 목표</strong>
      <p>포스터 희망 접수 ${preferredPoster}편 · ${acceptedPoster >= POSTER_MIN_TARGET ? '목표 달성' : `${POSTER_MIN_TARGET - acceptedPoster}편 추가 확보 필요`}</p>
      <div class="quota-sublist">
        <span>Poster 1 배정: ${sessionCount('poster_1')}편</span>
      </div>
    </article>
    <article class="quota-card quota-card-wide">
      <span class="portal-kicker">TRACK BREAKDOWN (3대 분야 · 4개 세부 트랙)</span>
      <ul class="quota-track-list">${trackRows}</ul>
    </article>
  `;
}

async function loadChairPapers() {
  chairPapers = check(await client.from('papers').select('*').eq('edition_year', edition.year)
    .neq('status', 'draft').order('created_at', { ascending: false }));
  const count = (statuses) => chairPapers.filter((paper) => statuses.includes(paper.status)).length;
  $('#chair-summary').innerHTML = `<span>전체 ${chairPapers.length}</span><span>심사 대기·진행 ${count(['submitted', 'under_review'])}</span><span>수정 요청 ${count(['revision'])}</span><span>채택 ${count(['accepted'])}</span><span>반려 ${count(['rejected'])}</span>`;
  renderChairQuotaBoard();
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
    $('#paper-track').value = ACTIVE_TRACK_KEYS.includes(paper.track) ? paper.track : (LEGACY_TRACK_MAP[paper.track] || 'master_eng');
    $('#paper-type').value = paper.paper_type;
    $('#paper-presentation').value = paper.preferred_presentation;
    $('#paper-keywords').value = (paper.keywords || []).join(', ');
    $('#paper-contact-name').value = paper.contact_name || '';
    $('#paper-contact-email').value = paper.contact_email || '';
    // 저자 목록(paper_authors)과 첨부 파일(paper_files)을 병렬(Promise.all)로 동시에 조회
    const [authorsResult, filesResult] = await Promise.all([
      client.from('paper_authors').select('*').eq('paper_id', paperId).order('sort_order'),
      client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }),
    ]);
    const authors = check(authorsResult);
    const files = check(filesResult);
    $('#paper-authors').value = authors.map((author) => [author.full_name, author.affiliation, author.email].filter(Boolean).join(' | ')).join('\n');
    showFiles(files, $('#paper-form'), 'paper-file-links');
    if (paper.submitted_at) {
      const submitted = kstMediumDateTimeFormatter.format(new Date(paper.submitted_at));
      const assignedText = paper.assigned_session
        ? ` · 배정 세션 ${SESSIONS[paper.assigned_session] || paper.assigned_session}`
        : paper.final_presentation
          ? ` · 확정 발표 형태 ${PRESENTATIONS[paper.final_presentation] || paper.final_presentation}`
          : '';
      $('#paper-receipt').textContent = `접수번호 ${paper.id.slice(0, 8).toUpperCase()} · 최근 제출 ${submitted} · 현재 상태 ${STATUSES[paper.status] || paper.status}${assignedText}. 이 화면에서 접수 상태와 PDF 버전을 다시 확인할 수 있습니다.`;
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
      // 기존 원고 수정 시 메타데이터 업데이트와 기존 저자 목록 정리를 병렬 수행
      const [updateResult, deleteAuthorsResult] = await Promise.all([
        client.from('papers').update(input).eq('id', id),
        client.from('paper_authors').delete().eq('paper_id', id),
      ]);
      check(updateResult);
      check(deleteAuthorsResult);
    } else {
      id = check(await client.from('papers').insert({ ...input, owner_id: user.id, edition_year: edition.year }).select('id').single()).id;
    }
    await Promise.all([
      client.from('paper_authors').insert(authors.map((author) => ({ ...author, paper_id: id }))).then(check),
      uploadFile(id, $('#paper-file').files[0]),
    ]);
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
    // 심사 대상 원고의 저자 목록과 첨부 PDF 파일을 병렬(Promise.all)로 동시에 조회
    const [authorsResult, filesResult] = await Promise.all([
      client.from('paper_authors').select('full_name,affiliation').eq('paper_id', paperId).order('sort_order'),
      client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }),
    ]);
    const authors = check(authorsResult);
    const files = check(filesResult);
    $('#review-authors').textContent = `저자·소속 확인: ${authors.map((author) => `${author.full_name} (${author.affiliation})`).join(', ') || '저자 정보 없음'}`;
    $('#review-authors').hidden = false;
    showFiles(files, $('#review-form'), 'review-file-links');
  }
  $('#review-form').hidden = false;
  $('#review-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function openChair(paperId) {
  const paper = chairPapers.find((row) => row.id === paperId);
  $('#chair-paper-id').value = paperId;
  $('#chair-title').textContent = paper.title;
  $('#chair-status').value = paper.status;
  $('#chair-presentation').value = paper.final_presentation || '';
  $('#chair-session').value = paper.assigned_session || '';
  $('#chair-note').value = paper.decision_note || '';
  // 저자 목록, 심사위원 배정/의견, 첨부 PDF 파일 3개 쿼리를 병렬(Promise.all)로 한 번에 조회
  const [authorsResult, reviewsResult, filesResult] = await Promise.all([
    client.from('paper_authors').select('full_name,affiliation,email').eq('paper_id', paperId).order('sort_order'),
    client.from('reviews').select('id,reviewer_id,review_state,recommendation,comments,decline_reason,submitted_at,profiles(full_name,email,expertise_tracks)').eq('paper_id', paperId),
    client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }),
  ]);
  const authors = check(authorsResult);
  selectedChairReviews = check(reviewsResult);
  const files = check(filesResult);
  $('#chair-paper-summary').innerHTML = `<p>${esc(paper.abstract)}</p><p class="field-help">모집 분야: ${esc(TRACKS[paper.track] || paper.track)} · 희망 발표 형태: ${esc(PRESENTATIONS[paper.preferred_presentation] || paper.preferred_presentation)}<br>저자: ${esc(authors.map((author) => `${author.full_name} (${author.affiliation})`).join(', ') || '미입력')}<br>키워드: ${esc((paper.keywords || []).join(', ') || '미입력')}<br>연락 담당자: ${esc(paper.contact_name || '미입력')} · ${esc(paper.contact_email || '미입력')}<br>접수번호 ${esc(paperId.slice(0, 8).toUpperCase())}</p>`;
  $('#assigned-reviewers').innerHTML = selectedChairReviews.length ? selectedChairReviews.map((review) => {
    const detail = review.review_state === 'declined' ? review.decline_reason : review.review_state === 'submitted' ? review.comments : '';
    const expertise = (review.profiles?.expertise_tracks || []).map((track) => TRACKS[track] || track).join(', ');
    return `<p>${esc(review.profiles?.full_name || review.profiles?.email || '심사위원')} · ${esc(REVIEW_STATES[review.review_state] || '심사 대기')}${review.review_state === 'submitted' ? ` · ${esc(RECOMMENDATIONS[review.recommendation])}` : ''}<br><small>전문 분야: ${esc(expertise || '미입력')}</small>${detail ? `<br><small>${esc(detail)}</small>` : ''}</p>`;
  }).join('') : '<p>아직 배정된 심사위원이 없습니다. 2명 배정을 권장합니다.</p>';
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
$('#sign-out').addEventListener('click', async () => { await client.auth.signOut(); user = null; isChair = false; $('#submission-operations-link').hidden = true; $('#workspace').hidden = true; $('#auth-panel').hidden = false; showAuthMode('login'); showTab('author'); });

document.querySelectorAll('[data-auth-mode]').forEach((button) => button.addEventListener('click', () => {
  $('#auth-password').value = '';
  $('#signup-password').value = '';
  $('#signup-confirm').value = '';
  showAuthMode(button.dataset.authMode);
  message('');
}));

$('#email-auth-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = $('#auth-email').value.trim().toLowerCase();
  const password = $('#auth-password').value;
  try {
    check(await client.auth.signInWithPassword({ email, password }));
    await loadWorkspace();
    message('로그인했습니다.');
  } catch (error) { message(error.message || '이메일 인증을 완료하지 못했습니다.', true); }
  finally { $('#auth-password').value = ''; }
});

$('#signup-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = $('#signup-email').value.trim().toLowerCase();
  const password = $('#signup-password').value;
  if (password.length < 10) { message('회원가입 비밀번호는 10자 이상으로 입력해 주세요.', true); return; }
  if (password !== $('#signup-confirm').value) { message('비밀번호 확인이 일치하지 않습니다.', true); return; }
  const submitButton = event.submitter;
  if (submitButton) submitButton.disabled = true;
  try {
    const result = check(await client.auth.signUp({ email, password, options: {
      emailRedirectTo: `${location.origin}/submission.html`,
    } }));
    if (result.session) {
      await client.auth.signOut();
      throw new Error('가입 확인 메일 설정을 확인해 주세요. 운영자에게 문의해 주세요.');
    }
    showAuthMode('pending');
    message('가입 확인 메일을 요청했습니다. 이메일의 확인 링크를 열면 가입이 완료됩니다.');
  } catch (error) { message(error.message || '가입 확인 메일을 요청하지 못했습니다.', true); }
  finally {
    $('#signup-password').value = '';
    $('#signup-confirm').value = '';
    if (submitButton) submitButton.disabled = false;
  }
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
    const email = $('#reviewer-email').value.trim().toLowerCase();
    if (!email) throw new Error('심사위원 이메일을 입력해 주세요.');
    if (!EMAIL_RE.test(email)) throw new Error('심사위원 이메일 형식을 확인해 주세요.');
    const reviewer = check(await client.from('profiles').select('user_id').ilike('email', email).maybeSingle());
    if (!reviewer) throw new Error('가입한 계정을 찾을 수 없습니다. 심사위원에게 먼저 로그인을 요청해 주세요.');
    const paperId = $('#chair-paper-id').value;
    check(await client.from('reviews').insert({ paper_id: paperId, reviewer_id: reviewer.user_id }));
    check(await client.from('papers').update({ status: 'under_review' }).eq('id', paperId));
    $('#reviewer-email').value = '';
    await Promise.all([loadChairPapers(), openChair(paperId)]);
    message('심사위원을 배정했습니다.');
  } catch (error) { message(error.message, true); }
});

$('#chair-session').addEventListener('change', () => {
  const sessionKey = $('#chair-session').value;
  if (sessionKey.startsWith('oral_')) $('#chair-presentation').value = 'oral';
  else if (sessionKey === 'poster_1') $('#chair-presentation').value = 'poster';
});

$('#chair-presentation').addEventListener('change', () => {
  const presentation = $('#chair-presentation').value;
  const sessionKey = $('#chair-session').value;
  if (presentation === 'oral' && sessionKey === 'poster_1') $('#chair-session').value = '';
  else if (presentation === 'poster' && sessionKey.startsWith('oral_')) $('#chair-session').value = 'poster_1';
  else if (!presentation || presentation === 'demo') $('#chair-session').value = '';
});

$('#chair-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const status = $('#chair-status').value;
    if (!status) throw new Error('판정을 선택해 주세요.');
    let finalPresentation = $('#chair-presentation').value || null;
    const assignedSession = $('#chair-session').value || null;
    if (assignedSession && status !== 'accepted') {
      throw new Error('세션 배정은 채택 판정인 원고에만 지정할 수 있습니다.');
    }
    if (assignedSession && !finalPresentation) {
      finalPresentation = assignedSession.startsWith('oral_') ? 'oral' : 'poster';
    }
    if (assignedSession?.startsWith('oral_') && finalPresentation !== 'oral') {
      throw new Error('Oral Session 1~3 배정 시 발표 형태는 구두(Oral)여야 합니다.');
    }
    if (assignedSession === 'poster_1' && finalPresentation !== 'poster') {
      throw new Error('Poster Session 1 배정 시 발표 형태는 포스터(Poster)여야 합니다.');
    }
    const paperId = $('#chair-paper-id').value;
    check(await client.from('papers').update({
      status,
      decision_note: $('#chair-note').value.trim(),
      final_presentation: finalPresentation,
      assigned_session: status === 'accepted' ? assignedSession : null,
      decided_at: ['accepted', 'rejected'].includes(status) ? new Date().toISOString() : null,
    }).eq('id', paperId));
    $('#chair-form').hidden = true;
    await loadChairPapers();
    message('원고 판정 및 세션 배정 상태를 저장했습니다. 저자는 대시보드에서 결과를 확인할 수 있습니다.');
  } catch (error) { message(error.message, true); }
});

async function start() {
  try {
    const config = await conferenceConfig();
    client = await conferenceClient(config);
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
    const [, editionResult] = await Promise.all([
      loadAuthAvailability(config),
      client.from('conference_editions').select('year,title,status').eq('status', 'current').single(),
    ]);
    edition = check(editionResult);
    document.title = `논문 투고·심사 | ${edition.title}`;
    $('#submission-edition-label').textContent = `CO-R&BD ${edition.year} / PAPER PORTAL`;
    $('#submission-intro').textContent = `${edition.title}의 원고 제출, 심사와 결과 확인을 이 화면에서 진행합니다.`;
    $('#submission-footer-edition').textContent = edition.title;
    $('#submission-cfp-link').href = edition.year === 2026 ? './cfp.html' : './edition.html';
    $('#submission-cfp-link').textContent = edition.year === 2026 ? '모집공고 보기' : '학회 안내 보기';
    let emailLinkMessage;
    let emailLinkError = false;
    if (emailLink) {
      try {
        check(await client.auth.verifyOtp(emailLink));
        emailLinkMessage = emailLink.type === 'recovery'
          ? '이메일 인증이 완료되었습니다. 새 비밀번호를 설정해 주세요.'
          : emailLink.type === 'email' ? '이메일 인증이 완료되어 회원가입이 완료되었습니다. 내 정보를 입력해 주세요.'
            : '이메일 인증이 완료되었습니다.';
      } catch (error) {
        isRecovery = false;
        emailLinkError = true;
        emailLinkMessage = '인증 링크가 유효하지 않거나 만료되었습니다. 새 메일을 요청해 주세요.';
      }
      history.replaceState(null, '', `${location.pathname}${location.search}`);
    }
    // 학회 운영 설정(loadSettings)과 사용자 워크스페이스(loadWorkspace)를 병렬(Promise.all)로 동시에 로드
    await Promise.all([loadSettings(), loadWorkspace()]);
    if (emailLink?.type === 'email' && !emailLinkError && !user) {
      showAuthMode('login');
      emailLinkMessage = '이메일 인증이 완료되어 회원가입이 완료되었습니다. 이메일과 비밀번호로 로그인해 주세요.';
    }
    if (emailLinkMessage) message(emailLinkMessage, emailLinkError);
  } catch (error) { $('#notice').textContent = error.message; message(error.message, true); }
}
start();
