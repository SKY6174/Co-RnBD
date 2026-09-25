export default function handler(request, response) {
  if (request.method !== 'GET') {
    response.setHeader('Allow', 'GET');
    return response.status(405).json({ error: 'Method not allowed' });
  }
  const url = process.env.SUPABASE_URL;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  response.setHeader('Cache-Control', 'no-store');
  if (!url || !publishableKey) {
    return response.status(503).json({ error: 'Supabase 연결 설정이 필요합니다.' });
  }
  return response.status(200).json({ url, publishableKey, naverEnabled: process.env.NAVER_OAUTH_ENABLED === 'true' });
}
