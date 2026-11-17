import { readFile } from "node:fs/promises";
import path from "node:path";
import fontkit from "@pdf-lib/fontkit";
import { PDFDocument, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import QRCode from "qrcode";

export type DocumentKind = "attendance" | "receipt" | "statement";
export type Signatory = { organization: string; title: string; name: string };
export type IssuedDocument = {
  id: string;
  kind: DocumentKind;
  document_no: string;
  verification_code: string;
  issued_at: string;
  snapshot: {
    recipient: { name: string; affiliation: string };
    conference: { title: string; start_date: string; end_date: string; venue: string };
    attendance_days?: string[];
    issuer: { organization?: string; representative?: string; address?: string; organization_number?: string; contact_email?: string };
    signatories?: Signatory[];
    billing?: { amount: number; status: string; payment_method: string | null; paid_at: string | null } | null;
  };
};

export const KIND_TITLES: Record<DocumentKind, string> = { attendance: "참가확인증", receipt: "영수증", statement: "거래명세서" };
const METHODS: Record<string, string> = { transfer: "계좌이체", cash: "현금", other: "기타" };
const INK = rgb(0.09, 0.18, 0.16);
const MUTED = rgb(0.32, 0.41, 0.36);
const LINE = rgb(0.09, 0.24, 0.2);
const A4: [number, number] = [595.28, 841.89];

const kst = (value: string, withYear = true) =>
  new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    ...(withYear ? { year: "numeric" } : {}),
    month: "long",
    day: "numeric",
  }).format(new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T12:00:00+09:00` : value));
const money = (value: number) => `${new Intl.NumberFormat("ko-KR").format(value)}원`;
export const formatCode = (code: string) => code.match(/.{1,5}/g)?.join("-") ?? code;

function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const lines: string[] = [];
  let line = "";
  for (const word of text.split(/(\s+)/)) {
    const next = line + word;
    if (font.widthOfTextAtSize(next, size) <= width) { line = next; continue; }
    if (line.trim()) lines.push(line.trim());
    line = word.trimStart();
    while (font.widthOfTextAtSize(line, size) > width) {
      let cut = line.length - 1;
      while (cut > 1 && font.widthOfTextAtSize(line.slice(0, cut), size) > width) cut--;
      lines.push(line.slice(0, cut));
      line = line.slice(cut);
    }
  }
  if (line.trim()) lines.push(line.trim());
  return lines.length ? lines : [""];
}

function centered(page: PDFPage, text: string, y: number, font: PDFFont, size: number, color = INK) {
  page.drawText(text, { x: (A4[0] - font.widthOfTextAtSize(text, size)) / 2, y, size, font, color });
}

let assets: Promise<{ regular: Uint8Array; bold: Uint8Array; logo: Uint8Array }> | null = null;
function loadAssets() {
  const root = process.cwd();
  assets ??= Promise.all([
    readFile(path.join(root, "lib/fonts/NanumSquare_acR.ttf")),
    readFile(path.join(root, "lib/fonts/NanumSquare_acB.ttf")),
    readFile(path.join(root, "public/assets/t-vet-co-rbd-conference-logo.png")),
  ]).then(([regular, bold, logo]) => ({ regular, bold, logo }));
  return assets;
}

/** Renders an issued document as an A4 PDF with a QR code for online verification. */
export async function renderDocumentPdf(doc: IssuedDocument, verifyBaseUrl: string): Promise<Uint8Array> {
  const { regular, bold, logo } = await loadAssets();
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const font = await pdf.embedFont(regular, { subset: false });
  const strong = await pdf.embedFont(bold, { subset: false });
  const logoImage = await pdf.embedPng(logo);
  const page = pdf.addPage(A4);
  const { recipient: who, conference: c, issuer, billing } = doc.snapshot;
  const title = KIND_TITLES[doc.kind];
  const verifyUrl = `${verifyBaseUrl}?code=${doc.verification_code}`;

  pdf.setTitle(`${title} ${doc.document_no}`);
  pdf.setSubject(`${c.title} ${title}`);
  pdf.setAuthor("T-VET Co-R&BD Conference");
  pdf.setCreator("co-rnbd.org");
  pdf.setKeywords([doc.document_no, `verification:${formatCode(doc.verification_code)}`]);
  pdf.setCreationDate(new Date(doc.issued_at));

  // Frame
  page.drawRectangle({ x: 24, y: 24, width: A4[0] - 48, height: A4[1] - 48, borderColor: LINE, borderWidth: 1.6 });
  page.drawRectangle({ x: 30, y: 30, width: A4[0] - 60, height: A4[1] - 60, borderColor: LINE, borderWidth: 0.5 });

  page.drawText(doc.document_no, { x: 56, y: A4[1] - 66, size: 11, font, color: INK });
  const logoWidth = 190;
  const logoHeight = (logoImage.height / logoImage.width) * logoWidth;
  page.drawImage(logoImage, { x: (A4[0] - logoWidth) / 2, y: A4[1] - 140, width: logoWidth, height: logoHeight });

  const spaced = [...title].join(" ");
  centered(page, spaced, A4[1] - 215, strong, 34);

  // Details
  const rows: [string, string][] = [
    ["성        명", who.name],
    ["소        속", who.affiliation],
    ["행  사  명", c.title],
    ["행사 기간", `${kst(c.start_date)} ~ ${kst(c.end_date, false)}`],
    ["장        소", c.venue],
  ];
  if (doc.kind === "attendance" && doc.snapshot.attendance_days?.length) {
    rows.push(["참  가  일", doc.snapshot.attendance_days.map((d) => kst(d, false)).join(", ")]);
  }
  if (billing && doc.kind !== "attendance") {
    rows.push(["금        액", `${money(billing.amount)} (학술대회 참가비)`]);
    if (doc.kind === "receipt" && billing.paid_at) {
      rows.push(["납부 내역", `${kst(billing.paid_at)} · ${METHODS[billing.payment_method ?? "other"] ?? "기타"}`]);
    }
  }
  let y = A4[1] - 290;
  const labelX = 96;
  const valueX = 196;
  for (const [label, value] of rows) {
    page.drawText(label, { x: labelX, y, size: 13, font: strong, color: INK });
    for (const line of wrap(value || "—", font, 13, A4[0] - valueX - 80)) {
      page.drawText(line, { x: valueX, y, size: 13, font, color: INK });
      y -= 19;
    }
    y -= 11;
  }

  // Declaration
  const declaration =
    doc.kind === "attendance"
      ? [`위 사람은 「${c.title}」에`, "참가하였음을 확인합니다."]
      : doc.kind === "receipt"
        ? ["위 금액을 학술대회 참가비로", "수납하였음을 확인합니다."]
        : ["위와 같이 학술대회 참가비 내역을", "확인합니다."];
  y = Math.min(y - 30, 330);
  for (const line of declaration) {
    centered(page, line, y, font, 15);
    y -= 26;
  }
  centered(page, kst(doc.issued_at), y - 18, font, 14);
  y -= 78;

  // Issuers (joint names for certificates; no seal)
  const signatories: Signatory[] =
    doc.kind === "attendance" && doc.snapshot.signatories?.length
      ? doc.snapshot.signatories
      : [{ organization: issuer.organization ?? "", title: "대표", name: issuer.representative ?? "" }];
  for (const s of signatories) {
    const text = `${s.organization}  ${s.title}   ${[...s.name.replace(/\s+/g, "")].join(" ")}`;
    centered(page, text, y, strong, 17);
    y -= 32;
  }
  if (doc.kind !== "attendance") {
    const extra = [issuer.address, issuer.organization_number ? `사업자·고유번호 ${issuer.organization_number}` : "", issuer.contact_email]
      .filter(Boolean)
      .join(" · ");
    if (extra) centered(page, extra, y + 8, font, 9.5, MUTED);
  }

  // Verification block
  const qr = QRCode.create(verifyUrl, { errorCorrectionLevel: "M" });
  const qrSize = 78;
  const cell = qrSize / (qr.modules.size + 8);
  const qrX = 60;
  const qrY = 58;
  for (let row = 0; row < qr.modules.size; row++) {
    for (let col = 0; col < qr.modules.size; col++) {
      if (qr.modules.get(row, col)) {
        page.drawRectangle({ x: qrX + (col + 4) * cell, y: qrY + qrSize - (row + 5) * cell, width: cell, height: cell, color: rgb(0, 0, 0) });
      }
    }
  }
  page.drawLine({ start: { x: 56, y: 146 }, end: { x: A4[0] - 56, y: 146 }, thickness: 0.6, color: MUTED });
  const textX = qrX + qrSize + 14;
  page.drawText(`문서확인번호  ${formatCode(doc.verification_code)}`, { x: textX, y: 118, size: 11, font: strong, color: INK });
  page.drawText(`QR 코드 또는 ${verifyBaseUrl.replace(/^https?:\/\//, "")} 에서 문서확인번호로`, { x: textX, y: 100, size: 9, font, color: MUTED });
  page.drawText("발급 여부와 유효(취소) 상태를 확인할 수 있습니다.", { x: textX, y: 87, size: 9, font, color: MUTED });
  const note =
    doc.kind === "attendance"
      ? "직인 생략 · 등록 및 현장 체크인 기록에 따라 전자 발급된 문서입니다."
      : doc.kind === "receipt"
        ? "직인 생략 · 주최 측 납부 확인용이며 현금영수증·세금계산서는 별도입니다."
        : "직인 생략 · 거래명세서는 납부 완료 증명이 아닙니다.";
  page.drawText(note, { x: textX, y: 68, size: 9, font, color: MUTED });

  return pdf.save();
}
