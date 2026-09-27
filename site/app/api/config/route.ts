export const dynamic = "force-dynamic";

export function GET() {
  const url = process.env.SUPABASE_URL;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;

  if (!url || !publishableKey) {
    return Response.json(
      { error: "Supabase 연결 설정이 필요합니다." },
      { status: 503, headers: { "Cache-Control": "no-store" } },
    );
  }

  return Response.json(
    { url, publishableKey, naverEnabled: process.env.NAVER_OAUTH_ENABLED === "true" },
    { headers: { "Cache-Control": "public, max-age=0, s-maxage=60" } },
  );
}
