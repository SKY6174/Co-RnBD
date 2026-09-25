import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/+esm';

const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const TRACKS = { applied: '전문기술석사 응용연구', industry: '산학공동기술개발 성과', convergence: '산업융합기술', education: '전문기술석사 교육·운영' };
const STATUSES = { draft: '초안', submitted: '제출 완료', under_review: '심사 중', revision: '수정 요청', accepted: '채택', rejected: '반려' };
const RECOMMENDATIONS = { accept: '채택 권고', revise: '수정 권고', reject: '반려 권고' };
let client;
let user;
let profile;
let isChair = false;
let submissionsOpen = false;
let myPapers = [];
let reviewRows = [];
let chairPapers = [];
let selectedChairReviews = [];

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

function showTab(name) {
  document.querySelectorAll('[data-tab]').forEach((button) => {
    const active = button.dataset.tab === name;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });
  document.querySelectorAll('.tab-panel').forEach((panel) => { panel.hidden = panel.id !== `tab-${name}`; });
  message('');
}

async function loadSettings() {
  const setting = check(await client.from('conference_settings').select('submissions_open,notice').single());
  submissionsOpen = setting.submissions_open;
  $('#notice').textContent = setting.notice || (submissionsOpen ? '투고 접수 중입니다.' : '투고 접수 준비 중입니다.');
  $('#new-paper').disabled = !submissionsOpen;
  $('#toggle-intake').textContent = submissionsOpen ? '접수 닫기' : '접수 열기';
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
    ? '가입과 로그인은 연결된 제공자를 통해 진행됩니다.'
    : 'Google·Naver 로그인 연동 준비 중입니다. 제공자 설정 후 이용할 수 있습니다.';
}

async function loadWorkspace() {
  const session = check(await client.auth.getSession()).session;
  const current = session ? check(await client.auth.getUser()).user : null;
  user = current;
  $('#auth-panel').hidden = Boolean(user);
  $('#workspace').hidden = !user;
  if (!user) return;
  profile = check(await client.from('profiles').select('*').eq('user_id', user.id).single());
  const role = check(await client.from('staff_roles').select('role').eq('user_id', user.id).maybeSingle());
  isChair = role?.role === 'chair';
  $('#welcome').textContent = `${profile.full_name || '회원'}님의 작업 공간`;
  $('#account-email').textContent = profile.email || user.email || '이메일 정보 없음';
  $('#profile-name').value = profile.full_name || '';
  $('#profile-affiliation').value = profile.affiliation || '';
  $('[data-tab="chair"]').hidden = !isChair;
  await Promise.all([loadMyPapers(), loadReviews(), isChair ? loadChairPapers() : Promise.resolve()]);
}

function paperCard(paper, action, label) {
  const submitted = paper.submitted_at ? new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium' }).format(new Date(paper.submitted_at)) : '아직 제출하지 않음';
  return `<article class="paper-card"><div class="paper-card-top"><span class="status status-${esc(paper.status)}">${STATUSES[paper.status] || esc(paper.status)}</span><span class="paper-id">${esc(paper.id.slice(0, 8).toUpperCase())}</span></div><h3>${esc(paper.title)}</h3><p>${esc(TRACKS[paper.track])} · ${esc(submitted)}</p><button type="button" class="card-action" data-action="${action}" data-id="${esc(paper.id)}">${label} <span aria-hidden="true">↗</span></button></article>`;
}

async function loadMyPapers() {
  myPapers = check(await client.from('papers').select('*').eq('owner_id', user.id).order('created_at', { ascending: false }));
  $('#my-papers').innerHTML = myPapers.length ? myPapers.map((paper) => paperCard(paper, 'author', paper.status === 'draft' || paper.status === 'revision' ? '수정·제출' : '원고 보기')).join('') : '<p class="empty-state">아직 작성한 원고가 없습니다. 접수가 시작되면 새 원고를 작성할 수 있습니다.</p>';
}

async function loadReviews() {
  reviewRows = check(await client.from('reviews').select('id,paper_id,recommendation,comments,conflict_confirmed,submitted_at,papers(id,title,abstract,track,status,owner_id)').eq('reviewer_id', user.id).order('assigned_at', { ascending: false }));
  $('[data-tab="reviewer"]').hidden = reviewRows.length === 0;
  $('#review-list').innerHTML = reviewRows.length ? reviewRows.map((review) => paperCard(review.papers, 'review', review.recommendation ? '심사 수정' : '심사 입력')).join('') : '<p class="empty-state">배정된 원고가 없습니다.</p>';
}

async function loadChairPapers() {
  chairPapers = check(await client.from('papers').select('*').order('created_at', { ascending: false }));
  $('#chair-list').innerHTML = chairPapers.length ? chairPapers.map((paper) => paperCard(paper, 'chair', '배정·판정')).join('') : '<p class="empty-state">접수된 원고가 없습니다.</p>';
}

function parseAuthors(text) {
  const authors = text.split('\n').map((line) => line.trim()).filter(Boolean).map((line, index) => {
    const [full_name, affiliation, email = ''] = line.split('|').map((part) => part.trim());
    if (!full_name || !affiliation || (email && !/^\S+@\S+\.\S+$/.test(email))) throw new Error(`${index + 1}번째 저자 정보를 확인해 주세요.`);
    return { sort_order: index + 1, full_name, affiliation, email: email || null };
  });
  if (authors.length < 1 || authors.length > 30) throw new Error('저자는 1~30명 입력해 주세요.');
  return authors;
}

async function uploadFile(paperId, file) {
  if (!file) return;
  if (file.type !== 'application/pdf' || !file.name.toLowerCase().endsWith('.pdf') || file.size > 20 * 1024 * 1024) throw new Error('20 MB 이하 PDF 파일만 업로드할 수 있습니다.');
  const oldFiles = check(await client.from('paper_files').select('version').eq('paper_id', paperId).order('version', { ascending: false }).limit(1));
  const version = (oldFiles[0]?.version || 0) + 1;
  const path = `${user.id}/${paperId}/${crypto.randomUUID()}.pdf`;
  check(await client.storage.from('paper-pdfs').upload(path, file, { contentType: 'application/pdf', upsert: false }));
  try {
    check(await client.from('paper_files').insert({ paper_id: paperId, storage_path: path, original_name: file.name, version, uploaded_by: user.id }));
  } catch (error) {
    await client.storage.from('paper-pdfs').remove([path]);
    throw error;
  }
}

async function openAuthor(paperId = '') {
  $('#paper-form').reset();
  $('#paper-id').value = paperId;
  $('#paper-form-title').textContent = paperId ? '원고 수정·확인' : '새 원고';
  $('#paper-form').hidden = false;
  const editable = !paperId || ['draft', 'revision'].includes(myPapers.find((paper) => paper.id === paperId)?.status);
  if (paperId) {
    const paper = myPapers.find((item) => item.id === paperId);
    $('#paper-title').value = paper.title;
    $('#paper-abstract').value = paper.abstract;
    $('#paper-track').value = paper.track;
    $('#paper-type').value = paper.paper_type;
    $('#paper-presentation').value = paper.preferred_presentation;
    const authors = check(await client.from('paper_authors').select('*').eq('paper_id', paperId).order('sort_order'));
    $('#paper-authors').value = authors.map((author) => [author.full_name, author.affiliation, author.email].filter(Boolean).join(' | ')).join('\n');
    const files = check(await client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }));
    showFiles(files, $('#paper-form'), 'paper-file-links');
    if (paper.decision_note) message(`위원장 메모: ${paper.decision_note}`);
  } else document.getElementById('paper-file-links')?.remove();
  $('#paper-form').querySelectorAll('input:not([type="hidden"]),select,textarea,button[type="submit"]').forEach((field) => { field.disabled = !editable; });
  if (editable && !submissionsOpen) $('#paper-form').querySelector('[data-save="submitted"]').disabled = true;
  $('#paper-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function showFiles(files, container, elementId) {
  document.getElementById(elementId)?.remove();
  if (!files.length) return;
  const list = document.createElement('div');
  list.id = elementId;
  list.className = 'file-list';
  list.innerHTML = `<strong>업로드된 PDF</strong>${files.map((file) => `<button type="button" data-file="${esc(file.storage_path)}">v${file.version} · ${esc(file.original_name)}</button>`).join('')}`;
  container.append(list);
}

async function savePaper(event) {
  event.preventDefault();
  const submit = event.submitter?.dataset.save === 'submitted';
  const paperId = $('#paper-id').value;
  try {
    const authors = parseAuthors($('#paper-authors').value);
    const input = { title: $('#paper-title').value.trim(), abstract: $('#paper-abstract').value.trim(), track: $('#paper-track').value, paper_type: $('#paper-type').value, preferred_presentation: $('#paper-presentation').value };
    if (input.title.length < 5 || input.abstract.length < 20) throw new Error('제목과 초록을 확인해 주세요.');
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
  $('#review-id').value = review.id;
  $('#review-title').textContent = review.papers.title;
  $('#review-paper-summary').textContent = review.papers.abstract;
  $('#review-conflict').checked = review.conflict_confirmed;
  $('#review-recommendation').value = review.recommendation || '';
  $('#review-comments').value = review.comments || '';
  const files = check(await client.from('paper_files').select('*').eq('paper_id', paperId).order('version', { ascending: false }));
  showFiles(files, $('#review-form'), 'review-file-links');
  $('#review-form').hidden = false;
  $('#review-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function openChair(paperId) {
  const paper = chairPapers.find((row) => row.id === paperId);
  $('#chair-paper-id').value = paperId;
  $('#chair-title').textContent = paper.title;
  $('#chair-paper-summary').innerHTML = `<p>${esc(paper.abstract)}</p><p class="field-help">접수번호 ${esc(paperId.slice(0, 8).toUpperCase())}</p>`;
  $('#chair-status').value = paper.status;
  $('#chair-presentation').value = paper.final_presentation || '';
  $('#chair-note').value = paper.decision_note || '';
  selectedChairReviews = check(await client.from('reviews').select('id,reviewer_id,recommendation,comments,submitted_at,profiles(full_name,email)').eq('paper_id', paperId));
  $('#assigned-reviewers').innerHTML = selectedChairReviews.length ? selectedChairReviews.map((review) => `<p>${esc(review.profiles?.full_name || review.profiles?.email || '심사위원')} · ${esc(RECOMMENDATIONS[review.recommendation] || '심사 대기')}${review.comments ? `<br><small>${esc(review.comments)}</small>` : ''}</p>`).join('') : '<p>아직 배정된 심사위원이 없습니다. 2명 배정을 권장합니다.</p>';
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
$('#cancel-paper').addEventListener('click', () => { $('#paper-form').hidden = true; });
$('#paper-form').addEventListener('submit', savePaper);
$('#cancel-review').addEventListener('click', () => { $('#review-form').hidden = true; });
$('#cancel-chair').addEventListener('click', () => { $('#chair-form').hidden = true; });
$('#refresh-chair').addEventListener('click', () => loadChairPapers().catch((error) => message(error.message, true)));
$('#toggle-intake').addEventListener('click', async () => {
  try {
    check(await client.from('conference_settings').update({ submissions_open: !submissionsOpen, notice: submissionsOpen ? '투고 접수는 현재 마감되었습니다.' : '논문·실천사례 투고 접수 중입니다.' }).eq('id', true));
    await loadSettings();
    message(submissionsOpen ? '접수를 열었습니다.' : '접수를 닫았습니다.');
  } catch (error) { message(error.message, true); }
});
$('#sign-out').addEventListener('click', async () => { await client.auth.signOut(); user = null; $('#workspace').hidden = true; $('#auth-panel').hidden = false; showTab('author'); });

$('#profile-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    check(await client.from('profiles').update({ full_name: $('#profile-name').value.trim(), affiliation: $('#profile-affiliation').value.trim() }).eq('user_id', user.id));
    message('내 정보를 저장했습니다.');
    await loadWorkspace();
  } catch (error) { message(error.message, true); }
});

$('#review-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    check(await client.from('reviews').update({ conflict_confirmed: $('#review-conflict').checked, recommendation: $('#review-recommendation').value, comments: $('#review-comments').value.trim() }).eq('id', $('#review-id').value));
    $('#review-form').hidden = true;
    await loadReviews();
    message('심사 의견을 저장했습니다.');
  } catch (error) { message(error.message, true); }
});

$('#assign-reviewer').addEventListener('click', async () => {
  try {
    const email = $('#reviewer-email').value.trim();
    if (!email) throw new Error('심사위원 이메일을 입력해 주세요.');
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
    await loadAuthAvailability(config);
    await loadSettings();
    await loadWorkspace();
    client.auth.onAuthStateChange((_event, session) => {
      if (session?.user?.id !== user?.id) setTimeout(() => loadWorkspace().catch((error) => message(error.message, true)), 0);
    });
  } catch (error) { $('#notice').textContent = error.message; message(error.message, true); }
}
start();
