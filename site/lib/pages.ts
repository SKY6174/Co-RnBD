import { readFileSync } from "node:fs";
import path from "node:path";
import type { Metadata } from "next";

export const PAGE_IDS = [
  "index",
  "cfp",
  "program",
  "edition",
  "archive",
  "submission",
  "registration",
  "operations",
  "monitor",
  "privacy",
  "terms",
  "cmt-reference",
] as const;

export type PageId = (typeof PAGE_IDS)[number];

const PAGE_SCRIPTS: Partial<Record<PageId, string>> = {
  program: "program.js",
  edition: "edition.js",
  archive: "archive.js",
  submission: "submission.js",
  registration: "registration.js",
  operations: "operations.js",
  monitor: "monitor.js",
};

const PAGE_METADATA: Record<PageId, Metadata> = {
  index: {
    title: "Co-R&BD Conference 2026 | 제1회 전문대학 산학공동 R&BD 컨퍼런스",
    description: "Co-R&BD Conference 2026 행사 안내 시안. 전문기술석사 연구와 산학공동기술개발과제의 만남.",
  },
  cfp: {
    title: "논문·현장사례 모집 | Co-R&BD Conference 2026",
    description: "Co-R&BD Conference 2026 논문·현장사례 모집공고 초안. 전문기술석사 연구와 산학공동기술개발과제의 만남.",
  },
  program: {
    title: "프로그램·연사 | Co-R&BD Conference",
    description: "Co-R&BD Conference 연도별 확정 프로그램과 연사 안내",
  },
  edition: {
    title: "학회 안내 | Co-R&BD Conference",
    description: "Co-R&BD Conference 연도별 행사 안내와 공개 기록",
  },
  archive: {
    title: "지난 학회 | Co-R&BD Conference",
    description: "Co-R&BD Conference 연도별 지난 학회 기록",
  },
  submission: {
    title: "논문 투고·심사 | Co-R&BD Conference",
    description: "Co-R&BD Conference 논문·현장사례 투고 및 심사",
  },
  registration: {
    title: "참가 신청 | Co-R&BD Conference",
    description: "Co-R&BD Conference 일반 참가 신청",
  },
  operations: {
    title: "참가·프로그램 관리 | Co-R&BD Conference",
    robots: { index: false, follow: false },
  },
  monitor: {
    title: "참가·투고 현황 | Co-R&BD Conference",
    robots: { index: false, follow: false },
  },
  privacy: {
    title: "개인정보처리방침 | Co-R&BD Conference 2026",
    description: "Co-R&BD Conference 2026 투고·심사 서비스의 개인정보처리방침",
  },
  terms: {
    title: "서비스 이용약관 | Co-R&BD Conference 2026",
    description: "Co-R&BD Conference 2026 투고·심사 서비스의 이용약관",
  },
  "cmt-reference": {
    title: "CMT 참고·감사 안내 | Co-R&BD Conference 2026",
    description: "Co-R&BD Conference 2026 논문 투고·심사 시스템의 CMT 참고 자료와 운영 주체 안내",
  },
};

export function isPageId(value: string): value is PageId {
  return PAGE_IDS.some((pageId) => pageId === value);
}

export function pageBody(pageId: PageId): string {
  return readFileSync(path.join(process.cwd(), "content", pageId + ".html"), "utf8");
}

export function pageScript(pageId: PageId): string | undefined {
  return PAGE_SCRIPTS[pageId];
}

export function pageMetadata(pageId: PageId): Metadata {
  return PAGE_METADATA[pageId];
}
