export const dynamic = "force-dynamic";

type NaverProfile = {
  resultcode?: string;
  response?: {
    id?: string;
    email?: string;
    name?: string;
    nickname?: string;
    profile_image?: string;
  };
};

export async function GET(request: Request) {
  const headers = { "Cache-Control": "no-store" };
  const bearer = request.headers.get("authorization");
  if (!bearer || !/^Bearer\s+\S+$/i.test(bearer)) {
    return Response.json({ error: "Bearer token required" }, { status: 401, headers });
  }

  try {
    const result = await fetch("https://openapi.naver.com/v1/nid/me", {
      headers: { Authorization: bearer, Accept: "application/json" },
      signal: AbortSignal.timeout(8000),
      cache: "no-store",
    });
    if (!result.ok) {
      return Response.json({ error: "Naver profile request failed" }, { status: 502, headers });
    }

    const payload: NaverProfile = await result.json();
    const user = payload.response;
    if (payload.resultcode !== "00" || !user?.id) {
      return Response.json({ error: "Naver profile is incomplete" }, { status: 502, headers });
    }

    return Response.json({
      sub: String(user.id),
      id: String(user.id),
      email: user.email || undefined,
      name: user.name || user.nickname || undefined,
      picture: user.profile_image || undefined,
    }, { headers });
  } catch {
    return Response.json({ error: "Naver profile request failed" }, { status: 502, headers });
  }
}
