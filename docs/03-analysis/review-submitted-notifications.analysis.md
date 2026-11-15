# 심사의견 제출 알림 — 설계 대조·검증

2026-11-08. [설계](../02-design/features/review-submitted-notifications.design.md).

| 요구사항 | 구현·검증 |
| --- | --- |
| 실제 제출 → AE·위원장 | review_submitted 감사 이벤트 → 전용 enqueue → 기존 outbox/pg_net/Next/수집기. 6회 제출 × 2 수신자 = 12건 확인 |
| 분야·인증·이해관계 | 활성 현재 분야 AE만 선택. 비활성/다른 분야/미인증/저자/공동저자/이해관계 거절 제외, 실제 역할 재검증 통과 |
| 수신자·중복 | private 지정 chair UUID와 실제 staff_roles 대조, 인증 계정 사용. AE/위원장 겸임 한 주소 한 통 검증 |
| 임시저장·중복 저장·수정 | 실제 draft 제외, 동일 submitted 저장 제외, 의견/추천 변경 추가 알림 확인 |
| 오래된 대기 요청 | 권한 회수/심사 내용 fingerprint/제출본 교체/거절 이해관계 취소 확인 |
| 중지·호환성 | 새 flag false는 enqueue·v2 dispatch 중지, 기존 v1 발송 계속. 상태 RPC는 종류별 활성 여부 반환 |
| 개인정보·서버 경계 | v2 note/exception 빈 값 제한, 고정 chair 링크, 심사 본문·추천·제출자 신원 비포함, HTML escape·입력 제한·인증 검사 |
| v1 회귀·재시도 | 기존 배정 6건·AE 판정 3건 유지. 응답 유실 503의 고정 키/본문 복구, 422/429/lease/23시간/8회 한도 통과 |
| 원자성·권한 | 트랜잭션 롤백 및 기존 key 중복, raw queue/worker/새 helper/trigger 접근 금지 확인 |
| 화면 | 1440px/390px 실제 AE 상세 PNG, overflow 없음. 새 종류는 심사의견 제출 알림으로 표시 |

새 격리 Supabase/Auth/Storage + Chromium 생명주기 **7묶음**, 메일/권한 경계 **6묶음** PASS.
`/tmp/co-rnbd-review-submitted-20261108/`의 editorial-results.json, email-results.json, PNG에 기록했다.
워크플로 알림 21건(v1 9 + v2 12)과 별도 양식 2건은 provider 접수 23개/요청 25개로 완료했다.
심사 본문은 provider에 없고 실제 외부 수신자를 사용하지 않았다. 추가 SQL fixture는 모두 rollback했다.

TypeScript/production build/JS syntax/HTML ID/CLI 호환성/diff 검사 PASS.
적용 전 운영은 발송 활성, 원고·심사·대기 메일 0건이다. 운영 advisor 기준은 기존 security WARN 2건과
performance WARN 4건이며 새 helper execute는 일반 역할에 주지 않는다.
운영은 새 flag 비활성 migration → 서버 배포 → 지정 chair 수신자 연결/활성화 → 테스트 메일 검증 순서다.
최종 배포·provider 검증 결과는 PR 설명에 기록한다. 로컬 수집기 접수는 운영 Delivered와 구별한다.
