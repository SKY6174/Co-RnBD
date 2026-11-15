# 신규 투고·수정본 알림 — 설계 대조·검증

2026-11-08. [설계](../02-design/features/paper-submitted-notifications.design.md).

| 요구사항 | 구현·검증 |
| --- | --- |
| 정상 신규 투고·재제출 | 실제 Chromium/Auth/Storage 투고 2건 + 수정본 1건, 종류별 담당 분야 AE/위원장 각 1통 = 6건 |
| 초안·실패·임시저장 제외 | 신규 draft, PDF 누락 제출 실패, metadata 저장, 수정 중 임시저장 시 추가 통보 없음 |
| 같은 제출본 중복 방지 | 원고 UUID/UTC 제출 시각/수신자 unique key, 감사 이벤트 replay에도 추가 메일 없음 |
| 정확한 수신자 | 기존 현재 회차/분야/활성/인증/이해관계 helper 재사용. 제출 시와 dispatch 시 역할 검증, 겸임 중복 제거 |
| 새 양식 | v3 신규·재제출 제목 구분, 고정 chair 링크, 본문/추천/저자 목록/PDF 비포함. 잘못된 version/날짜/자유 본문 거절 및 HTML escape |
| 전송·호환 | 기존 v1/v2 포함 27개 workflow 알림, v1/v2/v3 각각 접수 후 503 응답 유실의 동일 키/본문 재시도 통과 |
| 권한·취소·롤백 | 권한 회수/이전 제출본 취소, 새 flag enqueue·dispatch 중지, 상태 RPC 반영, helper/trigger 접근 금지, 추가 fixture rollback |
| 화면·정적 검사 | 1440px/390px overflow 없음, 새 종류 목록. TypeScript/build/JS syntax/HTML IDs/CLI/diff PASS |

새 격리 Supabase 전체 migrations 적용 및 브라우저 **7묶음**, 메일 경계 **7묶음** PASS.
결과는 `/tmp/co-rnbd-paper-submitted-20261108/`의 editorial-results.json, email-results.json 및 PNG에 보존했다.
27개 workflow + 별도 양식 4건 = 수집기 접수 31개, 요청 35개(버전별 응답 유실 3회와 동일 요청 1회).
운영 자격증명·실제 수신자는 로컬 검증에 사용하지 않았다. 임시 SQL 데이터와 HTTP 요청은 rollback했다.

적용 전 운영은 원고/심사/대기 메일 0건, 편집 담당자 알림 활성, 위원장 수신자 1계정이다.
운영 advisor 기준 security WARN 2건/performance WARN 4건을 비교한다. 새 flag 비활성 migration → 코드
배포 → 지정 수신 설정 확인·활성화 → 신규/재제출 양식별 지정 계정 테스트와 Delivered 대조를 수행한다.
최종 운영 결과와 롤백 기준은 PR 설명에 기록한다. 로컬 수집기 접수와 운영 Delivered를 구별한다.
