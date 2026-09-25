# 논문 투고·심사 시스템 설계

## 구조
기존 `site/` 정적 사이트에 `submission.html`, `submission.js`, `submission.css`를 추가한다. Vercel 함수 `site/api/config.js`는 기존 Vercel 환경변수의 **공개 가능** Supabase URL·publishable key만 브라우저에 제공한다. 브라우저는 `@supabase/supabase-js` 고정 버전으로 Auth, Data API, Storage에 직접 연결한다. 권한은 화면이 아니라 Postgres RLS가 강제한다.

## 데이터 관계
`auth.users` 1:1 `profiles`; `profiles` 1:N `papers`(교신저자); `papers` 1:N `paper_authors`, `paper_files`, `reviews`. `staff_roles`는 위원장 권한만 저장한다. `reviews` 한 행은 배정과 평가를 겸하고 `(paper_id, reviewer_id)` 유일하다. 파일은 private `paper-pdfs` 버킷의 `{user_id}/{paper_id}/{uuid}.pdf`에 버전별로 저장한다.

## 상태와 화면
- 저자: 로그인 → 프로필 → 초안 생성(제목·초록·유형·분야·발표 희망) → 저자 입력 → PDF 업로드 → 제출. 제출 후 상태 조회, 위원장이 `revision`으로 돌린 경우 수정·재제출.
- 심사위원: 배정 목록 → 원고/PDF 열람 → `accept`/`revise`/`reject` 권고 및 의견 저장. 점수표 없이 간결하게 운영.
- 위원장: 접수 목록 → 등록 계정에서 심사위원 배정 → 원고/심사 조회 → `accepted`/`revision`/`rejected` 판정, 발표형태 기록.
- 원고 상태: `draft`, `submitted`, `under_review`, `revision`, `accepted`, `rejected`. 저자는 `draft` 또는 `revision`만 수정하며 `submitted`로 재제출한다. 위원장이 나머지 전이를 관리한다.

## 권한과 보안
OAuth는 Google 기본 provider와 Naver 사용자 지정 `custom:naver` provider를 사용한다. OAuth 설정·Secret은 Supabase 대시보드에 두며 웹 코드에 넣지 않는다. `profiles`는 본인 수정, 위원장 조회. 원고·저자·파일 메타데이터는 소유자, 배정 심사위원, 위원장만 조회. 원고 수정과 업로드는 소유자 및 수정 가능 상태로 제한. 심사는 해당 심사위원이 자기 배정 행만 갱신하고, 위원장은 전체 조회·배정 가능. 비공개 Storage도 동일한 조회 범위. 위원장 지정은 서비스 운영자가 `staff_roles`에 Auth 사용자 ID를 직접 등록하며 웹에서 셀프 승격은 불가. 제출시 PDF 1개 이상 필수.

## 데이터 흐름 및 검증
클라이언트는 Supabase PKCE OAuth 후 세션을 회복하고, `papers`/`paper_authors`/`paper_files`/`reviews`를 Data API로 접근한다. 파일 크기는 20 MiB, MIME은 PDF로 제한한다. UI는 필수값, 길이, 파일 형식을 검사하고 DB 제약으로 재검증한다. 파일 업로드 성공 뒤 메타데이터 삽입이 실패하면 업로드 파일을 삭제한다. 오류는 화면에 알린다.

## 설정·배포
마이그레이션으로 테이블, RLS, 버킷을 만든다. Google/Naver 앱과 허용 리다이렉트 URL은 대시보드에서 설정한다. 행사 일정은 CFP의 가안이며 UI에 확정 마감으로 표기하지 않는다. 기본 운영은 접수 기능을 준비 상태로 배포하고, 운영자가 `conference_settings.submissions_open`을 켜야 실제 제출된다.

## 확인
SQL 마이그레이션 구문 검사, 정적 JS 문법 검사, 390px·데스크톱 렌더 확인, 미로그인/역할별 접근과 파일 다운로드 확인. 실제 OAuth 통합은 제공자 자격증명 등록 후 검증한다.
