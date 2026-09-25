// Supabase Custom OAuth expects standard top-level userinfo claims.
// Naver wraps them in a `response` object, so this endpoint normalizes it.
export default async function handler(request, response) {
  response.setHeader('Cache-Control', 'no-store');
  if (request.method !== 'GET') {
    response.setHeader('Allow', 'GET');
    return response.status(405).json({ error: 'Method not allowed' });
  }
  const bearer = request.headers.authorization;
  if (!bearer || !/^Bearer\s+\S+$/i.test(bearer)) {
    return response.status(401).json({ error: 'Bearer token required' });
  }
  try {
    const result = await fetch('https://openapi.naver.com/v1/nid/me', {
      headers: { Authorization: bearer, Accept: 'application/json' },
      signal: AbortSignal.timeout(8000),
    });
    if (!result.ok) return response.status(502).json({ error: 'Naver profile request failed' });
    const payload = await result.json();
    const user = payload.response;
    if (payload.resultcode !== '00' || !user?.id) {
      return response.status(502).json({ error: 'Naver profile is incomplete' });
    }
    return response.status(200).json({
      sub: String(user.id),
      id: String(user.id),
      email: user.email || undefined,
      name: user.name || user.nickname || undefined,
      picture: user.profile_image || undefined,
    });
  } catch {
    return response.status(502).json({ error: 'Naver profile request failed' });
  }
}
