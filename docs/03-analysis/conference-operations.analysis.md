# Conference operations — implementation check

## Matched design

- Single-conference attendee registration is separate from papers and references the existing profile.
- A unique user key prevents duplicate applications. The member sees their status and can cancel; the chair can confirm and check in.
- Speakers, sessions, and their ordered links are chair managed. Public queries return published records only.
- The public pages show an explicit empty state and distinguish the provisional homepage timetable from confirmed program entries.
- Registration remains closed by default. No fees, payment flow, automatic email, or invented speaker/session data were added.

## Verification

- JavaScript syntax checked with `node --check`.
- PostgreSQL migration parsed and executed in isolated PGlite. RLS probes confirmed member confirmation and registering another user were denied; chair confirmation was allowed; anonymous registration reads were denied; anonymous program reads returned only published records and links.
- HTML local references and duplicate IDs checked. `git diff --cached --check` passed.
- Desktop and 390px mobile pages inspected in a browser; no horizontal overflow on the inspected pages.

## Production database verification

On 2026-09-27, the additive migration was applied to the connected Supabase project under remote version `20260927010351`. All four new tables have RLS enabled, 15 operations policies are present, registration remains closed, and attendee and session counts are both zero. The Vercel Preview now reads an empty public program and the closed registration state without a schema error. No real participant write was performed. Full account-to-database verification awaits site deployment and an appropriate test account.

## 운영 현황 검증 (2026-11-23)

- 설계와 대조해 현재 회차의 등록·논문 집계, 발표 유형 구분, 필터 및 명단 메뉴가 일치함을 확인했다.
- 격리 Supabase에 전체 마이그레이션을 적용했다. SQL 테스트에서 비회원·일반 회원·만료 및 회수 권한 차단, 회차 격리, 조회 기록, 현재 제출본 심사 집계와 확정 발표 유형을 검증했다.
- Chromium과 WebKit에서 실제 로컬 로그인, 사무국과 위원장 메뉴, 검색·필터, 합성 제출 원고 507건의 조회 및 페이지 이동을 확인했다. 데스크톱과 390px 화면에서 접근성 자동 검사와 가로 넘침 검사가 통과했다. 좁은 화면 상세 표의 방향키 이동도 확인했다.
- 운영 적용 순서는 `20261123020423_staff_dashboard_presentation.sql` 적용 후 사이트 배포다. 운영 Supabase 조회는 기존 함수 계약 확인에 사용했다.
