import { KIND_TITLES, renderDocumentPdf, type IssuedDocument } from "../../../../../lib/document-pdf";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
export const maxDuration = 20;

const noStore = { "Cache-Control": "private, no-store" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const JWT = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/;

// The document is read with the caller's own access token, so Postgres RLS decides
// who may download it (the registrant or the chair). No service key is used here.
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) return Response.json({ error: "Invalid document" }, { status: 400, headers: noStore });
  const token = JWT.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!token) return Response.json({ error: "Authentication required" }, { status: 401, headers: noStore });
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return Response.json({ error: "Not configured" }, { status: 503, headers: noStore });

  let rows: (IssuedDocument & { state: string })[];
  try {
    const result = await fetch(
      `${url}/rest/v1/registration_documents?id=eq.${id}&select=id,kind,document_no,verification_code,snapshot,state,issued_at`,
      { headers: { apikey: key, Authorization: `Bearer ${token}` }, cache: "no-store", signal: AbortSignal.timeout(8000) },
    );
    if (result.status === 401) return Response.json({ error: "Authentication required" }, { status: 401, headers: noStore });
    if (!result.ok) throw new Error(`Supabase ${result.status}`);
    rows = await result.json();
  } catch {
    return Response.json({ error: "Document service unavailable" }, { status: 503, headers: noStore });
  }
  const doc = rows[0];
  if (!doc) return Response.json({ error: "Not found" }, { status: 404, headers: noStore });
  if (doc.state !== "issued") return Response.json({ error: "Revoked" }, { status: 410, headers: noStore });

  const verifyBase =
    process.env.VERCEL_ENV === "production" ? "https://co-rnbd.org/verify.html" : `${new URL(request.url).origin}/verify.html`;
  const bytes = await renderDocumentPdf(doc, verifyBase);
  const filename = `${KIND_TITLES[doc.kind]}_${doc.document_no}.pdf`;
  return new Response(Buffer.from(bytes), {
    headers: {
      ...noStore,
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="document.pdf"; filename*=UTF-8''${encodeURIComponent(filename)}`,
    },
  });
}
