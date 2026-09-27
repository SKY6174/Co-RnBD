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
| Supabase 스키마·Storage 유지 | 역할별 로컬 검증에서 발견한 RLS 순환 수정 마이그레이션 1개 추가; 운영 DB 미적용 |
| Vercel Preview | 프로젝트 Framework Preset을 Next.js로 변경 후 Preview 배포 Ready 및 읽기 경로 확인 |

## 검증 근거

- `npm ci`, `npm run typecheck`, `npm run build` 통과.
- 기존 HTML 경로 12개, 공개 이미지와 스크립트, API 오류 응답을 로컬 HTTP로 확인.
- 데스크톱과 390px에서 홈·CFP·투고 화면, 메뉴·날짜 탭, 가로 넘침 확인.
- HTML ID 중복과 페이지 내부 앵커 검사 통과, `git diff --check` 통과.
- Vercel Preview 배포 `3yekWJHgyffAHqUweEeWGZnuvAj9` Ready. `/`, `/cfp.html`, `/submission.html`, `/registration.html`, `/operations.html`, 이미지, 스크립트와 `/api/config`가 인증된 Preview 요청에 200으로 응답.

## 운영 검증 제한

Preview는 운영 Supabase `lvtdnrmwunahgwutafhv.supabase.co`를 사용한다. 따라서 Preview에서는 회원가입, OAuth, 원고 업로드, 심사, 참가 신청 및 위원장 쓰기 흐름을 테스트하지 않았다. 기존 DOM 클라이언트는 호환 계층으로 유지한다. `main` 병합과 프로덕션 배포는 수행하지 않았다.

## 2026-09-27 로컬 역할별 통합 검증

- 별도 포트의 로컬 Supabase에 기존 마이그레이션을 적용했다. `20260925190050`의 운영 전용 `public.rls_auto_enable()` 권한 회수문은 로컬에 함수가 없어 임시 복사본에서만 제외했다. 저장소의 과거 마이그레이션은 변경하지 않았다.
- 네 개의 로컬 Auth 계정으로 Data API와 비공개 Storage를 검사했다. 본인 프로필 수정, 타인 프로필 차단, 위원장만 단계 변경 가능, 저자 초안·공동저자·PDF 업로드와 제출, PDF 없는 제출 거절을 확인했다.
- 위원장 심사위원 배정에서 `42P17` RLS 순환 오류가 재현됐다. `20260927150000_fix_review_assignment_rls_cycle.sql`을 로컬에 적용한 뒤 위원장 배정, 배정 심사위원의 원고/PDF 조회, 심사 제출, 위원장 판정이 통과했다. 미배정 사용자의 조회·다운로드와 저자의 배정·판정 변경은 차단됐다.
- 이해관계로 배정을 거절하면 심사위원의 원고·PDF 접근이 사라지고 저자 접근은 유지됐다. 로컬 Next.js 화면에서도 저자·심사위원·위원장 작업 공간과 배정 목록을 확인했다.
- 운영 DB의 정책은 읽기 전용으로 확인했으며 같은 순환 구조다. 새 마이그레이션은 운영 DB에 적용하지 않았다. OAuth 공급자, 실메일, 참가 신청과 운영 Preview의 실제 쓰기 동작은 검증 범위 밖이다.
