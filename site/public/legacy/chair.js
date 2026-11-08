import { conferenceClient, currentEdition, escapeHtml as esc, requireData as data } from './conference-client.js';

const $ = (selector) => document.querySelector(selector);
const TRACKS = { master_eng:'전문기술석사 (공학 분야)',master_sci:'전문기술석사 (자연과학 분야)',industry_joint:'산학공동기술개발과제',convergence_etc:'기타 산학융합과제',applied:'전문기술석사 응용연구',industry:'산학공동기술개발과제 성과발표',convergence:'산업융합기술',education:'T-VET 정책·교육연구' };
const STATUS = {submitted:'제출 완료',under_review:'심사 중',revision:'수정 요청',accepted:'채택',rejected:'반려'};
const REVIEW = {assigned:'심사 대기',draft:'임시저장',submitted:'심사 제출',declined:'배정 거절'};
const RECOMMENDATION = {accept:'Accept · 채택 권고',revise:'Accept after revision · 수정 후 채택 권고',reject:'Reject · 반려 권고'};
const ACTION = {paper_submitted:'원고 제출',paper_status_changed:'진행 상태 변경',review_assigned:'심사위원 배정',review_revoked:'심사 배정 철회',review_submitted:'심사 의견 제출',review_declined:'심사 배정 거절',decision_published:'판정 확정·공개',file_uploaded:'PDF 업로드',final_checked:'최종본 확인 완료'};
const REQUIRED_REVIEWERS = 2;
const FILTERS = [['all','전체 접수'],['unassigned','배정 필요'],['reviewing','심사 중'],['ready','판정 대기'],['revision','수정 요청'],['accepted','채택'],['rejected','반려'],['final_pending','최종본 확인 대기']];
const dateFormatter = new Intl.DateTimeFormat('ko-KR',{timeZone:'Asia/Seoul',dateStyle:'short',timeStyle:'short'});
const date = (value) => value ? dateFormatter.format(new Date(value))+' KST' : '—';
const sameTime = (a,b) => Boolean(a && b) && new Date(a).getTime()===new Date(b).getTime();
let client, user, edition, selectedId, selectedPaper, pendingDecision;
let isChief=false, committee=[];
let papers=[], members=[], membersById=new Map(), busy=false;
let detailRequest=0;
let priorityFilter='all', countTimer;
const selected = () => selectedPaper;
const OVERVIEW_COLUMNS = 'id,owner_id,title,track,status,submitted_at,contact_name,final_presentation,assigned_session,paper_authors(full_name,affiliation,email,sort_order),reviews(reviewer_id,review_state,revoked_at,manuscript_submitted_at),paper_files(id,version,file_stage),paper_final_checks(file_id)';
const editorTracks = () => new Set(committee.filter(c=>c.active && c.committee_role==='associate_editor' && c.email===user.email?.toLowerCase()).map(c=>c.track));
// General RLS also grants author/reviewer reads; the editorial desk has its own scope.
const editorialPaper = p => isChief || (editorTracks().has(p.track) && p.owner_id!==user.id
  && !(p.paper_authors||[]).some(a=>a.email?.trim().toLowerCase()===user.email?.toLowerCase())
  && !(p.reviews||[]).some(r=>r.reviewer_id===user.id && r.review_state==='declined'));
const currentReviews = (p) => (p.reviews||[]).filter(r=>sameTime(r.manuscript_submitted_at,p.submitted_at));
const activeReviews = (p) => currentReviews(p).filter(r=>!r.revoked_at && r.review_state!=='declined');
const panelReady = (p) => Boolean(p) && activeReviews(p).length===REQUIRED_REVIEWERS;
const complete = (p) => panelReady(p) && activeReviews(p).every(r=>r.review_state==='submitted');
const latestFinal = (p) => (p.paper_files||[]).filter(f=>f.file_stage==='final').sort((a,b)=>b.version-a.version)[0];
const finalCheck = (p) => Array.isArray(p.paper_final_checks) ? p.paper_final_checks[0] : p.paper_final_checks;
const finalConfirmed = (p) => Boolean(latestFinal(p) && finalCheck(p)?.file_id===latestFinal(p).id);
const memberName = (id) => membersById.get(id)?.full_name || membersById.get(id)?.email || '회원';
const badge = (status) => `<span class="chair-badge ${esc(status)}">${esc(STATUS[status]||status)}</span>`;
function notice(text,error=false) { const el=$('#chair-message');el.textContent=text;el.classList.toggle('error',error);el.setAttribute('role',error?'alert':'status'); }
function friendly(error) {
  const text=error?.message||'처리하지 못했습니다. 다시 시도해 주세요.';
  if (/Exactly two active reviewers/.test(text)) return '현재 제출본에 심사위원 2명을 배정해야 판정할 수 있습니다. 거절·철회된 배정은 제외됩니다.';
  const messages=[[/Active field reviewer membership required/,'해당 분야 명부의 활성 심사위원만 배정할 수 있습니다. 분야별 위원 구성을 확인해 주세요.'],[/Editors require two completed reviews/,'AE는 현재 제출본의 심사 2건이 모두 완료된 뒤 판정할 수 있습니다.'],[/Editors may change decision fields only/,'AE는 담당 분야 원고의 판정만 변경할 수 있습니다.'],[/duplicate key|reviews_manuscript_reviewer_key/,'이미 이 제출본에 배정된 심사위원입니다.'],[/Reviewer is an author/,'저자·공동저자는 심사위원으로 배정할 수 없습니다.'],[/At most two/,'유효 심사위원은 최대 2명입니다. 기존 배정을 교체해 주세요.'],[/Incomplete reviews/,'미완료 심사에 대한 예외 판정 사유를 5자 이상 입력해 주세요.'],[/Reviews changed|Review snapshot required/,'심사 내용이 변경됐거나 화면이 오래되었습니다. 새로고침 후 최신 심사 의견을 확인해 주세요.'],[/Paper changed|Assignment changed/,'다른 작업으로 원고가 변경됐습니다. 새로고침 후 다시 확인해 주세요.'],[/latest final PDF/,'더 최신인 최종본이 있습니다. 새로고침 후 확인해 주세요.'],[/Chair permission|required.*permission|row-level security/,'이 작업에 필요한 위원장 권한을 확인해 주세요.'],[/Remove the paper from its session/,'프로그램에 편성된 원고입니다. 운영 관리에서 편성을 해제한 뒤 판정·발표 형태를 변경해 주세요.']];
  return messages.find(([pattern])=>pattern.test(text))?.[1]||text;
}
async function allRows(factory) {
  const rows=[];
  for(let offset=0;;offset+=300) { const part=data(await factory().range(offset,offset+299));rows.push(...part);if(part.length<300)return rows; }
}
async function load() {
  committee=await allRows(()=>client.from('review_committee').select('*').eq('edition_year',edition.year).order('track').order('display_name'));
  const tracks=editorTracks();
  if(!isChief&&!tracks.size){papers=[];selectedId=null;selectedPaper=null;$('#chair-workspace').hidden=true;$('#chair-access').hidden=false;throw Error('활성 분야별 편집위원장 권한을 확인해 주세요.');}
  const priorTrack=$('#chair-track-filter').value;
  $('#chair-track-filter').innerHTML='<option value="all">전체 분야</option>'+Object.entries(TRACKS).filter(([key])=>isChief||tracks.has(key)).map(([key,label])=>`<option value="${key}">${label}</option>`).join('');
  $('#chair-track-filter').value=isChief||tracks.has(priorTrack)?priorTrack:'all';
  const [list,profiles]=await Promise.all([
    allRows(()=>{const query=client.from('papers').select(OVERVIEW_COLUMNS).eq('edition_year',edition.year).neq('status','draft').not('submitted_at','is',null).order('id');return isChief?query:query.in('track',[...tracks]).neq('owner_id',user.id);}),
    allRows(()=>client.from('profiles').select('user_id,full_name,email,affiliation,expertise_tracks').order('user_id')),
  ]);
  const roster=committee;
  for(const c of roster)if(c.user_id&&!profiles.some(p=>p.user_id===c.user_id))profiles.push({user_id:c.user_id,full_name:c.display_name,email:c.email,expertise_tracks:roster.filter(row=>row.user_id===c.user_id&&row.active).map(row=>row.track)});
  renderCommittee();
  papers=list.filter(editorialPaper).sort((a,b)=>new Date(b.submitted_at)-new Date(a.submitted_at));members=profiles;membersById=new Map(profiles.map(p=>[p.user_id,p]));renderList();
}
function renderCommittee() {
  $('#committee-list').innerHTML=committee.map(c=>`<article class="chair-review"><strong>${esc(c.display_name)}</strong><p>${esc(TRACKS[c.track])} · ${c.committee_role==='associate_editor'?'편집위원장 (AE)':'심사위원'}<br>${esc(c.email)} · ${c.active?'활성':'비활성'} · ${c.user_id?'계정 연결 완료':'계정 연결 대기'}</p>${isChief?`<button type="button" class="operations-button secondary" data-committee-toggle="${c.id}" data-chair-write>${c.active?'역할 비활성화':'역할 활성화'}</button>`:''}</article>`).join('')||'<p>등록된 분야별 위원이 없습니다.</p>';
}
function matches(p,status) {
  const pending=['submitted','under_review'].includes(p.status);
  if(status==='all')return true;
  if(status==='unassigned')return pending && activeReviews(p).length<REQUIRED_REVIEWERS;
  if(status==='reviewing')return pending && panelReady(p) && !complete(p);
  if(status==='ready')return pending && complete(p);
  if(status==='final_pending')return p.status==='accepted' && latestFinal(p) && !finalConfirmed(p);
  return p.status===status;
}
function renderList() {
  const filter=$('#chair-status-filter').value, track=$('#chair-track-filter').value, search=$('#chair-search').value.trim().toLocaleLowerCase();
  const scoped=papers.filter(p=>track==='all'||p.track===track);
  if(!$('#chair-stats').children.length)$('#chair-stats').innerHTML=FILTERS.map(([key,label])=>`<button class="chair-stat" type="button" data-filter="${key}" aria-pressed="false"><span>${label}</span><strong>0</strong><small>원고 보기 <span aria-hidden="true">↗</span></small></button>`).join('');
  for(const [key] of FILTERS){const button=$(`[data-filter="${key}"]`);button.setAttribute('aria-pressed',String(filter===key));button.querySelector('strong').textContent=scoped.filter(p=>matches(p,key)).length;}
  const unassigned=scoped.filter(p=>matches(p,'unassigned')).length, ready=scoped.filter(p=>matches(p,'ready')).length, reviewing=scoped.filter(p=>matches(p,'reviewing')).length, finals=scoped.filter(p=>matches(p,'final_pending')).length;
  priorityFilter=isChief&&unassigned?'unassigned':ready?'ready':isChief&&finals?'final_pending':reviewing?'reviewing':unassigned?'unassigned':'all';
  $('#chair-priority-text').textContent=priorityFilter==='unassigned'?(isChief?`${unassigned}편에 심사위원 배정이 필요합니다. 현재 제출본마다 2명을 구성해 주세요.`:`${unassigned}편이 심사위원 배정을 기다리고 있습니다. 심사위원장 배정 후 심사가 진행됩니다.`):priorityFilter==='ready'?`${ready}편의 2인 심사가 완료되었습니다. 의견을 검토하고 판정해 주세요.`:priorityFilter==='final_pending'?`${finals}편의 최신 최종 PDF가 확인을 기다리고 있습니다.`:priorityFilter==='reviewing'?`${reviewing}편의 심사가 진행 중입니다. 현재 제출본의 의견 제출 현황을 확인하세요.`:scoped.length?'공개된 판정과 원고 진행 상태를 확인하세요.':'접수된 원고가 아직 없습니다. 제출이 완료되면 이곳에서 업무를 시작할 수 있습니다.';
  $('#chair-priority-action').textContent=(FILTERS.find(([key])=>key===priorityFilter)?.[1]||'전체 원고')+' 보기 →';
  const accepted=papers.filter(p=>p.status==='accepted');
  const sessionCounts=['oral_1','oral_2','oral_3','poster_1'].map(key=>`${key.replace('oral_','Oral ').replace('poster_','Poster ')}: ${accepted.filter(p=>p.assigned_session===key).length}편`);
  $('#chair-program-stats').innerHTML=`<p class="chair-prose">구두 채택 ${accepted.filter(p=>p.final_presentation==='oral').length}편 / 최소 20편 목표 · 포스터 채택 ${accepted.filter(p=>p.final_presentation==='poster').length}편 / 최소 30편 목표<br>${sessionCounts.join(' · ')}</p><ul class="chair-author-list">${Object.entries(TRACKS).filter(([key])=>papers.some(p=>p.track===key)).map(([key,label])=>`<li>${label} · 접수 ${papers.filter(p=>p.track===key).length}편 / 채택 ${accepted.filter(p=>p.track===key).length}편</li>`).join('')}</ul>`;
  const list=papers.filter(p=>matches(p,filter) && (track==='all'||p.track===track) && (!search || [p.id,p.title,...p.paper_authors.flatMap(a=>[a.full_name,a.affiliation])].join(' ').toLocaleLowerCase().includes(search)));
  clearTimeout(countTimer);countTimer=setTimeout(()=>{$('#chair-count').textContent=`${list.length}편 표시 · 전체 접수 ${papers.length}편 · 작성 중인 초안 제외`;},180);
  $('#chair-empty').hidden=list.length>0;$('#chair-table').hidden=list.length===0;
  $('#chair-empty').textContent=papers.length?'검색 조건에 맞는 원고가 없습니다. 검색어 또는 필터를 변경해 주세요.':'접수된 원고가 없습니다. 저자가 제출을 완료하면 여기에 표시됩니다.';
  $('#chair-rows').innerHTML=list.map(p=>{
    const authors=[...p.paper_authors].sort((a,b)=>a.sort_order-b.sort_order), reviews=activeReviews(p), done=reviews.filter(r=>r.review_state==='submitted').length;
    const final=p.status==='accepted'?(latestFinal(p)?finalConfirmed(p)?'최종본 확인 완료':'최종본 확인 대기':'최종본 미제출'):'';
    return `<tr><td data-label="원고"><small>${esc(p.id.slice(0,8).toUpperCase())} · ${esc(TRACKS[p.track]||p.track)}</small><strong>${esc(p.title)}</strong></td><td data-label="대표저자 / 제출">${esc(authors[0]?.full_name||p.contact_name)}<small>${esc(authors[0]?.affiliation||'')}</small><small>${esc(date(p.submitted_at))}</small></td><td data-label="심사위원 / 진행">${reviews.length?reviews.map(r=>esc(memberName(r.reviewer_id))).join('<br>'):'미배정'}<progress class="review-progress" value="${done}" max="${REQUIRED_REVIEWERS}" aria-label="${esc(p.title)} 심사 제출 ${done}/${REQUIRED_REVIEWERS}명"></progress><small>배정 ${reviews.length}/${REQUIRED_REVIEWERS}명 · 심사 제출 ${done}/${REQUIRED_REVIEWERS}명${['submitted','under_review'].includes(p.status)?complete(p)?' · 판정 가능':!panelReady(p)?' · 추가 배정 필요':'':' · 판정 공개 완료'}</small></td><td data-label="판정 / 최종본">${badge(p.status)}<small>${final}</small></td><td><button class="chair-open" type="button" data-open="${p.id}" aria-label="${esc(p.title)} 관리">관리 →</button></td></tr>`;
  }).join('');
}
function reviewerOptions() {
  const p=selected();if(!p)return;
  const q=$('#chair-reviewer-search').value.trim().toLocaleLowerCase();
  const authorEmails=new Set(p.paper_authors.map(a=>a.email?.trim().toLowerCase()));
  const assigned=new Set(currentReviews(p).map(r=>r.reviewer_id));
  const prior=$('#chair-reviewer').value;
  const fieldCommittee=committee.filter(c=>c.committee_role==='reviewer'&&c.track===p.track);
  const available=members.filter(m=>(!fieldCommittee.length||fieldCommittee.some(c=>c.active&&c.user_id===m.user_id))&&m.user_id!==p.owner_id && !authorEmails.has(m.email?.trim().toLowerCase()) && !assigned.has(m.user_id) && (!q||`${m.full_name} ${m.email} ${m.affiliation}`.toLocaleLowerCase().includes(q)));
  $('#chair-reviewer').innerHTML='<option value="">심사위원을 선택하세요</option>'+available.map(m=>{
    const count=papers.filter(paper=>['submitted','under_review'].includes(paper.status)).flatMap(activeReviews).filter(r=>r.reviewer_id===m.user_id && r.review_state!=='submitted').length;
    return `<option value="${m.user_id}">${esc(fieldCommittee.find(c=>c.user_id===m.user_id&&c.active)?.display_name||m.full_name||m.email)} · ${esc(m.affiliation||'소속 미입력')} · 진행 ${count}편</option>`;
  }).join('');
  if(available.some(m=>m.user_id===prior))$('#chair-reviewer').value=prior;
  reviewerInfo();
}
function reviewerInfo() {const m=membersById.get($('#chair-reviewer').value);$('#chair-reviewer-info').textContent=m?`${m.email||''} · 전문 분야: ${(m.expertise_tracks||[]).map(t=>TRACKS[t]||t).join(', ')||'미입력'}`:'검색 후 가입 회원을 선택하세요.';}
function renderReviews(p) {
  const ordered=[...p.reviews].sort((a,b)=>new Date(b.assigned_at)-new Date(a.assigned_at));
  $('#chair-review-progress').textContent=`배정 ${activeReviews(p).length}/${REQUIRED_REVIEWERS}명 · 심사 제출 ${activeReviews(p).filter(r=>r.review_state==='submitted').length}/${REQUIRED_REVIEWERS}명`;
  $('#chair-assignment-status').textContent=panelReady(p)?'2명 배정 완료. 변경하려면 기존 심사위원을 선택해 교체해 주세요.':`${REQUIRED_REVIEWERS-activeReviews(p).length}명을 추가 배정해 주세요. 거절·철회된 배정은 정원에서 제외됩니다.`;
  $('#chair-reviews').innerHTML=ordered.map(r=>{
    const current=sameTime(r.manuscript_submitted_at,p.submitted_at), m=membersById.get(r.reviewer_id);
    const state=r.revoked_at?'배정 철회':REVIEW[r.review_state];
    return `<article class="chair-review ${current&&!r.revoked_at?'':'history'}"><header><strong>${esc(memberName(r.reviewer_id))}</strong><span class="chair-badge">${current?'현재 제출본':'이전 제출본'} · ${esc(state)}</span></header><p>${esc(m?.affiliation||'')} · ${esc((m?.expertise_tracks||[]).map(t=>TRACKS[t]||t).join(', ')||'전문 분야 미입력')}</p>${r.review_state==='submitted'?`<strong>${esc(RECOMMENDATION[r.recommendation])}</strong><p class="chair-prose">${esc(r.comments)}</p><small>${esc(date(r.submitted_at))}</small>`:r.review_state==='declined'?`<p>거절 사유: ${esc(r.decline_reason)}</p>`:'<p>제출된 심사 의견이 없습니다.</p>'}${r.revoked_at?`<p>교체 사유: ${esc(r.revocation_reason)}</p>`:''}</article>`;
  }).join('')||'<p class="operations-meta">배정된 심사위원이 없습니다.</p>';
  $('#chair-assignment-form').hidden=!isChief||!['submitted','under_review'].includes(p.status);
  $('#chair-replace').required=panelReady(p);
  $('#chair-replace').innerHTML=`<option value=""${panelReady(p)?' disabled':''}>${panelReady(p)?'교체할 배정을 선택하세요':'추가 배정'}</option>`+currentReviews(p).filter(r=>!r.revoked_at && (!panelReady(p)||r.review_state!=='declined')).map(r=>`<option value="${r.id}">${esc(memberName(r.reviewer_id))} 배정 교체${r.review_state==='declined'?' (거절)':''}</option>`).join('');
  $('#chair-replace').value='';
  $('#chair-replace-reason').value='';$('#chair-replace-reason').required=false;$('#chair-replace-reason-label').hidden=true;
  $('#chair-reviewer-search').value='';reviewerOptions();
}
function renderDecision(p) {
  $('#desk-decision').value=['accepted','rejected','revision'].includes(p.status)?p.status:'';
  $('#desk-presentation').value=p.final_presentation||'';$('#desk-session').value=p.assigned_session||'';
  $('#desk-note').value=p.decision_note||'';$('#desk-exception').value='';
  $('#chair-exception-panel').hidden=!isChief||!panelReady(p)||complete(p);$('#desk-exception').required=isChief&&panelReady(p)&&!complete(p);
  $('#chair-decision-requirement').textContent=!panelReady(p)?'판정하려면 현재 제출본의 심사위원 2명을 먼저 구성해 주세요.':complete(p)?'2명의 심사가 모두 제출되었습니다. 의견을 검토하고 판정해 주세요.':(isChief?'2명의 심사 제출을 기다리고 있습니다. 완료 전 예외 판정은 저자에게 공개할 사유를 입력해야 합니다.':'AE는 2명의 심사 제출이 완료된 뒤 저자에게 판정·수정 요청을 공개할 수 있습니다.');
  $('#chair-decision-submit').disabled=busy||!panelReady(p)||(!isChief&&!complete(p));
  $('#chair-accepted-fields').hidden=p.status!=='accepted';
  $('#chair-decision-current').textContent=p.decision_published_at?`최근 공개 ${date(p.decision_published_at)} · ${memberName(p.decided_by)}`:'아직 공개한 판정이 없습니다.';
}
function renderFiles(p) {
  $('#chair-files').innerHTML=[...p.paper_files].sort((a,b)=>b.version-a.version).map(f=>`<div class="chair-file"><div><strong>${f.file_stage==='final'?'최종본':'심사용 원고'} v${f.version}</strong><small>${esc(f.original_name)} · ${esc(date(f.created_at))}</small></div><button type="button" class="chair-open" data-file="${f.id}">PDF 열기 ↗</button></div>`).join('')||'<p>제출된 PDF가 없습니다.</p>';
  const final=latestFinal(p),check=finalCheck(p);
  $('#chair-final-status').textContent=p.status!=='accepted'?'채택 후 최종본을 확인할 수 있습니다.':!final?'아직 최종본이 제출되지 않았습니다.':finalConfirmed(p)?`최종본 v${final.version} 확인 완료 · ${memberName(check.checked_by)} · ${date(check.checked_at)}`:`최종본 v${final.version} 확인 대기${check?' · 이전 버전 확인 기록은 보존됩니다.':''}`;
  $('#chair-final-form').hidden=!isChief||p.status!=='accepted'||!final||finalConfirmed(p);$('#chair-final-confirm').checked=false;
}
function eventDetail(event) {
  const a=event.after_data||{}, b=event.before_data||{};
  if(event.action==='decision_published')return `${STATUS[b.status]||b.status} → ${STATUS[a.status]||a.status}\n${a.note||''}${a.exception_reason?'\n예외 사유: '+a.exception_reason:''}${a.session?'\n세션: '+a.session:''}`;
  if(event.action.startsWith('review_'))return `${memberName(a.reviewer_id)} · ${RECOMMENDATION[a.recommendation]||REVIEW[a.review_state]||''}\n${a.revocation_reason||a.decline_reason||a.comments||''}`;
  if(event.action==='file_uploaded')return `${a.stage==='final'?'최종본':'심사용 원고'} v${a.version} · ${a.name}`;
  if(event.action==='final_checked') { const f=selected()?.paper_files.find(f=>f.id===a.file_id);return f?`최종본 v${f.version} 확인`:'최종본 확인'; }
  return `${STATUS[b.status]||b.status||''} → ${STATUS[a.status]||a.status||''}`;
}
function renderEmailStatus(result) {
  const states={queued:'발송 대기',sending:'발송 처리 중',retry:'자동 재시도 대기',sent:'발송 서비스 접수 완료',failed:'발송 실패 · 운영자 확인 필요',cancelled:'후속 발송 취소',uncertain:'처리 결과 불확실 · 자동 재전송 중지'};
  if(result.error){$('#chair-email-status').textContent='이메일 처리 상태를 불러오지 못했습니다. 새로고침해 주세요.';return;}
  const rows=result.data||[];
  const attention=rows.filter(row=>['failed','uncertain','retry'].includes(row.status)).length;
  const item=row=>`<li><strong>${({reviewer_assignment:'심사 배정 요청',decision:'판정·수정 요청',review_submitted:'심사의견 제출 알림',paper_submitted:'신규 논문 투고 알림',paper_resubmitted:'수정본 재제출 알림',author_submission_receipt:'저자 신규 투고 접수 확인',author_resubmission_receipt:'저자 수정본 접수 확인'})[row.kind]||'이메일 알림'} · ${esc(states[row.status]||row.status)}</strong><br>${esc(row.recipient_email||'인증된 수신 주소 없음')} · ${esc(date(row.sent_at||row.created_at))}<br><small>시도 ${row.attempts}회${!row.enabled&&['queued','retry'].includes(row.status)?' · 자동 발송 설정 대기':''}${row.last_error?' · 처리 코드 '+esc(row.last_error):''}</small></li>`;
  $('#chair-email-status').innerHTML=rows.length?`<p class="operations-meta">최근 기록 ${Math.min(3,rows.length)}건 · 조회된 전체 ${rows.length}건${attention ? ` · 확인 필요 ${attention}건` : ''}</p><ul class="chair-author-list chair-mail-list">${rows.slice(0,3).map(item).join('')}</ul>${rows.length>3?`<details class="chair-mail-history"${attention ? ' open' : ''}><summary>이전 알림 ${rows.length-3}건 펼치기</summary><ul class="chair-author-list chair-mail-list">${rows.slice(3).map(item).join('')}</ul></details>`:''}`:'아직 이메일 알림 내역이 없습니다.';
}
async function openPaper(id,focus=true) {
  selectedId=id;selectedPaper=null;pendingDecision=null;
  const request=++detailRequest;
  $('#chair-detail').hidden=true;
  notice('원고와 최신 심사 의견을 불러오고 있습니다.');
  let p, events;
  try {
    const [paperResult, history, mailResult]=await Promise.all([
      client.from('papers').select('*,paper_authors(*),reviews(*),paper_files(*),paper_final_checks(*)').eq('id',id).eq('edition_year',edition.year).neq('status','draft').not('submitted_at','is',null).single(),
      allRows(()=>client.from('paper_events').select('*').eq('paper_id',id).order('created_at',{ascending:false}).order('id')),
      client.rpc('review_email_status',{p_id:id}),
    ]);
    p=data(paperResult);events=history;
    if(!editorialPaper(p))throw Error('담당 분야의 이해관계가 없는 원고만 편집 화면에서 처리할 수 있습니다. 개인 심사 배정은 내 투고·심사에서 확인해 주세요.');
    renderEmailStatus(mailResult);
  } catch(error) {
    if(request!==detailRequest)return;
    selectedId=null;$('#chair-overview').hidden=false;
    throw error;
  }
  if(request!==detailRequest)return;
  selectedPaper=p;
  papers=papers.map(paper=>paper.id===id?p:paper);renderList();
  $('#chair-overview').hidden=true;$('#chair-detail').hidden=false;
  $('#chair-paper-number').textContent=`${p.id.slice(0,8).toUpperCase()} / ${TRACKS[p.track]||p.track}`;
  $('#chair-paper-title').textContent=p.title;$('#chair-paper-badges').innerHTML=badge(p.status)+`<span class="chair-badge">제출 ${esc(date(p.submitted_at))}</span>`;
  $('#chair-next-step').textContent=p.status==='revision'?'다음 단계 · 저자의 수정본 재제출 대기. 재제출 후 새 심사 배정으로 이어집니다.':p.status==='accepted'?'다음 단계 · 채택 원고의 최종본 제출·발표 편성을 확인하세요.':p.status==='rejected'?'판정 공개 완료 · 저자에게 판정과 심사의견이 공개되었습니다.':complete(p)?'다음 단계 · 2인의 심사의견을 검토하고 판정·수정 요청을 공개하세요.':!panelReady(p)?(isChief?'다음 단계 · 현재 제출본에 심사위원 2명을 배정하세요.':'다음 단계 · 심사위원장 배정과 2인의 심사 완료를 기다리고 있습니다.'):'다음 단계 · 2인의 심사 제출 대기. 최신 의견을 불러와 진행 상태를 확인하세요.';
  $('#chair-paper-abstract').textContent=p.abstract;
  $('#chair-paper-authors').innerHTML='<ol class="chair-author-list">'+[...p.paper_authors].sort((a,b)=>a.sort_order-b.sort_order).map(a=>`<li><strong>${esc(a.full_name)}</strong> · ${esc(a.affiliation)}<br><span>${esc(a.email)}${a.note?' · '+esc(a.note):''}</span></li>`).join('')+'</ol>';
  $('#chair-contact').textContent=`연락 담당자: ${p.contact_name} · ${p.contact_email}`;
  renderReviews(p);renderDecision(p);renderFiles(p);
  if(focus)$('#chair-paper-title').focus();
  $('#chair-events').innerHTML=events.map(e=>`<li><strong>${esc(ACTION[e.action]||e.action)}</strong><time datetime="${esc(e.created_at)}">${esc(date(e.created_at))} · ${esc(e.actor_label)}</time><p>${esc(eventDetail(e))}</p></li>`).join('')||'<li>아직 기록된 처리 이력이 없습니다.</li>';
  notice('최신 원고와 심사 의견을 불러왔습니다.');
}
async function run(action) {
  if(busy)return;busy=true;document.querySelectorAll('[data-chair-write],#chair-refresh,#chair-detail-refresh').forEach(b=>b.disabled=true);
  try {await action();}catch(error){if ($('#chair-publish-dialog').open) $('#chair-publish-dialog').close();notice(friendly(error),true);$('#chair-message').scrollIntoView({block:'center',behavior:'smooth'});}
  finally {busy=false;document.querySelectorAll('[data-chair-write],#chair-refresh,#chair-detail-refresh').forEach(b=>b.disabled=false);$('#chair-decision-submit').disabled=!panelReady(selected())||(!isChief&&!complete(selected()));}
}
async function reloadDetail() {await load();if(selectedId)await openPaper(selectedId,false);}
$('#chair-login').addEventListener('click',()=>{try { sessionStorage.setItem('co_rnbd_return_to','chair'); } catch { /* Fixed login query is the fallback. */ }});
$('#chair-search').addEventListener('input',renderList);
$('#chair-status-filter').addEventListener('change',renderList);
$('#chair-track-filter').addEventListener('change',renderList);
$('#chair-reviewer-search').addEventListener('input',reviewerOptions);
$('#chair-reviewer').addEventListener('change',reviewerInfo);
$('#chair-replace').addEventListener('change',()=>{const replacing=Boolean($('#chair-replace').value);$('#chair-replace-reason-label').hidden=!replacing;$('#chair-replace-reason').required=replacing;});
$('#chair-back').addEventListener('click',()=>{const previous=selectedId;selectedId=null;selectedPaper=null;detailRequest++;$('#chair-detail').hidden=true;$('#chair-overview').hidden=false;($(`[data-open="${previous}"]`)||$('#chair-search')).focus();});
$('#chair-reset-filters').addEventListener('click',()=>{$('#chair-search').value='';$('#chair-status-filter').value='all';$('#chair-track-filter').value='all';renderList();$('#chair-search').focus();});
$('#chair-priority-action').addEventListener('click',()=>{$('#chair-search').value='';$('#chair-status-filter').value=priorityFilter;renderList();$('#chair-search').focus();});
document.querySelectorAll('#chair-refresh,#chair-detail-refresh').forEach(button=>button.addEventListener('click',()=>run(async()=>{await reloadDetail();notice('최신 원고와 심사 의견을 불러왔습니다.');})));
$('#chair-stats').addEventListener('click',event=>{const el=event.target.closest('[data-filter]');if(el){$('#chair-status-filter').value=el.dataset.filter;renderList();}});
$('#chair-rows').addEventListener('click',event=>{const el=event.target.closest('[data-open]');if(el)run(()=>openPaper(el.dataset.open));});
$('#chair-files').addEventListener('click',event=>{const el=event.target.closest('[data-file]');if(!el)return;run(async()=>{const file=selected()?.paper_files.find(f=>f.id===el.dataset.file);if(!file)throw Error('파일을 찾을 수 없습니다.');const link=data(await client.storage.from('paper-pdfs').createSignedUrl(file.storage_path,60));window.open(link.signedUrl,'_blank','noopener,noreferrer');});});
$('#chair-assignment-form').addEventListener('submit',event=>{event.preventDefault();run(async()=>{data(await client.rpc('chair_assign_reviewer',{p_paper_id:selectedId,p_reviewer_id:$('#chair-reviewer').value,p_replace_review_id:$('#chair-replace').value||null,p_reason:$('#chair-replace-reason').value.trim()}));await reloadDetail();notice('심사위원 배정과 원고 상태를 저장했습니다. 이메일 알림 처리 상태를 확인해 주세요.');});});
$('#desk-decision').addEventListener('change',()=>{$('#chair-accepted-fields').hidden=$('#desk-decision').value!=='accepted';});
$('#desk-session').addEventListener('change',()=>{const value=$('#desk-session').value;if(value)$('#desk-presentation').value=value.startsWith('oral')?'oral':'poster';});
$('#desk-presentation').addEventListener('change',()=>{const value=$('#desk-presentation').value,s=$('#desk-session').value;if((s.startsWith('oral')&&value!=='oral')||(s==='poster_1'&&value!=='poster'))$('#desk-session').value='';});
$('#chair-decision-form').addEventListener('submit',event=>{
  event.preventDefault();if(busy)return;const p=selected(),accepted=$('#desk-decision').value==='accepted';
  if(!isChief&&!complete(p)){notice('AE는 심사 2건이 모두 완료된 뒤 판정할 수 있습니다.',true);return;}
  if(!panelReady(p)){notice('현재 제출본에 심사위원 2명을 배정해야 판정할 수 있습니다.',true);return;}
  pendingDecision={p_paper_id:p.id,p_status:$('#desk-decision').value,p_note:$('#desk-note').value.trim(),p_presentation:accepted?$('#desk-presentation').value||null:null,p_session:accepted?$('#desk-session').value||null:null,p_exception_reason:!isChief||complete(p)?'':$('#desk-exception').value.trim(),p_expected_updated_at:p.updated_at,p_expected_reviews:currentReviews(p).slice().sort((a,b)=>a.id.localeCompare(b.id))};
  $('#chair-publish-paper').textContent=p.title;$('#chair-publish-status').textContent=STATUS[pendingDecision.p_status];$('#chair-publish-note').textContent=pendingDecision.p_note;$('#chair-publish-exception').textContent=pendingDecision.p_exception_reason?'예외 사유: '+pendingDecision.p_exception_reason:'';$('#chair-publish-dialog').showModal();
});
$('#chair-publish-cancel').addEventListener('click',()=>{$('#chair-publish-dialog').close();pendingDecision=null;});
$('#chair-publish-confirm').addEventListener('click',()=>run(async()=>{if(!pendingDecision)return;data(await client.rpc('chair_publish_decision',pendingDecision));pendingDecision=null;$('#chair-publish-dialog').close();await reloadDetail();notice('판정을 확정하고 저자 포털에 공개했습니다. 이메일 알림 처리 상태를 확인해 주세요.');}));
$('#chair-final-form').addEventListener('submit',event=>{event.preventDefault();run(async()=>{const p=selected(),file=latestFinal(p);data(await client.from('paper_final_checks').upsert({paper_id:p.id,file_id:file.id,checked_by:user.id},{onConflict:'paper_id'}).select('paper_id').single());await reloadDetail();notice(`최종본 v${file.version} 확인 완료를 기록했습니다.`);});});
$('#committee-form').addEventListener('submit',event=>{event.preventDefault();run(async()=>{
  data(await client.from('review_committee').upsert({edition_year:edition.year,track:$('#committee-track').value,committee_role:$('#committee-role').value,display_name:$('#committee-name').value.trim(),email:$('#committee-email').value.trim().toLowerCase(),active:true},{onConflict:'edition_year,track,email,committee_role'}));
  await load();notice('분야별 위원 구성을 저장했습니다.');
});});
$('#committee-list').addEventListener('click',event=>{const el=event.target.closest('[data-committee-toggle]');if(!el)return;run(async()=>{
  const c=committee.find(c=>c.id===el.dataset.committeeToggle);if(!c)return;
  data(await client.from('review_committee').update({active:!c.active}).eq('id',c.id).select('id').single());await load();notice('위원 역할 상태를 변경했습니다.');
});});
async function start() {
  try {
    client=await conferenceClient();const auth=await client.auth.getUser();
    if(auth.error&&!/Auth session missing/i.test(auth.error.message))throw auth.error;
    user=auth.data?.user;
    if(!user){$('#chair-access').hidden=false;notice('위원장 계정으로 로그인해 주세요.');return;}
    const role=data(await client.from('staff_roles').select('role,is_super_admin').eq('user_id',user.id).maybeSingle());
    isChief=role?.role==='chair';
    edition=await currentEdition(client);
    committee=data(await client.from('review_committee').select('*').eq('edition_year',edition.year));
    const isEditor=committee.some(c=>c.active&&c.committee_role==='associate_editor'&&c.email===user.email?.toLowerCase());
    if(!isChief&&!isEditor){$('#chair-access').hidden=false;$('#chair-access-text').textContent='현재 계정에는 위원장 권한이 없습니다. 투고·심사 화면에서 계정을 확인해 주세요.';$('#chair-login').textContent='계정 확인';notice('심사위원장 또는 담당 분야 AE 계정만 이용할 수 있습니다.',true);return;}
    client.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(event==='SIGNED_IN'&&session?.user?.id!==user.id)){papers=[];members=[];membersById.clear();$('#chair-workspace').hidden=true;location.reload();}});
    document.title=`원고 심사 관리 | ${edition.title}`;$('#chair-edition').textContent=`CO-R&BD ${edition.year} / CHAIR DESK`;
    $('#chair-monitor').hidden=!role?.is_super_admin;
    document.querySelectorAll('[data-chief-only]').forEach(el=>el.hidden=!isChief);
    $('#chair-edition').textContent=`CO-R&BD ${edition.year} / ${isChief?'CHIEF EDITOR':'ASSOCIATE EDITOR'}`;
    $('#committee-track').innerHTML=Object.entries(TRACKS).map(([key,label])=>`<option value="${key}">${label}</option>`).join('');
    $('#chair-track-filter').innerHTML='<option value="all">전체 분야</option>'+Object.entries(TRACKS).map(([value,label])=>`<option value="${value}">${label}</option>`).join('');
    await load();$('#chair-workspace').hidden=false;notice('현재 회차의 접수 원고를 불러왔습니다. 원고를 선택해 담당 분야의 심사 진행·판정을 확인하세요.');
  }catch(error){notice(friendly(error),true);}
}
start();
