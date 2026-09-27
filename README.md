# Co-R&BD Conference

제1회 전문대학 산학공동 R&BD 컨퍼런스의 공개 안내 사이트와 논문·현장사례 모집공고 초안입니다. 행사일은 **2026년 12월 17–18일**, 장소는 **울산과학대학교 동부캠퍼스**입니다. 일반 참가신청 마감은 **2026년 10월 30일(금) 18:00 KST**이며, 발표자는 채택 후 별도 등록합니다.

## 연도별 운영

2026은 첫 회차입니다. Supabase의 `conference_editions`가 연도별 행사 정보와 상태(준비 중·현재·지난 학회)를 보관합니다. 투고 원고, 참가 신청, 연사, 세션과 운영 설정은 각 회차에 연결됩니다. 위원장은 [운영 화면](https://co-rnbd.org/operations.html)에서 2027 이후 회차를 미리 만들고 날짜·장소를 입력할 수 있습니다. 기존 회차가 끝난 뒤 새 회차를 활성화하면 이전 회차의 접수·심사·등록이 닫힙니다.

공개가 승인된 종료 회차만 [지난 학회](https://co-rnbd.org/archive.html)에 표시됩니다. 이 화면은 공개 행사 정보와 확정 프로그램만 보여 줍니다. 원고 PDF, 심사 내용, 참가자 목록은 아카이브에서 공개하지 않습니다. 새 연도를 실제로 열기 전에는 그해의 모집공고, 개인정보 안내, 운영 일정과 자료집 공개 범위를 별도로 확정해야 합니다.

마이그레이션: `supabase/migrations/20260927014640_annual_conferences.sql`. 2026 운영 데이터는 이 마이그레이션에서 2026 회차로 자동 연결되며, 운영 Supabase DB에 적용했습니다.

- 공개 사이트: [`site/`](site/README.md)
- 국·영문 CFP 원문: [`outputs/co-rbd-2026-cfp-draft.md`](outputs/co-rbd-2026-cfp-draft.md)
- 행사 기획·설계: [`docs/`](docs/02-design/features/college-tech-conference-2026.design.md)

## 로컬 개발

```sh
cd site
npm ci
npm run dev
```

`http://localhost:3000/`에서 첫 화면을, `/cfp.html`에서 모집공고 전문을 볼 수 있습니다. TypeScript 검사는 `npm run typecheck`, 배포 빌드는 `npm run build`입니다. 로컬 Supabase 연결은 루트 `.env.example`을 참고해 `site/.env.local`에 공개 가능 설정만 입력합니다.

## 서비스 연결

| 서비스 | 연결 대상 | 현재 역할 |
|---|---|---|
| GitHub | `SKY6174/Co-RnBD` · `main` | 소스 및 CFP 버전 관리 |
| Vercel | `ucsky6174/co-rnbd` · 루트 `site/` · `co-rnbd.org` | Next.js App Router 배포 |
| Supabase | `Co-RnBD/Co-RnBD-2026` · ref `lvtdnrmwunahgwutafhv` | Auth·Postgres·비공개 PDF Storage |

Vercel에는 `SUPABASE_URL`과 `SUPABASE_PUBLISHABLE_KEY`가 설정되어 있습니다. 로컬 연결은 `supabase link --project-ref lvtdnrmwunahgwutafhv`로 재현할 수 있습니다. 키 값과 `.env.local`은 Git에 올리지 않습니다.

## 논문 투고·심사

[`/submission.html`](https://co-rnbd.org/submission.html)은 저자·심사위원·위원장 작업 공간입니다. 이메일·비밀번호 가입/로그인/재설정과 Google/Naver 로그인 연결을 지원합니다. 원고, 공동저자, PDF 버전, 심사 배정과 판정은 Supabase Postgres·비공개 Storage에 저장되며 RLS가 역할별 접근을 제한합니다. 참가등록과 투고는 별개입니다.

DB 마이그레이션은 `supabase/migrations/`에 있고 연결된 `Co-RnBD-2026` 프로젝트에 적용했습니다. 접수 스위치는 기본적으로 **닫힘**입니다. 논문 일정·주최기관·개인정보 보존 기준이 확정되면 위원장 계정에서 접수를 열 수 있습니다. Google/Naver OAuth 제공자 등록과 최초 위원장 지정 방법은 [운영 설정](site/README.md#투고-시스템-운영-설정)에 있습니다.

Next.js Route Handler가 `/api/config`와 `/api/naver-userinfo`를 제공합니다. 로컬 공개 설정이 없으면 데이터 화면에는 연결 안내가 표시되며, 실제 투고 흐름은 별도의 안전한 Supabase 환경에서 검증해야 합니다.
