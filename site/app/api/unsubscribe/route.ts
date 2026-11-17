export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 15;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const headers = { 'Cache-Control': 'no-store', 'Content-Type': 'text/html; charset=utf-8', 'X-Robots-Tag': 'noindex' };

function page(title: string, body: string, status = 200) {
  return new Response(`<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title} | T-VET Co-R&amp;BD</title></head>`
    + '<body style="margin:0;background:#f5f8ef;font-family:-apple-system,BlinkMacSystemFont,\'Apple SD Gothic Neo\',\'Noto Sans KR\',Arial,sans-serif;color:#14382e">'
    + `<main style="max-width:520px;margin:48px auto;padding:28px;background:#fff;border:1px solid #d8e4d2;border-radius:12px;line-height:1.7"><h1 style="font-size:22px;margin-top:0">${title}</h1>${body}`
    + '<p style="font-size:13px;color:#60736a">문의: office@co-rnbd.org · <a href="https://co-rnbd.org/mypage.html" style="color:#244d38">마이페이지</a></p></main></body></html>', { status, headers });
}

function token(request: Request) {
  const value = new URL(request.url).searchParams.get('t') || '';
  return UUID.test(value) ? value : null;
}

// Opening the link only shows a confirmation button, so link scanners cannot withdraw consent.
export function GET(request: Request) {
  const t = token(request);
  if (!t) return page('수신거부 링크가 올바르지 않습니다', '<p>메일에 있는 링크를 그대로 열었는지 확인해 주세요. 마이페이지에서도 홍보 메일 수신을 끌 수 있습니다.</p>', 400);
  return page('홍보 메일 수신거부', '<p>T-VET Co-R&amp;BD의 홍보(광고성) 메일을 더 이상 받지 않으려면 아래 버튼을 눌러 주세요. 참가 신청·투고·심사 등 서비스 안내 메일은 계속 발송됩니다.</p>'
    + `<form method="post" action="/api/unsubscribe?t=${t}"><button type="submit" style="min-height:44px;padding:10px 20px;border:0;border-radius:8px;background:#244d38;color:#fff;font:inherit;font-weight:700;cursor:pointer">수신거부</button></form>`);
}

// Form submission and RFC 8058 one-click requests (List-Unsubscribe=One-Click) withdraw consent.
export async function POST(request: Request) {
  const t = token(request);
  if (!t) return page('수신거부 링크가 올바르지 않습니다', '<p>메일에 있는 링크를 그대로 열었는지 확인해 주세요.</p>', 400);
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return page('잠시 후 다시 시도해 주세요', '<p>수신거부를 처리하지 못했습니다. 잠시 후 다시 시도하거나 office@co-rnbd.org로 알려 주세요.</p>', 503);
  try {
    const result = await fetch(new URL('/rest/v1/rpc/unsubscribe_marketing', url), {
      method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_token: t }), signal: AbortSignal.timeout(8000), cache: 'no-store',
    });
    if (!result.ok) throw new Error('rpc ' + result.status);
    const outcome = await result.json();
    if (outcome === 'unknown') return page('수신거부 링크를 찾을 수 없습니다', '<p>이미 처리되었거나 만료된 링크입니다. 마이페이지에서 현재 수신 상태를 확인해 주세요.</p>', 404);
    return page('수신거부가 처리되었습니다', outcome === 'already'
      ? '<p>이미 홍보 메일 수신을 거부한 상태입니다. 더 이상 홍보 메일을 보내지 않습니다.</p>'
      : '<p>앞으로 홍보 메일을 보내지 않습니다. 처리 결과는 메일로도 알려 드립니다. 다시 받으려면 마이페이지에서 동의할 수 있습니다.</p>');
  } catch {
    console.error('Unsubscribe could not be recorded');
    return page('잠시 후 다시 시도해 주세요', '<p>수신거부를 처리하지 못했습니다. 잠시 후 다시 시도하거나 office@co-rnbd.org로 알려 주세요.</p>', 503);
  }
}
