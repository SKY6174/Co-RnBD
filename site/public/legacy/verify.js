import { conferenceClient, escapeHtml as esc, requireData } from './conference-client.js';
const $=s=>document.querySelector(s);
const KINDS={attendance:'참가확인증',receipt:'영수증',statement:'거래명세서'};
const day=v=>new Intl.DateTimeFormat('ko-KR',{timeZone:'Asia/Seoul',dateStyle:'long'}).format(new Date(/^\d{4}-\d{2}-\d{2}$/.test(v)?v+'T12:00:00+09:00':v));
const normalize=v=>String(v||'').replace(/[^0-9a-f]/gi,'').toUpperCase();
const pretty=v=>normalize(v).match(/.{1,5}/g)?.join('-')||'';
let busy=false;
function message(text,error=false){$('#verify-message').textContent=text;$('#verify-message').classList.toggle('error',error);}
async function verify(raw){
 const code=normalize(raw),result=$('#verify-result');result.hidden=true;result.replaceChildren();
 if(code.length!==20){message('문서확인번호 20자리(영문 A–F, 숫자)를 정확히 입력해 주세요.',true);return;}
 if(busy)return;busy=true;message('확인하고 있습니다.');
 try{
  const client=await conferenceClient();
  const row=requireData(await client.rpc('verify_registration_document',{p_code:code}))?.[0];
  if(!row){message('일치하는 발급문서가 없습니다. 번호를 다시 확인하거나 사무국에 문의해 주세요.',true);return;}
  const valid=row.state==='issued';
  const signers=(row.signatories||[]).map(s=>`${esc(s.organization)} ${esc(s.title)} ${esc(s.name)}`).join('<br>');
  result.innerHTML=`<span class="operations-kicker">${valid?'VALID':'REVOKED'}</span><h2 id="verify-result-title">${valid?'유효한 발급문서입니다':'발급이 취소된 문서입니다'}</h2>${valid?'':`<p class="document-warning">${day(row.revoked_at)}에 발급이 취소되었습니다. 이 사본은 더 이상 유효하지 않습니다.</p>`}<table class="issued-info"><tbody><tr><th scope="row">문서 종류</th><td>${KINDS[row.kind]||esc(row.kind)}</td></tr><tr><th scope="row">발급번호</th><td>${esc(row.document_no)}</td></tr><tr><th scope="row">문서확인번호</th><td>${esc(pretty(code))}</td></tr><tr><th scope="row">성명</th><td>${esc(row.recipient_name)}</td></tr><tr><th scope="row">소속</th><td>${esc(row.recipient_affiliation)}</td></tr><tr><th scope="row">행사</th><td>${esc(row.conference_title)} (${day(row.start_date)} – ${day(row.end_date)})</td></tr><tr><th scope="row">발급일</th><td>${day(row.issued_at)}</td></tr><tr><th scope="row">발급 명의</th><td>${signers||'—'}</td></tr></tbody></table><p class="operations-meta">종이·PDF 사본의 내용이 위 정보와 다르면 위·변조된 문서일 수 있습니다.</p>`;
  result.hidden=false;message(valid?'확인을 완료했습니다.':'취소된 문서입니다.',!valid);
  history.replaceState(null,'','?code='+code);
 }catch(error){message('지금은 확인할 수 없습니다. 잠시 후 다시 시도해 주세요.',true);}
 finally{busy=false;}
}
$('#verify-form').addEventListener('submit',event=>{event.preventDefault();verify($('#verify-code').value);});
const initial=new URLSearchParams(location.search).get('code');
if(initial){$('#verify-code').value=pretty(initial);verify(initial);}
