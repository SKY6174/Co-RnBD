import { conferenceClient, escapeHtml as esc, requireData } from './conference-client.js';
import { REGISTRATION_COLUMNS, BILLING, STATES, cards, one, money, date, issue, friendly, registrationNo, depositorName } from './member-documents.js';
const $=s=>document.querySelector(s);
let client,user,generation=0,consented=false;
function notice(text,error=false){$('#member-message').textContent=text;$('#member-message').classList.toggle('error',error);}
function clear(){generation++;user=null;$('#member-workspace').hidden=true;$('#member-login').hidden=false;$('#member-history').replaceChildren();$('#member-account').replaceChildren();$('#member-admin').hidden=true;}
const dateOnly=value=>new Intl.DateTimeFormat('ko-KR',{timeZone:'Asia/Seoul',dateStyle:'long'}).format(new Date(value));
function renderConsent(row){
 consented=Boolean(row?.consented);
 $('#marketing-consent-status').textContent=consented?`홍보 메일 수신에 동의했습니다 (${dateOnly(row.consented_at)}).`
  :row?.withdrawn_at?`홍보 메일 수신을 거부한 상태입니다 (${dateOnly(row.withdrawn_at)} 철회).`:'홍보 메일 수신에 동의하지 않은 상태입니다.';
 const button=$('#marketing-consent-toggle');button.disabled=false;
 button.textContent=consented?'수신 동의 철회':'홍보 메일 수신 동의';
 button.className=consented?'operations-button secondary':'operations-button';
}
async function load(){
 const ticket=++generation;
 const auth=await client.auth.getUser();
 if(ticket!==generation)return;
 if(auth.error&&!/Auth session missing/i.test(auth.error.message))throw auth.error;
 user=auth.data?.user;
 if(!user){clear();notice('로그인하면 본인의 참가 내역과 증빙을 확인할 수 있습니다.');return;}
 const [profileResult,rowsResult,issuersResult,roleResult,consentResult]=await Promise.all([
  client.from('profiles').select('full_name,affiliation,email').eq('user_id',user.id).single(),
  client.from('attendee_registrations').select(REGISTRATION_COLUMNS).eq('user_id',user.id).order('edition_year',{ascending:false}),
  client.from('document_issuers').select('edition_year,enabled'),
  client.from('staff_roles').select('role').eq('user_id',user.id).maybeSingle(),
  client.from('marketing_consents').select('consented,consented_at,withdrawn_at').eq('user_id',user.id).maybeSingle()
 ]);
 if(ticket!==generation)return;
 const profile=requireData(profileResult),rows=requireData(rowsResult),issuers=requireData(issuersResult),role=requireData(roleResult);
 renderConsent(requireData(consentResult));
 $('#member-account').textContent=`${profile.full_name||'회원'} · ${profile.affiliation||'소속 미입력'} · ${profile.email||user.email}`;
 $('#member-login').hidden=true;$('#member-workspace').hidden=false;$('#member-admin').hidden=role?.role!=='chair';
 $('#member-history').innerHTML=rows.length?rows.map(row=>{
  const edition=one(row.conference_editions),bill=one(row.registration_billing);
  return `<section class="operations-card" data-registration-id="${row.id}"><div class="document-section-head"><div><span class="operations-kicker">${row.edition_year} EDITION</span><h2>${esc(edition?.title||`Co-R&BD ${row.edition_year}`)}</h2></div><span class="document-status">${STATES[row.status]}</span></div><p class="document-summary">${esc(row.attendance_days.map(date).join(' · '))} · ${row.checked_in_at?'체크인 완료':'체크인 전'}</p><p class="document-summary">등록비 ${bill?money(bill.amount):'미설정'} · ${bill?BILLING[bill.status]:'납부 안내 준비 중'}</p><p class="document-summary">등록번호 ${registrationNo(row.id)}${row.status!=='cancelled'&&(!bill||bill.status==='unpaid')?` · 계좌이체 입금자명 <strong>${esc(depositorName(profile.full_name,row.id))}</strong>`:''}</p>${cards(row,issuers.find(i=>i.edition_year===row.edition_year))}</section>`;
 }).join(''):'<div class="operations-empty"><h2>참가 신청 내역이 없습니다.</h2><p>일반 참가 신청을 완료하면 이곳에서 내역과 증빙을 관리할 수 있습니다.</p><a class="operations-button" href="./registration.html">참가 신청하기</a></div>';
 notice('참가확인증은 체크인, 영수증은 실제 납부 확인 후 발급됩니다.');
}
$('#member-history').addEventListener('click',async event=>{
 const button=event.target.closest('[data-issue]');if(!button)return;
 const ticket=generation;button.disabled=true;
 try{const id=await issue(client,button.dataset.issue,button.dataset.kind);if(ticket===generation)location.assign('./document.html?id='+id);}
 catch(error){if(ticket===generation){notice(friendly(error),true);button.disabled=false;}}
});
$('#marketing-consent-toggle').addEventListener('click',async()=>{
 const button=$('#marketing-consent-toggle'),ticket=generation,next=!consented;
 if(!next&&!confirm('홍보 메일 수신 동의를 철회할까요? 서비스 안내 메일은 계속 발송됩니다.'))return;
 button.disabled=true;
 try{
  requireData(await client.rpc('set_marketing_consent',{p_consent:next,p_source:'mypage'}));
  const row=requireData(await client.from('marketing_consents').select('consented,consented_at,withdrawn_at').eq('user_id',user.id).maybeSingle());
  if(ticket!==generation)return;
  renderConsent(row);notice(next?'홍보 메일 수신에 동의했습니다. 처리 결과를 메일로 보내 드립니다.':'홍보 메일 수신 동의를 철회했습니다. 처리 결과를 메일로 보내 드립니다.');
 }catch(error){if(ticket===generation){button.disabled=false;notice(friendly(error),true);}}
});
$('#member-signout').addEventListener('click',async()=>{try{const result=await client.auth.signOut();if(result.error)throw result.error;clear();notice('로그아웃했습니다.');}catch(error){notice(friendly(error),true);}});
$('#member-refresh').addEventListener('click',()=>load().catch(error=>{clear();notice(friendly(error),true);}));
(async()=>{try{client=await conferenceClient();await load();client.auth.onAuthStateChange((event,session)=>{if(event==='INITIAL_SESSION'||event==='TOKEN_REFRESHED'||(event==='SIGNED_IN'&&session?.user?.id===user?.id))return;clear();setTimeout(()=>load().catch(error=>notice(friendly(error),true)),0);});}catch(error){clear();notice(friendly(error),true);}})();
