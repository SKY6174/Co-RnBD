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

## 운영 현황

- `staff.html`에 등록 현황, 논문 제출 현황, 심사위원, 좌장 메뉴를 둔다. 선택한 메뉴로 바로 연결할 수 있으며 읽을 때마다 기존 명단 RPC가 열람을 기록한다. 투고·심사 페이지의 메뉴는 현재 회차의 `staff_my_access` 또는 위원장 역할을 확인한 계정에 표시한다. 위원장 화면에서도 같은 메뉴로 연결한다.
- 등록 집계는 취소를 제외한 유효 등록, 확인 대기, 참가 확정, 체크인을 표시한다. 납부 상태와 확정 인원의 참가일 분포, 일반 참가·발표자·참가일 필터를 제공한다.
- 논문은 초안을 제외한다. 현재 제출본의 유효 배정이 없으면 심사 전, 배정 후 의견 2건 미만이면 심사 중, 2건 이상이면 판정 대기다. 수정 요청·채택·반려는 심사 후, 철회는 별도로 표시한다. 재제출 후 이전 제출본의 의견은 집계하지 않는다.
- 기존 `staff_list_submissions`의 반환 계약에 채택 원고의 `final_presentation`을 추가한다. 희망 발표 유형과 확정 유형은 각각 집계·필터링한다. 채택 원고에 확정값이 없으면 미확정으로 표시한다. 기존 명단에 없던 개인 정보나 심사 자료는 반환하지 않는다.
- 화면은 우선 선택한 명단만 불러오며 새로고침·검색·필터와 상세 목록 페이지 이동을 제공한다. 슈퍼 관리자는 기존 `monitor.html`의 초안 현황에도 접근할 수 있다.
