# 투고자 접수 확인 — 설계 대조·검증

2026-11-08. [설계](../02-design/features/author-receipt-notifications.design.md).

| 요구사항 | 구현·검증 |
| --- | --- |
| 신규·수정본 접수 | 실제 Chromium/Auth/Storage 신규 투고 2건·수정본 1건에서 투고자 접수 확인 3건 발송 |
| 수신자 | papers.owner_id의 인증된 Auth 이메일. 다른 연락처·공동저자에게 보내지 않음 |
| 완료 시점 | 초안, PDF 누락 실패, 수정 중 임시저장에는 생성하지 않으며 저장과 outbox는 동일 트랜잭션 |
| 중복·재시도 | 원고/제출 시각/소유자 unique key. 이벤트 replay 제외, v1~v4 각 응답 유실 시 동일 키·본문 유지 |
| 과거 접수 사실 | 현재 제출 시각·판정 변경 후에도 원본 paper_submitted 증거가 유효하면 접수 확인 유지 |
| 취소·권한 | 소유권·이메일·제출 증거 불일치 취소, private trigger 접근 금지, 상태 RPC 편집 권한 유지 |
| 독립 제어 | 새 flag로 enqueue·dispatch 중지 및 상태 표시. 기존 편집자 알림 flag와 독립 |
| 양식·안전 | v4 전용 제목, 접수번호·고정 KST 시각·내 원고 링크. 잘못된 버전/증거 ID/자유 본문 거절, HTML escape |
| 기존 기능 | 기존 배정·의견·AE 판정·편집자 투고 알림 및 분야·익명화·권한 회귀 검증 통과 |
| 정적·화면 | TypeScript/build/JS syntax/HTML IDs/CLI/diff PASS. 1440px·390px 화면 확인 |

새 격리 Supabase 전체 migrations 적용 및 브라우저 **7묶음**, 메일 경계 **8묶음** PASS.
결과는 `/tmp/co-rnbd-author-receipt-20261108/`의 editorial-results.json, email-results.json 및 PNG에 보존했다.
30개 workflow 알림 + 별도 양식 6건 = 수집기 접수 36개, 요청 41개(버전별 응답 유실 4회와 동일 요청 1회).
실제 운영 자격증명·수신자는 로컬 검증에 사용하지 않았다. 추가 SQL fixture와 HTTP 요청은 rollback했다.

운영은 새 flag 비활성 migration → 코드 배포 → 활성화 → 기존 지정 테스트 계정으로 신규·수정본 양식 각 1통
발송 후 provider Delivered와 DB 기록을 대조한다. 실제 운영 논문·심사는 만들지 않는다.
기존 SMTP·키·편집자 수신 설정을 유지한다. 롤백은 author_receipt_enabled=false 및 이전 서버 배포 복원이며,
운영 security WARN 2건/performance WARN 4건 기준과 비교한다. 최종 운영 결과는 PR 설명에 기록한다.
