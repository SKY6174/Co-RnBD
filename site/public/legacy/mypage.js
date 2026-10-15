import { conferenceClient, escapeHtml as esc, requireData } from './conference-client.js';
import { REGISTRATION_COLUMNS, BILLING, STATES, cards, one, money, date, issue, friendly } from './member-documents.js';
const $=s=>document.querySelector(s);
let client,user,generation=0;
function notice(text,error=false){$('#member-message').textContent=text;$('#member-message').classList.toggle('error',error);}
function clear(){generation++;user=null;$('#member-workspace').hidden=true;$('#member-login').hidden=false;$('#member-history').replaceChildren();$('#member-account').replaceChildren();$('#member-admin').hidden=true;}
async function load(){
 const ticket=++generation;
 const auth=await client.auth.getUser();
 if(ticket!==generation)return;
 if(auth.error&&!/Auth session missing/i.test(auth.error.message))throw auth.error;
 user=auth.data?.user;
 if(!user){clear();notice('로그인하면 본인의 참가 내역과 증빙을 확인할 수 있습니다.');return;}
 const [profileResult,rowsResult,issuersResult,roleResult]=await Promise.all([
  client.from('profiles').select('full_name,affiliation,email').eq('user_id',user.id).single(),
  client.from('attendee_registrations').select(REGISTRATION_COLUMNS).eq('user_id',user.id).order('edition_year',{ascending:false}),
  client.from('document_issuers').select('edition_year,enabled'),
  client.from('staff_roles').select('role').eq('user_id',user.id).maybeSingle()
 ]);
 if(ticket!==generation)return;
 const profile=requireData(profileResult),rows=requireData(rowsResult),issuers=requireData(issuersResult),role=requireData(roleResult);
 $('#member-account').textContent=`${profile.full_name||'회원'} · ${profile.affiliation||'소속 미입력'} · ${profile.email||user.email}`;
 $('#member-login').hidden=true;$('#member-workspace').hidden=false;$('#member-admin').hidden=role?.role!=='chair';
 $('#member-history').innerHTML=rows.length?rows.map(row=>{
  const edition=one(row.conference_editions),bill=one(row.registration_billing);
  return `<section class="operations-card" data-registration-id="${row.id}"><div class="document-section-head"><div><span class="operations-kicker">${row.edition_year} EDITION</span><h2>${esc(edition?.title||`Co-R&BD ${row.edition_year}`)}</h2></div><span class="document-status">${STATES[row.status]}</span></div><p class="document-summary">${esc(row.attendance_days.map(date).join(' · '))} · ${row.checked_in_at?'체크인 완료':'체크인 전'}</p><p class="document-summary">등록비 ${bill?money(bill.amount):'미설정'} · ${bill?BILLING[bill.status]:'납부 안내 준비 중'}</p>${cards(row,issuers.find(i=>i.edition_year===row.edition_year))}</section>`;
 }).join(''):'<div class="operations-empty"><h2>참가 신청 내역이 없습니다.</h2><p>일반 참가 신청을 완료하면 이곳에서 내역과 증빙을 관리할 수 있습니다.</p><a class="operations-button" href="./registration.html">참가 신청하기</a></div>';
 notice('참가확인증은 체크인, 영수증은 실제 납부 확인 후 발급됩니다.');
}
$('#member-history').addEventListener('click',async event=>{
 const button=event.target.closest('[data-issue]');if(!button)return;
 const ticket=generation;button.disabled=true;
 try{const id=await issue(client,button.dataset.issue,button.dataset.kind);if(ticket===generation)location.assign('./document.html?id='+id);}
 catch(error){if(ticket===generation){notice(friendly(error),true);button.disabled=false;}}
});
$('#member-signout').addEventListener('click',async()=>{try{const result=await client.auth.signOut();if(result.error)throw result.error;clear();notice('로그아웃했습니다.');}catch(error){notice(friendly(error),true);}});
$('#member-refresh').addEventListener('click',()=>load().catch(error=>{clear();notice(friendly(error),true);}));
(async()=>{try{client=await conferenceClient();await load();client.auth.onAuthStateChange((event,session)=>{if(event==='INITIAL_SESSION'||event==='TOKEN_REFRESHED'||(event==='SIGNED_IN'&&session?.user?.id===user?.id))return;clear();setTimeout(()=>load().catch(error=>notice(friendly(error),true)),0);});}catch(error){clear();notice(friendly(error),true);}})();
