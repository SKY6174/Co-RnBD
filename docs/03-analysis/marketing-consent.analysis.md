# 홍보 메일 수신 동의와 발송 — 설계 대조·검증

2026-11-17. [설계](../02-design/features/marketing-consent.design.md).

| 요구사항 | 결과 |
| --- | --- |
| 동의·철회 RPC | 동의 `granted`, 재요청 `unchanged`, 미동의 철회 `unchanged`, 회원의 `unsubscribe_link` 경로 거부, 미인증·anon 거부 |
| 이력·통지 | 경로가 남은 이력 1건, v7 처리 결과 메일 1통(Reply-To office@). 같은 트랜잭션의 연속 변경도 통지가 합쳐지지 않음(검증 중 발견해 `clock_timestamp`로 수정) |
| 권한 | 본인 행만 조회, 수신거부 토큰 열 조회 불가, 직접 수정 불가, 다른 회원 행 비공개 |
| 홍보 대상 | 동의 중·2년 이내·인증·수신 거부 아님만 포함. 2년 경과 제외, 재동의 시 다시 포함, 철회 즉시 제외 |
| 홍보 payload | 수신자별 동의 일자·토큰, 위원장 테스트는 토큰 없이 `promotional`, 일반 공지에는 홍보 필드 없음 |
| 발송 시간 | 확정 함수의 주간 경로 검증(실행 시각이 낮이라 야간 거부 경로는 미실행). 서버 야간 판정 21:00·08:00 경계 4건 |
| 수신거부 | 토큰 철회 `withdrawn`→`already`, 대기 홍보 취소, 철회 통지. 로컬 PostgREST로 GET 확인 화면(변경 없음), 한 번 클릭 POST, 재요청, 모르는 토큰 404 |
| 메일 렌더링 | `(광고)` 제목, 동의 일자·전송자·수신거부 문구, `List-Unsubscribe`/`-Post` 헤더, 토큰 없는 실제 홍보·잘못된 필드 거부, v7 통지 |
| 화면 | 로컬 Next+Supabase에서 마이페이지 동의→철회와 상태 문구, 참가 신청 체크 기본 해제·레이블, 375px 가로 넘침 없음 |

환경: 새 격리 로컬 Supabase에 전체 migration 적용. `verify-marketing-consent.sql`, `verify-chair-announcements.sql`,
`verify-email-delivery-feedback.sql`, `verify-registration-emails.sql` PASS(롤백). TypeScript typecheck PASS.
`next build`는 Next.js 보안 업그레이드 안내로 일부 실행이 중단되며, 재실행 시 exit 0으로 완료.

미검증: 운영 적용, 야간 확정 거부 경로의 실제 실행, 참가 신청 제출 후 동의 기록(신청 기간이 열린 화면 필요),
운영 메일 클라이언트의 한 번 클릭 수신거부, 2년 주기 재확인 통지(후속 작업).
