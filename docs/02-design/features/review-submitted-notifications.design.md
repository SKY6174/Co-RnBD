# 심사의견 제출 알림 — Design

기존 [이메일 설계](review-email-notifications.design.md)를 확장한다. 새 외부 서비스·키·공개 RPC는 추가하지 않는다.

## 이벤트와 수신자

`paper_events.review_submitted`의 after/before snapshot을 비교한다. 최초 submitted 전환 또는 comments/recommendation 변경만 대상이다. 기존 감사 이벤트 생성과 심사 저장 규칙은 바꾸지 않는다. 같은 트랜잭션에서 새 outbox를 생성하므로 롤백 시 메일도 발생하지 않는다.

private `review_submission_recipients(paper_id)`는 현재 회차의 접수된 원고에 대해 다음을 반환한다.

- 해당 회차·분야의 활성 AE. 인증된 계정 이메일로 명부와 연결하고 저자/공동저자/모든 제출본의 이해관계 거절 계정은 제외한다.
- private config의 `review_submitted_chair_ids`에 운영자가 지정한 계정 중 실제 chair 권한·인증 이메일이 있는 계정.
- 주소를 소문자로 정규화하고 같은 주소의 겸임은 한 통으로 합친다. 제출자가 AE를 겸해도 해당 역할 자격이 있으면 통보한다.

심사위원장 권한과 알림 수신 설정은 구별한다. 기존 지정 수신 계정을 기본으로 준비하며 운영자의 선택을 설정에 반영한다. UUID 목록은 private config에 두고 각 조회 시 staff_roles와 다시 대조한다. helper execute는 public/anon/authenticated에 주지 않는다.

## 큐·전송·권한

새 kind는 `review_submitted`, payload version은 **2**다. v1 배정/판정 메일의 렌더링은 유지해 기존 재시도 본문이 달라지지 않게 한다. 이벤트 UUID + 수신자 UUID가 unique event key다. payload에는 기존 공통 원고 정보와 reviewId, reviewFingerprint(md5로 내용 snapshot 비교), 빈 note를 저장한다. 심사 원문·추천 값·제출자 신원은 메일/외부 provider에 전달하지 않는다.

worker는 해당 심사가 현재 제출본의 유효한 submitted 상태인지, 현재 추천·의견 fingerprint가 같은지, 수신자가 여전히 helper의 반환 대상인지 확인한다. 철회·거절·새 제출본·내용 변경은 obsolete로, AE/위원장 권한 회수·분야 변경·공동저자 변경·이메일 변경은 취소로 처리한다. 판정 후에도 같은 제출본의 제출 사실은 유효하며 포털의 최신 상태를 확인하도록 안내한다.

기존 private outbox/RLS/상태 RPC/인증 hook/8회 재시도/23시간 cutoff/provider idempotency를 재사용한다. 메일은 ‘심사의견 제출 알림’, 학회·분야·원고 제목·접수번호와 고정 `/chair.html` 링크를 포함한다. 수신자별 개별 전송이며 다른 수신 주소를 노출하지 않는다. 화면에는 새 종류를 ‘심사의견 제출 알림’으로 구분한다.

## 적용과 검증

- config에 `review_submitted_enabled=false`, `review_submitted_chair_ids={}`를 추가한다. 새 flag가 false이면 enqueue와 새 kind dispatch를 건너뛰되 기존 배정·판정 큐 처리는 계속한다.
- production migration과 배포 후 지정 chair UUID/권한·인증 여부를 확인해 flag를 켠다. 기존 auth SMTP·hook secret·Resend key·단계 설정은 유지한다. 롤백은 새 flag만 false로 하고 이전 배포를 복원한다. 기록을 삭제하지 않는다.
- 로컬: 최초/수정 제출, draft·동일 저장 제외, 분야 AE·위원장·겸임 중복, 잘못된 분야·비활성·미인증·저자/공동저자·거절 AE 제외, 권한 회수/이메일 변경/이전 제출본/변경 의견 취소, 트랜잭션 롤백·동일 이벤트 중복, 재시도·v1 회귀를 검증한다.
- 실제 브라우저/Auth/DB/Storage → pg_net → Next → loopback 메일 수집기로 두 분야의 제출/재심 흐름과 화면의 새 종류를 확인한다. HTML/JS/TS/build/diff 검사와 운영 schema/grants/cron을 확인한다.
- Preview는 운영 DB를 사용하면 쓰지 않는다. 운영에는 실제 원고를 테스트로 만들지 않고 지정 계정의 `is_test=true` 제출 알림 양식만 발송해 provider Delivered를 확인한다.

참고: [Supabase trigger](https://supabase.com/docs/guides/database/postgres/triggers), [pg_net](https://supabase.com/docs/guides/database/extensions/pg_net).
