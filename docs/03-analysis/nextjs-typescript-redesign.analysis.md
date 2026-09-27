# Next.js·TypeScript 전환 Gap Analysis

> 2026-09-27 · 설계: `docs/02-design/features/nextjs-typescript-redesign.design.md`

## 설계 일치도: 10/10 (100%)

| 설계 항목 | 결과 |
|---|---|
| `site/` Next.js 16·TypeScript 앱 | 구현, 타입 검사·프로덕션 빌드 통과 |
| 공개/포털 11개 페이지 라우트 | 구현, 정적 페이지 생성 |
| 기존 `.html` URL과 OAuth 회귀 경로 | rewrite 구현, 로컬 HTTP 12개 경로 확인 |
| 메타데이터와 위원장 화면 noindex | 타입이 있는 목록에 보존 |
| 공통 CSS·이미지·favicon | 이전, 로컬·Preview 응답 확인 |
| 홈·CFP 메뉴/탭 | TypeScript 클라이언트 컴포넌트, 모바일 실제 동작 확인 |
| 투고·등록·운영 데이터 클라이언트 | 기존 DOM 계약과 스크립트 보존, 로컬에서 설정 오류 상태 확인 |
| API config·Naver 사용자 정보 | TypeScript Route Handler, 로컬 200/401/405 및 Preview config 200 확인 |
| Supabase 스키마·RLS·Storage 무변경 | 관련 마이그레이션 없음, Preview에서 운영 데이터 쓰기 없음 |
| Vercel Preview | 프로젝트 Framework Preset을 Next.js로 변경 후 Preview 배포 Ready 및 읽기 경로 확인 |

## 검증 근거

- `npm ci`, `npm run typecheck`, `npm run build` 통과.
- 기존 HTML 경로 12개, 공개 이미지와 스크립트, API 오류 응답을 로컬 HTTP로 확인.
- 데스크톱과 390px에서 홈·CFP·투고 화면, 메뉴·날짜 탭, 가로 넘침 확인.
- HTML ID 중복과 페이지 내부 앵커 검사 통과, `git diff --check` 통과.
- Vercel Preview 배포 `3yekWJHgyffAHqUweEeWGZnuvAj9` Ready. `/`, `/cfp.html`, `/submission.html`, `/registration.html`, `/operations.html`, 이미지, 스크립트와 `/api/config`가 인증된 Preview 요청에 200으로 응답.

## 운영 검증 제한

Preview는 운영 Supabase `lvtdnrmwunahgwutafhv.supabase.co`를 사용한다. 따라서 회원가입, OAuth, 원고 업로드, 심사, 참가 신청 및 위원장 쓰기 흐름은 테스트하지 않았다. 기존 DOM 클라이언트는 호환 계층으로 유지되며 향후 별도의 안전한 환경에서 역할별 통합 검증이 필요하다. `main` 병합과 프로덕션 배포는 수행하지 않았다.
