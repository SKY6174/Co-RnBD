# 반송·스팸 신고 처리 — 설계 대조·검증

2026-11-17. [설계](../02-design/features/email-delivery-feedback.design.md).

| 요구사항 | 결과 |
| --- | --- |
| Svix 서명 검증 | 정상·다중 서명 통과. 본문 변조, 다른 svix-id, 5분 초과 시각, 다른 키, secret·id 누락, 잘못된 시각 형식 거부 |
| 최소 필드 전달 | 파서와 route가 주소·제목을 DB로 넘기지 않음을 확인. 지원하지 않는 이벤트는 DB 호출 없이 200 |
| 환경 격리 | `VERCEL_ENV`가 production이 아니면 503. 64KB 초과 413, 서명 실패 401, DB 실패 503(Resend 재시도) |
| DB 토큰 | 잘못된 토큰 28000 거부(PostgREST 403 → route 503), anon도 토큰 없이 기록 불가 |
| 매칭·중복 | 모르는 provider ID, 태그 불일치 `ignored`. 같은 svix-id 재전송 `duplicate` |
| 상태 우선순위 | delivered 후 delayed가 덮어쓰지 않음. complained 후 bounced가 낮추지 않음 |
| 수신 거부 | 영구 반송·suppressed·complaint만 등록, 일시 반송은 기록만. 같은 주소 queued 취소, sending 유지, 새 insert 즉시 취소, 다른 주소 영향 없음 |
| 권한 | anon/authenticated의 private 테이블 조회 차단. 위원장 상태 RPC가 delivery_state 반환 |
| 파기 | outbox 행 삭제 시 이벤트·수신 거부 기록 cascade 삭제 |
| HTTP 경로 | 로컬 Supabase PostgREST로 route → RPC 실제 호출: recorded/duplicate/ignored 및 DB 반영 확인 |

환경: 새 격리 로컬 Supabase(`scripts/prepare-lifecycle-env.py`)에 저장소 전체 migration 적용 성공.
`scripts/verify-email-delivery-feedback.sql` PASS(롤백). TypeScript typecheck, Next production build PASS,
`node --check site/public/legacy/chair.js`, `git diff --check` PASS.

미검증: 운영 Resend webhook 실제 수신(등록 전), 위원장 화면의 새 문구 시각 확인(데이터가 있는 원고 필요),
운영 migration 적용. 반송은 outbox가 인증된 계정에만 보내므로 운영에서 의도적으로 만들지 않는다.
