# 심사 이메일 자동 알림 — Design

## 발송 구조

기존 `paper_events`의 `review_assigned`, `decision_published`가 저장되는 같은 트랜잭션에서 비공개 발송 대기열에 기록한다. 원고 저장이 롤백되면 메일도 발생하지 않는다. 기존 원고·심사·판정 RPC는 유지한다.

- `app_private.review_email_outbox`: event key(unique), 원고/배정 식별자, 수신 계정·이메일, 고정 payload, 상태, 시도 횟수, 최초/다음 시각, pg_net 요청 ID, provider ID, 안전한 오류 코드. 공개 테이블/조회 권한은 주지 않는다.
- `app_private.review_email_config`: 초기 비활성, 고정 운영 hook URL, 활성 여부. hook 공유 비밀은 Vault에 보관한다.
- `pg_net`이 Vercel `/api/review-notifications`로 비동기 요청한다. 최초 요청은 enqueue 시 실행하고, `pg_cron`의 1분 작업은 응답 회수·실패 재시도·정체 복구를 수행한다.
- Vercel은 공유 비밀을 검증한 뒤 고정 Resend API로 발송한다. Supabase service-role key를 Vercel에 추가하지 않는다. Resend key와 hook 비밀은 production 서버 환경변수에만 둔다. Preview에 실제 메일 키를 주지 않는다.

## 수신자·권한

심사 요청은 해당 배정의 `reviewer_id`, 판정은 `papers.owner_id`의 `auth.users.email`을 사용한다. 확인되지 않은 이메일은 발송 실패로 기록하며 임의 contact_email로 대체하지 않는다. 공동저자·다른 심사위원·일반 참가자에게 함께 보내지 않는다.

발송 직전에 배정 철회/거절, 제출본 교체, 이후 판정, 수신 계정 이메일 변경을 확인해 유효하지 않은 대기 요청을 취소한다. 이미 발송 서비스가 접수한 이메일은 회수할 수 없다.

공개 상태 RPC는 로그인한 위원장 또는 해당 원고의 유효한 AE만 사용할 수 있고 제목·본문·비밀을 반환하지 않는다. 익명·일반 회원은 실행/조회할 수 없다. 운영 상태는 원고 상세에서 문자로 표시한다. `sent`는 수신함 도착이 아닌 **발송 서비스 접수 완료**를 뜻한다.

## 중복·재시도

DB unique event key로 같은 이벤트 재생을 막고, 발송마다 고정 UUID를 Resend Idempotency-Key로 사용한다. payload는 최초 snapshot을 유지한다. 429/네트워크/5xx는 제한된 간격으로 최대 8회 재시도한다. 잠긴 행과 요청 lease로 동시 작업을 조정한다.

[Resend 중복 방지](https://resend.com/docs/dashboard/emails/idempotency-keys)의 24시간 보존 기한을 넘겨 불명확한 발송을 자동 재전송하지 않는다. 최초 시도 후 23시간이 지나면 불확실 상태로 중지한다. 4xx 영구 오류와 설정 오류를 감추지 않는다. 재시도에는 같은 수신자·본문·키를 사용한다.

## 메일·화면

사용자가 추가 요청한 `co-rnbd.org`에서 `no-reply@co-rnbd.org`로 발송한다. 기존 인증메일 발신 도메인과 설정은 별도이다. 한국어 text/HTML 양식으로 학회명, 원고 제목·접수번호, 요청/판정과 사유, 고정 HTTPS 포털 링크를 제공한다. 모든 사용자 문구를 HTML escape하고 이메일 헤더 줄바꿈을 차단한다. 첨부파일·다운로드 서명 URL은 보내지 않는다.

판정 확인창과 도움말의 ‘자동 이메일 없음’을 실제 발송 대기·자동 재시도 안내로 교체한다. 원고 상세에 발송 대기/서비스 접수/재시도/실패/취소를 표시하고 기존 polite 상태 영역을 재사용한다. 새 제어는 native button을 사용한다.

## 검증·배포·롤백

1. 로컬 새 Supabase에서 migrations, enqueue 원자성, 권한, 중복, 철회·거절·수정본/판정 교체 취소, 재시도·lease·23시간 경계를 검증한다.
2. 로컬 Next API → 메일 수집기의 실제 HTTP 경로로 인증/본문/HTML escape/중복/장애를 검사한다. 실제 수신자는 쓰지 않는다.
3. 브라우저에서 배정·두 심사·AE 수정 요청·재심·채택/반려와 발송 상태를 확인하고 1440px/390px 및 키보드 접근을 검사한다.
4. typecheck/build, JS syntax, HTML ID, diff check와 보안 advisory 확인.
5. 운영은 대기열 비활성으로 migration 적용 → production 배포 → 비밀/발신 설정 검증 → 활성화한다. 기존 원고·심사를 수정하지 않는다. 지정 테스트 계정에만 테스트임을 명시한 메일을 발송한다.
6. 롤백은 config 비활성화와 이전 Vercel 배포로 진행한다. 미발송 큐를 보존하고 provider 접수 기록은 삭제하지 않는다. 메일 발송 기록의 보존은 기존 학회 개인정보 보존 기간을 따른다.

참고: [Supabase pg_net](https://supabase.com/docs/guides/database/extensions/pg_net), [Cron와 Vault](https://supabase.com/docs/guides/functions/schedule-functions).
