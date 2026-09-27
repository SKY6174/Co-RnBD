export default function handler(request, response) {
  if (request.method !== 'GET') {
    response.setHeader('Allow', 'GET');
    return response.status(405).json({ error: 'Method not allowed' });
  }
  const url = process.env.SUPABASE_URL;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !publishableKey) {
    response.setHeader('Cache-Control', 'no-store');
    return response.status(503).json({ error: 'Supabase 연결 설정이 필요합니다.' });
  }
  response.setHeader('Cache-Control', 'public, max-age=0, s-maxage=60');
  return response.status(200).json({ url, publishableKey, naverEnabled: process.env.NAVER_OAUTH_ENABLED === 'true' });
}
