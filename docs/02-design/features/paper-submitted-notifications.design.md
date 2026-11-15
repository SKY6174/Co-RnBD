# 신규 투고·수정본 재제출 알림 — Design

기존 [심사 이메일](review-email-notifications.design.md)과 [편집 담당자 통보](review-submitted-notifications.design.md)를 확장한다.

## 이벤트·수신자

`paper_events.paper_submitted`의 before.status가 draft이면 `paper_submitted`, revision이면 `paper_resubmitted`로 기록한다. after.status=submitted 및 실제 papers.submitted_at 일치를 확인한다. 기존 제출 저장/RLS/파일·저자 검증·감사 트리거를 바꾸지 않는다.

`app_private.review_submission_recipients(paper_id)`를 공통 편집 담당자 선택기로 재사용한다. 현재 회차·분야의 활성/인증 AE와 `review_submitted_chair_ids`에 지정된 실제 chair만 대상이며, 기존 AE의 저자/공동저자/이해관계 거절 제외 및 주소별 중복 제거를 따른다. 운영 위원장 수신은 사용자가 확정한 한 계정을 유지한다.

## 큐·메일·상태

신규 두 kind는 payload **version=3**이다. 기존 v1/v2 렌더링을 유지한다. payload에 공통 원고 정보, `manuscriptAt`, 빈 note/exceptionReason을 저장한다. 메일에는 제목·접수번호·분야·학회와 고정 `/chair.html` 링크를 담고 PDF·초록·저자 목록은 담지 않는다. 두 제목은 ‘신규 논문 투고 알림’, ‘수정본 재제출 알림’으로 구분한다.

원고 UUID + UTC 마이크로초 제출 시각 + 수신자 UUID를 unique event key로 사용해 같은 제출본의 감사 이벤트 재생도 합친다. 롤백하면 큐/HTTP 요청도 롤백된다. worker는 현재 제출본 시각, 비초안/현재 회차 및 공통 수신자 helper의 현재 권한을 재검증한다. 이전 제출본·초안은 submission_obsolete, 역할 회수는 recipient_role_changed로 취소한다. 판정 이후에도 같은 제출본의 접수 사실은 유효하며 최신 상태는 포털에서 확인하도록 안내한다.

`paper_submitted_enabled=false`를 private config에 추가한다. false이면 enqueue와 두 kind dispatch만 중지하고 이전 메일은 계속 처리한다. 상태 RPC는 새 종류의 개별 활성 여부를 반환하며 화면의 기존 알림 목록에 종류를 표시한다. 개인키·hook·SMTP 설정을 재사용한다.

## 검증·배포

새 로컬 Supabase/Auth/Storage/Chromium → pg_net → Next → loopback 수집기로 신규 투고 2건·수정본 재제출 1건의 AE/위원장 알림 6건 및 기존 전체 메일을 확인한다. v1/v2/v3 각 응답 유실 복구, 개인별 수신자·양식·권한·HTML escape·입력 검증을 확인한다.

추가 rollback SQL은 초안/실패/임시저장 제외, 제출본 재생 중복, 실제 기존 원고의 새 수정본 제출, flag 중지/상태 RPC/오래된 제출본·권한 회수 취소를 검사한다. 신규 migration 전체 적용, TS/build/JS/HTML IDs/diff, desktop/mobile를 확인한다.

운영은 새 flag를 끈 채 migration과 서버 배포 후 기존 위원장 수신자가 올바른지 확인하고 켠다. 지정 테스트 계정으로 양식별 메일을 보내 provider Delivered와 DB 접수 기록을 대조한다. 실제 원고는 만들지 않는다. 롤백은 새 flag=false와 이전 배포 복원이며 큐/접수 기록을 보존한다. 이전 제출/심사·판정 이벤트는 소급 발송하지 않는다.
