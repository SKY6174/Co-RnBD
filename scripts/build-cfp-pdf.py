"""Build the A4 CFP using ReportLab and the approved conference/logo assets.

Usage: python scripts/build-cfp-pdf.py --font-dir /path/to/Pretendard/fonts
       --background /path/to/co-rnbd-2026-event-poster-background.png
The background is the existing user-provided poster artwork; it is optional.
"""

import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "site/public/assets"
NAVY = colors.HexColor("#07172c")
BLUE = colors.HexColor("#16799e")
CYAN = colors.HexColor("#5fcdf1")
LIME = colors.HexColor("#c9e66b")
INK = colors.HexColor("#283b4b")
MUTED = colors.HexColor("#526574")
RULE = colors.HexColor("#dce5eb")
W, H = A4
MARGIN = 30
GAP = 26
COL = (W - 2 * MARGIN - GAP) / 2


def buildPdf(output, fontDir, background):
    for weight in ("Regular", "Bold"):
        font = fontDir / f"Pretendard-{weight}.ttf"
        if not font.is_file():
            raise FileNotFoundError(f"Required font: {font}")
        pdfmetrics.registerFont(TTFont(weight, str(font)))
    pdfmetrics.registerFontFamily("Regular", normal="Regular", bold="Bold")
    output.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(output), pagesize=A4, pageCompression=1)
    c.setTitle("T-VET Co-R&BD Conference 2026 | Call for Papers & Cases")
    c.setAuthor("T-VET Co-R&BD Conference")
    c.setSubject("2027. 1. 20.-21. | 울산과학대학교 동부캠퍼스 | CFP 초안")

    def text(value, x, y, size=9.4, font="Regular", color=INK):
        c.setFillColor(color)
        c.setFont(font, size)
        c.drawString(x, y, value)

    def paragraph(value, x, top, width=COL, size=9.4, leading=14, color=MUTED):
        style = ParagraphStyle("body", fontName="Regular", fontSize=size,
                               leading=leading, textColor=color, wordWrap="CJK")
        p = Paragraph(value, style)
        _, height = p.wrap(width, H)
        p.drawOn(c, x, top - height)
        return top - height

    def heading(label, english, x, top):
        text(label, x, top - 12, size=12, font="Bold", color=BLUE)
        labelWidth = pdfmetrics.stringWidth(label, "Bold", 12)
        text(english, x + labelWidth + 10, top - 12, size=7.5, font="Bold", color=MUTED)
        c.setStrokeColor(CYAN)
        c.setLineWidth(2)
        c.line(x, top - 20, x + 27, top - 20)
        return top - 31

    def fitImage(path, x, y, width, height):
        image = ImageReader(str(path))
        iw, ih = image.getSize()
        scale = min(width / iw, height / ih)
        dw, dh = iw * scale, ih * scale
        c.drawImage(image, x + (width - dw) / 2, y + (height - dh) / 2,
                    width=dw, height=dh, mask="auto")

    # Compact photo header reserves most of the page for the detailed call.
    headerBottom = 635
    c.setFillColor(NAVY)
    c.rect(0, headerBottom, W, H - headerBottom, fill=1, stroke=0)
    if background:
        c.saveState()
        clip = c.beginPath()
        clip.rect(0, headerBottom, W, H - headerBottom)
        c.clipPath(clip, stroke=0, fill=0)
        c.drawImage(str(background), 0, 385, width=W, height=W * 1492 / 1054)
        c.setFillColor(NAVY)
        c.setFillAlpha(.70)
        c.rect(0, headerBottom, W, H - headerBottom, fill=1, stroke=0)
        c.restoreState()
    c.setFillColor(CYAN)
    c.rect(0, H - 4, W, 4, fill=1, stroke=0)

    text("논문·현장사례 모집", MARGIN, H - 34, size=10, font="Bold", color=LIME)
    # The transparent brand artwork has dark lettering; a white plate preserves it.
    logoX, logoY = W - MARGIN - 190, H - 77
    c.setFillColor(colors.white)
    c.roundRect(logoX, logoY, 190, 52, 3, fill=1, stroke=0)
    fitImage(ASSETS / "t-vet-co-rbd-conference-logo.png", logoX + 9, logoY + 7, 172, 38)
    text("CALL FOR", MARGIN, H - 76, size=28, font="Bold", color=colors.white)
    text("PAPERS & CASES", MARGIN, H - 108, size=28, font="Bold", color=colors.white)
    text("제1회 전문대학 산학공동 R&BD 컨퍼런스", MARGIN, H - 134,
         size=14, font="Bold", color=colors.white)
    text("전문기술석사 연구와 산학공동기술개발과제의 만남", MARGIN, H - 153,
         size=10, color=colors.HexColor("#d5e6ef"))
    text("2027. 1. 20.(수) - 1. 21.(목)", MARGIN, headerBottom + 33,
         size=15, font="Bold", color=CYAN)
    text("울산과학대학교 동부캠퍼스", MARGIN, headerBottom + 15,
         size=10, font="Bold", color=colors.white)
    text("co-rnbd.org", W - MARGIN - 85, headerBottom + 15,
         size=11, font="Bold", color=colors.white)
    c.linkURL("https://co-rnbd.org", (W - MARGIN - 90, headerBottom + 10,
                                     W - MARGIN, headerBottom + 30), relative=0)
    c.setFillColor(LIME)
    c.rect(0, headerBottom, W, 3, fill=1, stroke=0)

    left, right = MARGIN, MARGIN + COL + GAP
    top = headerBottom - 22
    c.setStrokeColor(RULE)
    c.setLineWidth(.6)
    c.line(W / 2, 142, W / 2, top)

    y = heading("모집 취지", "GENERAL INFORMATION", left, top)
    y = paragraph("전문기술석사 연구성과와 산학공동기술개발과제의 현장 적용 경험을 공유하고, "
                  "대학과 기업의 후속 공동연구를 발굴합니다. 재학생·졸업생, 교수·연구진, "
                  "산업체 공동연구자의 참여를 환영합니다.", left, y)

    y = heading("메인 트랙", "MAIN TRACKS", left, y - 20)
    tracks = [
        ("전문기술석사 응용연구", "학위 프로젝트와 현장 문제 해결 연구·실험·검증·적용 성과"),
        ("산학공동기술개발과제 성과발표", "기업 애로기술 공동개발, 현장 실증 결과와 후속 사업화 사례"),
        ("산업융합기술", "AI·자동화·모빌리티·조선·에너지·환경·보건 융합기술과 현장 적용사례"),
        ("T-VET 정책·교육연구", "전문기술석사·고등직업교육 정책·제도, 교육과정 운영, 성과평가·산학협력 사례"),
    ]
    for index, (title, detail) in enumerate(tracks, 1):
        text(f"{index:02}", left, y - 10, size=9.5, font="Bold", color=BLUE)
        y = paragraph(f"<b>{title}</b><br/>{detail}", left + 24, y,
                      width=COL - 24, size=9.2, leading=13) - 9

    y = heading("제출 유형", "SUBMISSION TYPES", left, y - 9)
    types = [
        ("응용연구 · 확장초록 2-4쪽", "문제·방법·검증·현장 활용"),
        ("산학공동기술개발 사례 · 보고서 2쪽", "기업 문제·기술적 접근·전후 성과지표"),
        ("교육·운영 사례 · 보고서 2쪽", "운영모델·교육성과 근거·개선 과제"),
        ("진행연구 포스터·데모 · 요약 1쪽", "진행단계·현재 결과·데모 필요사항"),
    ]
    for title, detail in types:
        c.setFillColor(BLUE)
        c.circle(left + 3, y - 6, 1.7, fill=1, stroke=0)
        y = paragraph(f"<b>{title}</b><br/>{detail}", left + 13, y,
                      width=COL - 13, size=9.2, leading=13.5) - 10
    if y < 125:
        raise ValueError(f"Left column overlaps footer: {y:.1f}")

    y = heading("투고 안내", "PAPER SUBMISSION", right, top)
    y = paragraph("국문 또는 영문 PDF 원고를 접수합니다. 저자 중 1명 이상은 전문대학 소속이거나 "
                  "해당 전문대학 공동과제 참여자여야 합니다.", right, y)
    y = heading("심사·발표", "REVIEW & PRESENTATION", right, y - 20)
    y = paragraph("원고마다 이해관계를 확인한 심사위원 2명이 검토합니다. 채택 원고는 구두 또는 "
                  "포스터로 발표하며, 발표자 1명 이상이 별도 등록하고 현장에서 발표해야 합니다.", right, y)

    y = heading("주요 일정", "IMPORTANT DATES", right, y - 20)
    dates = [
        ("일반 참가신청 마감", "2027. 01. 05.(화) 18:00", True),
        ("원고 접수 마감", "2026. 12. 21.(월) 18:00", False),
        ("채택·수정 요청 통보", "2027. 01. 04.(월)", False),
        ("최종본·발표자 등록", "2027. 01. 12.(화) 18:00", False),
    ]
    for label, value, confirmed in dates:
        text(label, right, y - 9, size=8.8, font="Bold")
        status = "확정" if confirmed else "가안"
        text(status, right + COL - 20, y - 9, size=8,
             font="Bold", color=BLUE if confirmed else MUTED)
        text(value, right, y - 24, size=9.2, color=MUTED)
        c.setStrokeColor(RULE)
        c.line(right, y - 32, right + COL, y - 32)
        y -= 41

    y = heading("안내·문의", "MORE INFORMATION", right, y - 13)
    y = paragraph("<b>모집공고·투고 절차</b> co-rnbd.org/cfp.html<br/>"
                  "<b>사무국</b> 052)230-0441", right, y)
    y = paragraph("논문 일정은 확정 후 안내합니다. 일반 참가신청과 발표자 등록은 별도 절차이며, 마감 시간은 KST 기준입니다.",
                  right, y - 12, size=8.6, leading=13)
    if y < 125:
        raise ValueError(f"Right column overlaps footer: {y:.1f}")

    # Four institution logos, grouped clearly by the three requested roles.
    footerTop = 121
    c.setStrokeColor(RULE)
    c.line(MARGIN, footerTop, W - MARGIN, footerTop)
    widths = (121.5, 173.5, W - 2 * MARGIN - 295)
    x = MARGIN
    for label, width in zip(("주최", "주관", "후원"), widths):
        text(label, x, footerTop - 22, size=8, font="Bold", color=MUTED)
        x += width
    # Center the visible artwork, excluding transparent padding in the PNGs.
    # DigiTech scales to 80% inside its existing slot; other sizes stay the same.
    for filename, slotX, slotWidth, sizeFactor, visibleCenter in [
        ("ulsan-college.png", MARGIN, 107, 1, 75.5),
        ("digitech.png", MARGIN + 121.5, 159, .8, 445.5),
        ("ministry-of-education.png", MARGIN + 295, 118, 1, 47),
        ("national-research-foundation.png", MARGIN + 427.5, 107, 1, 216),
    ]:
        logo = ImageReader(str(ASSETS / "organizers" / filename))
        iw, ih = logo.getSize()
        width = slotWidth * sizeFactor
        scale = width / iw
        x = slotX + (slotWidth - width) / 2
        c.drawImage(logo, x, 70 - (ih - visibleCenter) * scale,
                    width=width, height=ih * scale, mask="auto")
    text("공고 전 검토본 · 논문 투고 일정 가안", MARGIN, 22, size=7.5, color=MUTED)
    text("T-VET Co-R&BD Conference 2026", W - MARGIN - 151, 22, size=7.5, color=MUTED)
    c.showPage()
    c.save()
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font-dir", type=Path, default=Path.home() / "Library/Fonts")
    parser.add_argument("--background", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "site/public/downloads/t-vet-co-rbd-2026-call-for-papers-and-cases.pdf")
    args = parser.parse_args()
    buildPdf(args.output, args.font_dir, args.background)
