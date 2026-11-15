# 심사 이메일 알림 — 설계 대조·검증

2026-11-07. [설계](../02-design/features/review-email-notifications.design.md).

| 요구사항 | 구현·검증 결과 |
| --- | --- |
| 배정 요청 자동 발송 | paper_events trigger → private outbox → pg_net → Next API → 로컬 수집기. 현재본/재심 6건, 두 배정 계정 수신 확인 |
| AE 판정·수정 요청 | 두 분야의 수정 요청·채택·반려 3건, 인증된 원고 소유자만 수신 |
| 원자성·중복 방지 | 트랜잭션 롤백 시 큐 미생성, 동일 이벤트 중복 차단. 접수 후 응답 유실 503 → 동일 provider 키·본문으로 재시도, 추가 접수 없음 |
| 취소·장애·경계 | 오래된 배정/판정, 수신 주소 변경 취소. 23시간 컷오프, 8회 한도, 영구 422/일시 429, 요청 lease 만료 복구 통과 |
| 권한 | raw outbox·worker 일반 사용자 접근 금지, 위원장·담당 AE 상태 조회, 일반 회원·anon 차단 |
| 서버 경계 | 잘못된 hook 인증 401, 잘못된 event 400, 32KB 초과 413. 헤더 개행 차단·HTML escape·고정 포털 URL·첨부 없음 |
| 환경 격리 | local Supabase·localhost provider만 사용. Preview 모드의 인증된 요청도 발송 503. 운영 키·외부 수신자 미사용 |
| 화면 | AE 상세의 발송 내역과 1440px/390px overflow 검사 통과, PNG 직접 확인. 기존 polite 상태와 native refresh button 유지 |
| 도메인 | 요청한 co-rnbd.org를 Resend에 추가, Vercel DNS 3개 레코드와 Verified 상태 확인. receiving 비활성 |

로컬 결과: `/tmp/co-rnbd-review-email-final-20261107/editorial-results.json`(7묶음),
`email-results.json`(5묶음), `editor-accepted-1440.png`, `editor-accepted-390.png`.
실제 브라우저·Auth·Postgres·Storage를 사용했고 발송 서비스는 loopback 수집기로 대체했다.
워크플로 9건과 별도 HTML/중복 검증 1건이 provider 접수 10개, HTTP 요청 12개로 끝났다.

정적 검사: TypeScript, Next.js production build, JS syntax, HTML ID, diff check PASS.
운영 적용 전 확인한 papers/reviews/paper_events는 모두 0건이다.

운영 migration은 비활성 큐·예약 작업만 추가한다. 전용 Resend 발송 키와 hook 비밀 설정,
production 배포, 명시적인 지정 계정 테스트 및 provider 도착 확인은 별도 운영 단계이다.
이 로컬 결과를 실제 수신함 도착으로 간주하지 않는다. 롤백은 발송 비활성 + 이전 배포 복원이며
대기열·서비스 접수 기록을 보존한다. 기존 인증 SMTP credential은 별도로 유지한다.
