# Next.js·TypeScript 전환 설계

> 2026-09-27 · [기획](../../01-plan/features/nextjs-typescript-redesign.plan.md) · 배포 루트 `site/`

## 구조

`site/`에 Next.js 16 App Router와 TypeScript를 설치한다. 서버 컴포넌트는 저장소에 있는 승인된 HTML 본문 조각을 빌드 시 읽어 렌더링한다. `app/page.tsx`와 각 공개·포털 경로의 `page.tsx`가 명시적 라우트다. 메타데이터와 페이지별 클라이언트 엔트리는 타입이 있는 단일 라우트 목록에서 관리한다. 홈·CFP의 메뉴와 탭은 TypeScript 클라이언트 컴포넌트로 관리한다. 데이터 포털의 기존 브라우저 코드는 `public/legacy/`로 옮겨 DOM ID와 Supabase 직접 연결을 유지한다. 이는 인증·심사·위원장 기능의 안전한 첫 프레임워크 전환을 위한 호환성 계층이다. 신규 화면과 데이터 접근 코드는 TypeScript로 작성한다.

`next.config.ts`에서 `/index.html`와 각 기존 `/*.html`를 대응하는 App Router 경로로 rewrite한다. 따라서 기존 공유 링크와 Supabase Auth 회귀 URL을 바꾸지 않는다. `public/assets/`와 `public/favicon.png`를 사용한다. 공통 글로벌 CSS는 루트 layout에서 로드한다. 2026 CFP 문안과 확정/가안 표기는 그대로 둔다.

## 경로

| 기존 URL | Next 경로 | 클라이언트 동작 |
|---|---|---|
| `/`, `/index.html` | `/` | 홈 메뉴·프로그램 탭·현재 회차 확인 |
| `/cfp.html` | `/cfp` | 홈 메뉴 |
| `/program.html` | `/program` | 공개 세션·연사 |
| `/edition.html` | `/edition` | 현재/지난 회차 정보 |
| `/archive.html` | `/archive` | 공개 지난 학회 |
| `/submission.html` | `/submission` | Auth·투고·심사·위원장 |
| `/registration.html` | `/registration` | 일반 참가 신청 |
| `/operations.html` | `/operations` | 위원장 운영 |
| `/privacy.html`, `/terms.html`, `/cmt-reference.html` | 대응 경로 | 정적 안내 |

## 데이터와 API

기존 DB 관계, RLS와 Storage 정책은 변경하지 않는다. 클라이언트는 `/api/config`에서 공개 가능 Supabase URL·publishable key·Naver 활성화 여부만 읽고 각 사용자의 JWT로 Supabase Data API를 호출한다. `/api/config`와 `/api/naver-userinfo`는 TypeScript Route Handler로 옮기고 기존 GET 응답, 405/401/502/503 상태를 유지한다. Naver access token은 서버에서 프로필 조회에만 사용하며 로그 또는 응답에 포함하지 않는다. 어떤 Route Handler도 service-role key를 사용하지 않는다.

## 구현 순서

1. 패키지·TypeScript 설정, App Router layout/라우트/메타데이터와 호환 URL을 추가한다.
2. 기존 HTML 본문·자산·브라우저 스크립트를 앱의 콘텐츠와 public 디렉터리로 옮긴다.
3. 두 API를 타입이 있는 Route Handler로 전환하고 운영 문서를 갱신한다.
4. 타입 검사·빌드·HTTP 경로 및 오류 응답 검사 후 Preview를 확인한다.

## 검증과 배포

`npm ci`, `npm run typecheck`, `npm run build` 후 로컬 서버에서 기존 모든 HTML 경로, CSS·이미지·스크립트 응답, 두 API의 오류 상태를 확인한다. 데스크톱과 390px 폭에서 홈·CFP·포털을 검사한다. 실계정 가입·원고·참가 신청 등 운영 DB 쓰기는 Preview에서 하지 않는다. 브랜치를 푸시하고 PR을 생성해 Vercel Preview를 확인한다. 배포 루트와 환경변수 이름은 그대로다.

## 롤백

`main` 배포 전에는 브랜치를 사용하지 않으면 된다. 이후 배포가 승인될 경우 기존 커밋으로 Vercel rollback 가능하다. DB 변경이 없으므로 데이터 마이그레이션 롤백은 없다.
