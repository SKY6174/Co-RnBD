# Conference operations — design

## Data model

- `conference_settings`: add `registration_open` (false by default) and `registration_deadline` (initially 2026-10-30 18:00 KST; revised to 2027-01-05 18:00 KST with registration opened by the October 13, 2026 user instruction).
- `attendee_registrations`: one row per Auth user; category (`student`, `faculty`, `industry`, `other`), requested days as a constrained date array, status (`applied`, `confirmed`, `cancelled`), and optional chair check-in timestamp. Names and emails remain in `profiles`.
- `program_speakers`: name, affiliation, short bio, publication flag. Chair writes, public reads only published records.
- `program_sessions`: title, type, start/end, room, summary, publication flag. A published session must have required schedule details.
- `program_session_speakers`: ordered many-to-many links. The public can read links only when both the session and speaker are published.

## Access and workflow

Authenticated members apply or cancel their own registrations. A trigger validates the registration window and prevents member confirmation/check-in and identity changes. Chair can read all applications, confirm/cancel, and check in. Unique `user_id` prevents duplicates. No payment, ticket number, or auto-email.

`program.html` renders only published sessions and their published speaker details. Chair uses `operations.html` to create/edit speakers and sessions, set speaker links, and publish once confirmed. Drafts are never visible to anonymous visitors. The chair can see drafts. The program starts empty rather than inventing names, rooms, or talk times.

`registration.html` uses the existing Supabase session. Unauthenticated visitors can start Google or Naver OAuth directly on the registration page and return there after authentication; the existing submission portal remains the email login and signup entry point. Provider availability follows the submission portal's Google Auth settings and Naver site configuration. Logged-in visitors can sign out here, immediately clearing their registration details and form from the page. The registration form reuses profile name, affiliation, and email and requires completeness. Application success means pending review; the chair explicitly confirms. Registration has no fee field until fees are approved.

## Verification

Validate schema and RLS with a rollback-only SQL transaction or local database, inspect public and member UI at desktop/mobile widths, run `node --check`, check HTML links/IDs, and inspect a Preview without writing real attendee records.

## 시범 운영 접수와 통합 관리 메뉴

2026 회차의 일반 참가신청은 기존 확정 마감(2027-01-05 18:00 KST)과 열린 상태를 유지한다. 논문투고는 위원장 승인에 따라 시범 운영 상태로 열며, 공식 접수 일정과 구별되는 공개 안내문을 표시한다. 심사와 최종본 단계는 원고 접수와 별개로 닫힌 상태를 유지한다. 시범 데이터도 운영 DB의 실제 개인정보와 원고이므로 공개 화면에 그 성격을 명확히 밝히고, 자동 삭제 또는 공식 접수 전환을 약속하지 않는다.

`operations.html`을 위원장 통합 운영 메뉴로 사용한다. 논문투고 설정(원고 접수·심사·최종본, 마감, 공개 안내문)과 일반 참가신청 설정(열림, 확정 마감)을 같은 화면에서 관리한다. 원고 배정·판정은 기존 투고 화면의 위원장 탭, 참가자 확정·체크인은 기존 운영 화면에서 수행한다. 로그인한 위원장에게만 운영 메뉴 링크를 보여 주며, 실제 쓰기 권한은 기존 `conference_settings`의 위원장 RLS가 강제한다. 일반 사용자에게는 운영 컨트롤과 참가자 목록을 노출하지 않는다.
