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

## CMT 참고 운영 흐름
공개 투고 화면에 CFP·가안 일정으로 이동하는 링크와 저자/심사위원 안내를 둔다. 저자 안내는 계정 생성, 분야·제목·초록·공동저자 정보 확인, PDF 형식과 20 MB 제한, 초안 저장과 제출의 차이, 접수번호·상태 확인, 수정 요청 후 재제출 순서로 쓴다. 공동저자 이메일은 실제 계정이나 수신 여부가 자동 검증되지 않음을 명시한다. 심사 안내는 배정 확인, 저자·소속을 보고 이해관계 확인, PDF 열람, 의견 임시저장, 권고 제출, 위원장 판정 순서로 쓴다. CMT의 사이트 개설 요청이나 특정 대학 이메일 제한, 별도 CMT 계정, 실제 CMT 서비스 사용을 주장하는 공식 감사 문구는 이 자체 운영 시스템에 적용하지 않는다. 일정과 프로그램위원회 연락처는 확정 전이므로 임의의 확정 정보로 표시하지 않는다.

공개 `cmt-reference.html`에는 CMT 공개 도움말을 설계 참고 자료로 사용한 사실과 감사, 참고한 범위, 공식 문서 링크를 정적 HTML로 표시한다. 동시에 실제 투고·심사는 Co-R&BD 자체 Supabase 기반 시스템이 운영하며 CMT나 Microsoft가 이 서비스를 운영하지 않는다고 명시한다. 투고 화면과 홈·모집공고의 하단에서 이 페이지로 연결한다. CMT 서비스 사용을 전제로 한 공식 감사 문구를 자체 시스템의 사용 사실처럼 게시하지 않는다.

심사 행은 `review_state`(`assigned`/`draft`/`submitted`/`declined`), `decline_reason`, `declined_at`을 가진다. 심사위원은 진행 중인 배정에서 임시저장하거나 권고·의견·이해관계 없음 확인을 갖춰 제출한다. 이해관계가 있으면 사유를 적어 배정을 거절할 수 있다. 거절 후에는 해당 원고와 PDF 열람 권한이 사라지고 위원장에게는 거절 사유가 표시되어 다른 심사위원을 배정할 수 있다. 기존 권고가 저장된 행은 마이그레이션 때 `submitted`로 옮긴다. 위원장 화면은 심사 상태를 구분하고 제출된 의견만 판정 근거로 표시한다.

참고: [CMT 사이트 요청 안내](https://cmt3.research.microsoft.com/docs/help/general/request-conference.html), [CMT 저자 투고 안내](https://cmt3.research.microsoft.com/docs/help/author/author-submission-form.html), [CMT 심사위원 안내](https://cmt3.research.microsoft.com/docs/help/reviewer/reviewing-guide.html).

## 권한과 보안
이메일 가입은 로그인과 분리된 화면에서 이메일, 10자 이상 비밀번호, 비밀번호 확인을 받아 `signUp`을 호출한다. 신규 계정의 확인 메일을 보낸 뒤에는 인증 대기 상태로 표시하고, 메일의 `auth-signup` 링크를 `verifyOtp`로 검증한 후에만 가입 완료와 작업 공간을 표시한다. 이미 확인된 계정의 재가입 요청은 Supabase의 계정 존재 숨김 응답을 고려해 메일 발송을 단정하지 않고 기존 계정 로그인·비밀번호 재설정을 안내한다. Google·Naver 연동 로그인은 기존 흐름을 유지한다.
신규 이메일 가입과 비밀번호 재설정의 비밀번호는 최소 10자로 제한한다. 기존 계정 로그인에는 새 길이 제한을 적용하지 않는다. 이메일 인증·매직 로그인·비밀번호 재설정 메일의 링크는 `submission.html#auth-signup=...`, `#auth-magiclink=...`, `#auth-recovery=...` 형식으로 토큰 해시 하나만 전달한다. 투고 화면은 링크 종류에 맞춰 Supabase `verifyOtp`를 호출하고 성공 후 URL 조각을 제거한다. 이는 메일 클라이언트가 HTML 링크의 `&amp;`를 변형해 인증을 실패시키는 경우를 피한다.
이메일·비밀번호 가입/로그인은 Supabase Auth를 사용한다. 확인 메일을 거쳐 로그인하며 비밀번호 재설정 링크는 동일한 투고 화면의 새 비밀번호 입력 폼으로 돌아온다. 비밀번호는 브라우저 상태나 DB 테이블에 별도 저장하지 않는다. Google 기본 provider와 Naver 사용자 지정 `custom:naver` provider도 지원한다. Naver의 중첩 프로필 응답은 Vercel 사용자 정보 함수에서 표준 필드로 변환한다. 간편 로그인 버튼은 Naver 초록색 N 및 Google의 다색 G 로고와 검은 배경을 사용하고, Kakao는 제공하지 않는다. OAuth 설정·Secret은 Supabase 대시보드에 두며 웹 코드에 넣지 않는다. `profiles`는 본인 수정, 위원장 조회. 원고·저자·파일 메타데이터는 소유자, 배정 심사위원, 위원장만 조회. 원고 수정과 업로드는 소유자 및 수정 가능 상태로 제한. 심사는 해당 심사위원이 자기 배정 행만 갱신하고, 위원장은 전체 조회·배정 가능. 비공개 Storage도 동일한 조회 범위. 위원장 지정은 서비스 운영자가 `staff_roles`에 Auth 사용자 ID를 직접 등록하며 웹에서 셀프 승격은 불가. 제출시 PDF 1개 이상 필수. 저자의 원고 생성에서는 판정용 필드를 비워야 하고, 심사위원 배정에서는 평가·이해관계 확인 필드를 비워야 한다. 원고와 심사의 ID·생성/배정 시각은 수정할 수 없다.

## 데이터 흐름 및 검증
클라이언트는 Supabase PKCE OAuth 후 세션을 회복하고, `papers`/`paper_authors`/`paper_files`/`reviews`를 Data API로 접근한다. 파일 크기는 20 MiB, MIME은 PDF로 제한한다. UI는 필수값, 길이, 파일 형식을 검사하고 DB 제약으로 재검증한다. 파일 업로드 성공 뒤 메타데이터 삽입이 실패하면 업로드 파일을 삭제한다. 오류는 화면에 알린다.

## 설정·배포
마이그레이션으로 테이블, RLS, 버킷을 만든다. 이메일 확인과 재설정 메일은 Supabase Auth가 발송하며 본운영 전에 전용 SMTP와 허용 리다이렉트 URL을 설정한다. Google/Naver 앱도 대시보드에서 설정한다. 행사 일정은 CFP의 가안이며 UI에 확정 마감으로 표기하지 않는다. 기본 운영은 접수 기능을 준비 상태로 배포하고, 운영자가 `conference_settings.submissions_open`을 켜야 실제 제출된다.

## 확인
SQL 마이그레이션 구문 검사, 정적 JS 문법 검사, 390px·데스크톱 렌더 확인, 미로그인/역할별 접근과 파일 다운로드 확인. 실제 OAuth 통합은 제공자 자격증명 등록 후 검증한다.
