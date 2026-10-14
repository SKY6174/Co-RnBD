import { conferenceClient, currentEdition, escapeHtml as esc, requireData as data } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const TRACKS = { master_eng:'전문기술석사 (공학 분야)',master_sci:'전문기술석사 (자연과학 분야)',industry_joint:'산학공동기술개발과제',convergence_etc:'기타 산학융합과제',applied:'전문기술석사 응용연구',industry:'산학공동기술개발과제 성과발표',convergence:'산업융합기술',education:'T-VET 정책·교육연구' };
const STATUS = {submitted:'제출 완료',under_review:'심사 중',revision:'수정 요청',accepted:'채택',rejected:'반려'};
const REVIEW = {assigned:'심사 대기',draft:'임시저장',submitted:'심사 제출',declined:'배정 거절'};
const RECOMMENDATION = {accept:'채택 권고',revise:'수정 권고',reject:'반려 권고'};
const ACTION = {paper_submitted:'원고 제출',paper_status_changed:'진행 상태 변경',review_assigned:'심사위원 배정',review_revoked:'심사 배정 철회',review_submitted:'심사 의견 제출',review_declined:'심사 배정 거절',decision_published:'판정 확정·공개',file_uploaded:'PDF 업로드',final_checked:'최종본 확인 완료'};
const FILTERS = [['all','전체 접수'],['unassigned','미배정'],['reviewing','심사 중'],['ready','판정 대기'],['revision','수정 요청'],['accepted','채택'],['rejected','반려']];
const dateFormatter = new Intl.DateTimeFormat('ko-KR',{timeZone:'Asia/Seoul',dateStyle:'short',timeStyle:'short'});
const date = (value) => value ? dateFormatter.format(new Date(value))+' KST' : '—';
const sameTime = (a,b) => Boolean(a && b) && new Date(a).getTime()===new Date(b).getTime();
let client, user, edition, selectedId, pendingDecision;
let papers=[], members=[], membersById=new Map(), busy=false;
let detailRequest=0;
const selected = () => papers.find(p=>p.id===selectedId);
const currentReviews = (p) => (p.reviews||[]).filter(r=>sameTime(r.manuscript_submitted_at,p.submitted_at));
const activeReviews = (p) => currentReviews(p).filter(r=>!r.revoked_at && r.review_state!=='declined');
const complete = (p) => activeReviews(p).length>0 && activeReviews(p).every(r=>r.review_state==='submitted');
const latestFinal = (p) => (p.paper_files||[]).filter(f=>f.file_stage==='final').sort((a,b)=>b.version-a.version)[0];
const finalCheck = (p) => Array.isArray(p.paper_final_checks) ? p.paper_final_checks[0] : p.paper_final_checks;
const finalConfirmed = (p) => Boolean(latestFinal(p) && finalCheck(p)?.file_id===latestFinal(p).id);
const memberName = (id) => membersById.get(id)?.full_name || membersById.get(id)?.email || '회원';
const badge = (status) => `<span class="chair-badge ${esc(status)}">${esc(STATUS[status]||status)}</span>`;
function notice(text,error=false) { const el=$('#chair-message');el.textContent=text;el.classList.toggle('error',error);el.setAttribute('role',error?'alert':'status'); }
function friendly(error) {
  const text=error?.message||'처리하지 못했습니다. 다시 시도해 주세요.';
  const messages=[[/duplicate key|reviews_manuscript_reviewer_key/,'이미 이 제출본에 배정된 심사위원입니다.'],[/Reviewer is an author/,'저자·공동저자는 심사위원으로 배정할 수 없습니다.'],[/At most two/,'유효 심사위원은 최대 2명입니다. 기존 배정을 교체해 주세요.'],[/Incomplete reviews/,'미완료 심사에 대한 예외 판정 사유를 5자 이상 입력해 주세요.'],[/Paper changed|Assignment changed/,'다른 작업으로 원고가 변경됐습니다. 새로고침 후 다시 확인해 주세요.'],[/latest final PDF/,'더 최신인 최종본이 있습니다. 새로고침 후 확인해 주세요.'],[/Chair permission|required.*permission|row-level security/,'이 작업에 필요한 위원장 권한을 확인해 주세요.'],[/Remove the paper from its session/,'프로그램에 편성된 원고입니다. 운영 관리에서 편성을 해제한 뒤 판정·발표 형태를 변경해 주세요.']];
  return messages.find(([pattern])=>pattern.test(text))?.[1]||text;
}
async function allRows(factory) {
  const rows=[];
  for(let offset=0;;offset+=300) { const part=data(await factory().range(offset,offset+299));rows.push(...part);if(part.length<300)return rows; }
}
async function load() {
  const [list,profiles]=await Promise.all([
    allRows(()=>client.from('papers').select('*,paper_authors(*),reviews(*),paper_files(*),paper_final_checks(*)').eq('edition_year',edition.year).neq('status','draft').not('submitted_at','is',null).order('id')),
    allRows(()=>client.from('profiles').select('user_id,full_name,email,affiliation,expertise_tracks').order('user_id')),
  ]);
  papers=list.sort((a,b)=>new Date(b.submitted_at)-new Date(a.submitted_at));members=profiles;membersById=new Map(profiles.map(p=>[p.user_id,p]));renderList();
}
function matches(p,status) {
  const pending=['submitted','under_review'].includes(p.status);
  if(status==='all')return true;
  if(status==='unassigned')return pending && !activeReviews(p).length;
  if(status==='reviewing')return pending && activeReviews(p).length>0 && !complete(p);
  if(status==='ready')return pending && complete(p);
  if(status==='final_pending')return p.status==='accepted' && latestFinal(p) && !finalConfirmed(p);
  return p.status===status;
}
function renderList() {
  const filter=$('#chair-status-filter').value, track=$('#chair-track-filter').value, search=$('#chair-search').value.trim().toLocaleLowerCase();
  $('#chair-stats').innerHTML=FILTERS.map(([key,label])=>`<button class="chair-stat" type="button" data-filter="${key}" aria-pressed="${filter===key}"><span>${label}</span><strong>${papers.filter(p=>matches(p,key)).length}</strong></button>`).join('');
  const accepted=papers.filter(p=>p.status==='accepted');
  const sessionCounts=['oral_1','oral_2','oral_3','poster_1'].map(key=>`${key.replace('oral_','Oral ').replace('poster_','Poster ')}: ${accepted.filter(p=>p.assigned_session===key).length}편`);
  $('#chair-program-stats').innerHTML=`<p class="chair-prose">구두 채택 ${accepted.filter(p=>p.final_presentation==='oral').length}편 / 최소 20편 목표 · 포스터 채택 ${accepted.filter(p=>p.final_presentation==='poster').length}편 / 최소 30편 목표<br>${sessionCounts.join(' · ')}</p><ul class="chair-author-list">${Object.entries(TRACKS).filter(([key])=>papers.some(p=>p.track===key)).map(([key,label])=>`<li>${label} · 접수 ${papers.filter(p=>p.track===key).length}편 / 채택 ${accepted.filter(p=>p.track===key).length}편</li>`).join('')}</ul>`;
  const list=papers.filter(p=>matches(p,filter) && (track==='all'||p.track===track) && (!search || [p.id,p.title,...p.paper_authors.flatMap(a=>[a.full_name,a.affiliation])].join(' ').toLocaleLowerCase().includes(search)));
  $('#chair-count').textContent=`${list.length}편 표시 · 전체 접수 ${papers.length}편 · 작성 중인 초안 제외`;
  $('#chair-empty').hidden=list.length>0;$('#chair-table').hidden=list.length===0;
  $('#chair-empty').textContent=papers.length?'검색 조건에 맞는 원고가 없습니다. 검색어 또는 필터를 변경해 주세요.':'접수된 원고가 없습니다. 저자가 제출을 완료하면 여기에 표시됩니다.';
  $('#chair-rows').innerHTML=list.map(p=>{
    const authors=[...p.paper_authors].sort((a,b)=>a.sort_order-b.sort_order), reviews=activeReviews(p), done=reviews.filter(r=>r.review_state==='submitted').length;
    const final=p.status==='accepted'?(latestFinal(p)?finalConfirmed(p)?'최종본 확인 완료':'최종본 확인 대기':'최종본 미제출'):'';
    return `<tr><td data-label="원고"><small>${esc(p.id.slice(0,8).toUpperCase())} · ${esc(TRACKS[p.track]||p.track)}</small><strong>${esc(p.title)}</strong></td><td data-label="대표저자 / 제출">${esc(authors[0]?.full_name||p.contact_name)}<small>${esc(authors[0]?.affiliation||'')}</small><small>${esc(date(p.submitted_at))}</small></td><td data-label="심사위원 / 진행">${reviews.length?reviews.map(r=>esc(memberName(r.reviewer_id))).join('<br>'):'미배정'}<small>${done}/${reviews.length} 심사 완료${complete(p)?' · 판정 가능':''}</small></td><td data-label="판정 / 최종본">${badge(p.status)}<small>${final}</small></td><td><button class="chair-open" type="button" data-open="${p.id}" aria-label="${esc(p.title)} 관리">관리 →</button></td></tr>`;
  }).join('');
}
function reviewerOptions() {
  const p=selected();if(!p)return;
  const q=$('#chair-reviewer-search').value.trim().toLocaleLowerCase();
  const authorEmails=new Set(p.paper_authors.map(a=>a.email?.trim().toLowerCase()));
  const assigned=new Set(currentReviews(p).map(r=>r.reviewer_id));
  const prior=$('#chair-reviewer').value;
  const available=members.filter(m=>m.user_id!==p.owner_id && !authorEmails.has(m.email?.trim().toLowerCase()) && !assigned.has(m.user_id) && (!q||`${m.full_name} ${m.email} ${m.affiliation}`.toLocaleLowerCase().includes(q)));
  $('#chair-reviewer').innerHTML='<option value="">심사위원을 선택하세요</option>'+available.map(m=>{
    const count=papers.filter(paper=>['submitted','under_review'].includes(paper.status)).flatMap(activeReviews).filter(r=>r.reviewer_id===m.user_id && r.review_state!=='submitted').length;
    return `<option value="${m.user_id}">${esc(m.full_name||m.email)} · ${esc(m.affiliation||'소속 미입력')} · 진행 ${count}편</option>`;
  }).join('');
  if(available.some(m=>m.user_id===prior))$('#chair-reviewer').value=prior;
  reviewerInfo();
}
function reviewerInfo() {const m=membersById.get($('#chair-reviewer').value);$('#chair-reviewer-info').textContent=m?`${m.email||''} · 전문 분야: ${(m.expertise_tracks||[]).map(t=>TRACKS[t]||t).join(', ')||'미입력'}`:'검색 후 가입 회원을 선택하세요.';}
function renderReviews(p) {
  const ordered=[...p.reviews].sort((a,b)=>new Date(b.assigned_at)-new Date(a.assigned_at));
  $('#chair-review-progress').textContent=`현재 제출본 ${activeReviews(p).filter(r=>r.review_state==='submitted').length}/${activeReviews(p).length} 완료`;
  $('#chair-reviews').innerHTML=ordered.map(r=>{
    const current=sameTime(r.manuscript_submitted_at,p.submitted_at), m=membersById.get(r.reviewer_id);
    const state=r.revoked_at?'배정 철회':REVIEW[r.review_state];
    return `<article class="chair-review ${current&&!r.revoked_at?'':'history'}"><header><strong>${esc(memberName(r.reviewer_id))}</strong><span class="chair-badge">${current?'현재 제출본':'이전 제출본'} · ${esc(state)}</span></header><p>${esc(m?.affiliation||'')} · ${esc((m?.expertise_tracks||[]).map(t=>TRACKS[t]||t).join(', ')||'전문 분야 미입력')}</p>${r.review_state==='submitted'?`<strong>${esc(RECOMMENDATION[r.recommendation])}</strong><p class="chair-prose">${esc(r.comments)}</p><small>${esc(date(r.submitted_at))}</small>`:r.review_state==='declined'?`<p>거절 사유: ${esc(r.decline_reason)}</p>`:'<p>제출된 심사 의견이 없습니다.</p>'}${r.revoked_at?`<p>교체 사유: ${esc(r.revocation_reason)}</p>`:''}</article>`;
  }).join('')||'<p class="operations-meta">배정된 심사위원이 없습니다.</p>';
  $('#chair-assignment-form').hidden=!['submitted','under_review'].includes(p.status);
  $('#chair-replace').innerHTML='<option value="">추가 배정</option>'+currentReviews(p).filter(r=>!r.revoked_at).map(r=>`<option value="${r.id}">${esc(memberName(r.reviewer_id))} 배정 교체${r.review_state==='declined'?' (거절)':''}</option>`).join('');
  $('#chair-replace-reason').value='';$('#chair-replace-reason').required=false;$('#chair-replace-reason-label').hidden=true;
  $('#chair-reviewer-search').value='';reviewerOptions();
}
function renderDecision(p) {
  $('#desk-decision').value=['accepted','rejected','revision'].includes(p.status)?p.status:'';
  $('#desk-presentation').value=p.final_presentation||'';$('#desk-session').value=p.assigned_session||'';
  $('#desk-note').value=p.decision_note||'';$('#desk-exception').value='';
  $('#chair-exception-panel').hidden=complete(p);$('#desk-exception').required=!complete(p);
  $('#chair-accepted-fields').hidden=p.status!=='accepted';
  $('#chair-decision-current').textContent=p.decision_published_at?`최근 공개 ${date(p.decision_published_at)} · ${memberName(p.decided_by)}`:'아직 공개한 판정이 없습니다.';
}
function renderFiles(p) {
  $('#chair-files').innerHTML=[...p.paper_files].sort((a,b)=>b.version-a.version).map(f=>`<div class="chair-file"><div><strong>${f.file_stage==='final'?'최종본':'심사용 원고'} v${f.version}</strong><small>${esc(f.original_name)} · ${esc(date(f.created_at))}</small></div><button type="button" class="chair-open" data-file="${f.id}">PDF 열기 ↗</button></div>`).join('')||'<p>제출된 PDF가 없습니다.</p>';
  const final=latestFinal(p),check=finalCheck(p);
  $('#chair-final-status').textContent=p.status!=='accepted'?'채택 후 최종본을 확인할 수 있습니다.':!final?'아직 최종본이 제출되지 않았습니다.':finalConfirmed(p)?`최종본 v${final.version} 확인 완료 · ${memberName(check.checked_by)} · ${date(check.checked_at)}`:`최종본 v${final.version} 확인 대기${check?' · 이전 버전 확인 기록은 보존됩니다.':''}`;
  $('#chair-final-form').hidden=p.status!=='accepted'||!final||finalConfirmed(p);$('#chair-final-confirm').checked=false;
}
function eventDetail(event) {
  const a=event.after_data||{}, b=event.before_data||{};
  if(event.action==='decision_published')return `${STATUS[b.status]||b.status} → ${STATUS[a.status]||a.status}\n${a.note||''}${a.exception_reason?'\n예외 사유: '+a.exception_reason:''}${a.session?'\n세션: '+a.session:''}`;
  if(event.action.startsWith('review_'))return `${memberName(a.reviewer_id)} · ${RECOMMENDATION[a.recommendation]||REVIEW[a.review_state]||''}\n${a.revocation_reason||a.decline_reason||a.comments||''}`;
  if(event.action==='file_uploaded')return `${a.stage==='final'?'최종본':'심사용 원고'} v${a.version} · ${a.name}`;
  if(event.action==='final_checked') { const f=selected()?.paper_files.find(f=>f.id===a.file_id);return f?`최종본 v${f.version} 확인`:'최종본 확인'; }
  return `${STATUS[b.status]||b.status||''} → ${STATUS[a.status]||a.status||''}`;
}
async function openPaper(id,focus=true) {
  selectedId=id;const p=selected();if(!p)throw Error('원고를 찾을 수 없습니다. 목록을 새로고침해 주세요.');
  const request=++detailRequest;
  $('#chair-overview').hidden=true;$('#chair-detail').hidden=false;
  $('#chair-paper-number').textContent=`${p.id.slice(0,8).toUpperCase()} / ${TRACKS[p.track]||p.track}`;
  $('#chair-paper-title').textContent=p.title;$('#chair-paper-badges').innerHTML=badge(p.status)+`<span class="chair-badge">제출 ${esc(date(p.submitted_at))}</span>`;
  $('#chair-paper-abstract').textContent=p.abstract;
  $('#chair-paper-authors').innerHTML='<ol class="chair-author-list">'+[...p.paper_authors].sort((a,b)=>a.sort_order-b.sort_order).map(a=>`<li><strong>${esc(a.full_name)}</strong> · ${esc(a.affiliation)}<br><span>${esc(a.email)}${a.note?' · '+esc(a.note):''}</span></li>`).join('')+'</ol>';
  $('#chair-contact').textContent=`연락 담당자: ${p.contact_name} · ${p.contact_email}`;
  renderReviews(p);renderDecision(p);renderFiles(p);$('#chair-events').innerHTML='<li>처리 이력을 불러오고 있습니다.</li>';
  if(focus)$('#chair-paper-title').focus();
  const events=await allRows(()=>client.from('paper_events').select('*').eq('paper_id',id).order('created_at',{ascending:false}).order('id'));
  if(request!==detailRequest)return;
  $('#chair-events').innerHTML=events.map(e=>`<li><strong>${esc(ACTION[e.action]||e.action)}</strong><time datetime="${esc(e.created_at)}">${esc(date(e.created_at))} · ${esc(e.actor_label)}</time><p>${esc(eventDetail(e))}</p></li>`).join('')||'<li>아직 기록된 처리 이력이 없습니다.</li>';
}
async function run(action) {
  if(busy)return;busy=true;document.querySelectorAll('[data-chair-write],#chair-refresh').forEach(b=>b.disabled=true);
  try {await action();}catch(error){if ($('#chair-publish-dialog').open) $('#chair-publish-dialog').close();notice(friendly(error),true);$('#chair-message').scrollIntoView({block:'center',behavior:'smooth'});}
  finally {busy=false;document.querySelectorAll('[data-chair-write],#chair-refresh').forEach(b=>b.disabled=false);}
}
async function reloadDetail() {await load();if(selectedId)await openPaper(selectedId,false);}
$('#chair-login').addEventListener('click',()=>{try { sessionStorage.setItem('co_rnbd_return_to','chair'); } catch { /* Fixed login query is the fallback. */ }});
$('#chair-search').addEventListener('input',renderList);
$('#chair-status-filter').addEventListener('change',renderList);
$('#chair-track-filter').addEventListener('change',renderList);
$('#chair-reviewer-search').addEventListener('input',reviewerOptions);
$('#chair-reviewer').addEventListener('change',reviewerInfo);
$('#chair-replace').addEventListener('change',()=>{const replacing=Boolean($('#chair-replace').value);$('#chair-replace-reason-label').hidden=!replacing;$('#chair-replace-reason').required=replacing;});
$('#chair-back').addEventListener('click',()=>{selectedId=null;detailRequest++;$('#chair-detail').hidden=true;$('#chair-overview').hidden=false;$('#chair-search').focus();});
$('#chair-refresh').addEventListener('click',()=>run(async()=>{await reloadDetail();notice('최신 원고 목록을 불러왔습니다.');}));
$('#chair-stats').addEventListener('click',event=>{const el=event.target.closest('[data-filter]');if(el){$('#chair-status-filter').value=el.dataset.filter;renderList();}});
$('#chair-rows').addEventListener('click',event=>{const el=event.target.closest('[data-open]');if(el)run(()=>openPaper(el.dataset.open));});
$('#chair-files').addEventListener('click',event=>{const el=event.target.closest('[data-file]');if(!el)return;run(async()=>{const file=selected()?.paper_files.find(f=>f.id===el.dataset.file);if(!file)throw Error('파일을 찾을 수 없습니다.');const link=data(await client.storage.from('paper-pdfs').createSignedUrl(file.storage_path,60));window.open(link.signedUrl,'_blank','noopener,noreferrer');});});
$('#chair-assignment-form').addEventListener('submit',event=>{event.preventDefault();run(async()=>{data(await client.rpc('chair_assign_reviewer',{p_paper_id:selectedId,p_reviewer_id:$('#chair-reviewer').value,p_replace_review_id:$('#chair-replace').value||null,p_reason:$('#chair-replace-reason').value.trim()}));await reloadDetail();notice('심사위원 배정과 원고 상태를 저장했습니다. 처리 이력에 기록되었습니다.');});});
$('#desk-decision').addEventListener('change',()=>{$('#chair-accepted-fields').hidden=$('#desk-decision').value!=='accepted';});
$('#desk-session').addEventListener('change',()=>{const value=$('#desk-session').value;if(value)$('#desk-presentation').value=value.startsWith('oral')?'oral':'poster';});
$('#desk-presentation').addEventListener('change',()=>{const value=$('#desk-presentation').value,s=$('#desk-session').value;if((s.startsWith('oral')&&value!=='oral')||(s==='poster_1'&&value!=='poster'))$('#desk-session').value='';});
$('#chair-decision-form').addEventListener('submit',event=>{
  event.preventDefault();if(busy)return;const p=selected(),accepted=$('#desk-decision').value==='accepted';
  pendingDecision={p_paper_id:p.id,p_status:$('#desk-decision').value,p_note:$('#desk-note').value.trim(),p_presentation:accepted?$('#desk-presentation').value||null:null,p_session:accepted?$('#desk-session').value||null:null,p_exception_reason:complete(p)?'':$('#desk-exception').value.trim(),p_expected_updated_at:p.updated_at};
  $('#chair-publish-paper').textContent=p.title;$('#chair-publish-status').textContent=STATUS[pendingDecision.p_status];$('#chair-publish-note').textContent=pendingDecision.p_note;$('#chair-publish-exception').textContent=pendingDecision.p_exception_reason?'예외 사유: '+pendingDecision.p_exception_reason:'';$('#chair-publish-dialog').showModal();
});
$('#chair-publish-cancel').addEventListener('click',()=>{$('#chair-publish-dialog').close();pendingDecision=null;});
$('#chair-publish-confirm').addEventListener('click',()=>run(async()=>{if(!pendingDecision)return;data(await client.rpc('chair_publish_decision',pendingDecision));pendingDecision=null;$('#chair-publish-dialog').close();await reloadDetail();notice('판정을 확정하고 저자 포털에 공개했습니다. 이메일은 발송하지 않았습니다.');}));
$('#chair-final-form').addEventListener('submit',event=>{event.preventDefault();run(async()=>{const p=selected(),file=latestFinal(p);data(await client.from('paper_final_checks').upsert({paper_id:p.id,file_id:file.id,checked_by:user.id},{onConflict:'paper_id'}).select('paper_id').single());await reloadDetail();notice(`최종본 v${file.version} 확인 완료를 기록했습니다.`);});});
async function start() {
  try {
    client=await conferenceClient();const auth=await client.auth.getUser();
    if(auth.error&&!/Auth session missing/i.test(auth.error.message))throw auth.error;
    user=auth.data?.user;
    if(!user){$('#chair-access').hidden=false;notice('위원장 계정으로 로그인해 주세요.');return;}
    const role=data(await client.from('staff_roles').select('role,is_super_admin').eq('user_id',user.id).maybeSingle());
    if(role?.role!=='chair'){$('#chair-access').hidden=false;$('#chair-access-text').textContent='현재 계정에는 위원장 권한이 없습니다. 투고·심사 화면에서 계정을 확인해 주세요.';$('#chair-login').textContent='계정 확인';notice('위원장 계정만 원고 심사 관리를 이용할 수 있습니다.',true);return;}
    client.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(event==='SIGNED_IN'&&session?.user?.id!==user.id)){papers=[];members=[];membersById.clear();$('#chair-workspace').hidden=true;location.reload();}});
    edition=await currentEdition(client);document.title=`원고 심사 관리 | ${edition.title}`;$('#chair-edition').textContent=`CO-R&BD ${edition.year} / CHAIR DESK`;
    $('#chair-monitor').hidden=!role.is_super_admin;
    $('#chair-track-filter').innerHTML='<option value="all">전체 분야</option>'+Object.entries(TRACKS).map(([value,label])=>`<option value="${value}">${label}</option>`).join('');
    await load();$('#chair-workspace').hidden=false;notice('현재 회차의 접수 원고를 불러왔습니다. 원고를 선택해 배정·판정을 진행하세요.');
  }catch(error){notice(friendly(error),true);}
}
start();
