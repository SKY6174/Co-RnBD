# 투고자 접수 확인 이메일 — Design

기존 [투고 알림](paper-submitted-notifications.design.md)과 같은 `paper_events.paper_submitted`를 사용한다.

## 수신자·원자성

before.status=draft/revision, after.status=submitted 및 현재 제출 시각 일치인 정상 이벤트에서만 생성한다.
수신자는 papers.owner_id의 인증된 auth.users.email이며 연락 이메일·공동저자에 자동 확장하지 않는다.
미인증/부정확한 주소는 안전한 실패 상태로 남기고 원고 저장을 막지 않는다. 저장과 outbox는 같은 트랜잭션이다.

새 kind는 `author_submission_receipt`, `author_resubmission_receipt`, payload는 version=4다.
원고 UUID + UTC 마이크로초 제출 시각 + 소유자 UUID를 unique key로 사용해 같은 제출본 replay를 합친다.
기존 이벤트 UUID, manuscriptAt, 공통 원고 정보와 빈 note/exceptionReason을 snapshot으로 저장한다.

접수 확인은 과거 완료 사실이므로 이후 재제출·판정으로 취소하지 않는다. dispatch에서 현재 소유자/인증 이메일,
실제 paper_submitted 이벤트의 ID·원고·이전 상태·해당 제출 시각을 대조한다. 소유권/이메일 변경, 삭제되거나
맞지 않는 제출 증거는 취소한다. 본문에 고정 KST 접수 시각과 해당 제출본의 접수 확인임을 명시한다.

## 메일·독립 제어

v1/v2/v3 렌더링을 유지하고 v4 양식만 추가한다. 제목은 신규 투고 접수 확인/수정본 재제출 접수 확인,
본문은 학회·제목·접수번호·분야·고정 수치 KST 접수 시각과 `/submission.html` 링크다. PDF·초록·심사 결과는
넣지 않는다. 시험 메일은 실제 원고 접수가 아님을 표시한다. 접수와 심사 진행·판정 확인을 구분해 안내한다.

`author_receipt_enabled=false`를 private config에 추가하며 기존 알림과 독립적으로 활성화·중지한다.
새 trigger는 enqueue만 하고 기존 dispatcher/cron이 처리해 한 제출에서 두 번 즉시 dispatch하지 않는다.
심사 관리의 기존 상태 목록에 새 종류와 종류별 활성 상태를 표시한다. 저자 UI에는 접수 확인 안내 문구만 추가한다.

## 검증·롤백

로컬 실제 두 분야 신규 투고 2건·수정본 1건에서 owner 확인 3건과 기존 모든 알림을 검증한다.
v1~v4 각각 응답 유실·동일 키/본문 복구, draft/실패/임시저장/replay 제외, 연락처/공동저자 비수신,
과거 제출본 유효성, 소유권·이메일·증거 변경 취소, flag·상태 RPC·권한을 rollback SQL로 확인한다.
TS/build/JS/HTML IDs/diff 및 desktop/mobile도 검증한다. 운영은 flag=false migration → 코드 배포 → 활성화 →
기존 지정 테스트 계정으로 신규/수정본 양식 각 1통을 보내 Delivered와 DB 기록을 대조한다. 실제 논문은 만들지 않는다.
롤백은 새 flag=false와 이전 서버 배포 복원이다. 기존 AE·위원장 알림과 발송 기록을 보존하며 키/SMTP는 재설정하지 않는다.
