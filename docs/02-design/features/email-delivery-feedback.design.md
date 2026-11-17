# 반송·스팸 신고 처리 — Design

[계획](../../01-plan/features/email-delivery-feedback.plan.md). 기존 [심사 이메일 설계](review-email-notifications.design.md)를 확장한다.

## 경로

```
Resend ──(Svix 서명)──▶ Vercel /api/resend-webhook
                         │ 서명·시각·크기·형식 검증, 최소 필드만 추출
                         ▼
          Supabase RPC public.record_email_feedback(p_token, p_message_id, p_event)
                         │ Vault review_email_webhook_token 대조 (기존 hook 비밀 재사용)
                         ▼
          app_private: outbox 전달 상태 갱신, 이벤트 중복 기록, 수신 거부, 대기 알림 취소
```

- Vercel은 이미 있는 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `REVIEW_MAIL_WEBHOOK_SECRET`과
  새 `RESEND_WEBHOOK_SECRET`(Resend가 발급한 `whsec_` 서명 secret)만 쓴다. service-role key는 쓰지 않는다.
- RPC는 anon/authenticated에 실행 권한이 있지만 Vault 비밀과 일치하지 않으면 아무것도 하지 않고 거부한다.
  비밀은 기존 pg_net → Vercel 발송 hook과 같은 값이며 양쪽에 이미 저장되어 있다.
- production이 아니면 route는 503을 반환한다. Preview에는 secret을 넣지 않는다.

## 서명 검증 (Svix 수동 검증)

- 헤더 `svix-id`, `svix-timestamp`, `svix-signature`. 서명 대상은 `${id}.${timestamp}.${rawBody}`.
- secret에서 `whsec_`를 떼고 base64 decode한 키로 HMAC-SHA256 → base64. 헤더의 공백 구분 `v1,<sig>` 중
  하나와 상수 시간 비교로 일치해야 한다.
- 시각은 현재 기준 ±5분. 본문 64KB 초과는 413. 서명 실패는 401, 형식 오류는 400.

## 이벤트 → DB 반영

route는 다음 필드만 넘긴다: `type`, `emailId`(provider UUID), `notificationId`(발송 시 태그 `notification_id`),
`bounceType`, `bounceSubType`(각 60자 이하), `occurredAt`.

RPC는 태그가 있으면 `id = notificationId`이고 `provider_id`가 아직 비었거나 `emailId`와 같은 행, 태그가 없으면 `provider_id = emailId`인 행만 찾는다. 없으면 `ignored`. (2026-11-17 운영 확인: Resend의 `delivered`가 worker의 다음 분 접수 회수보다 먼저 도착하므로 provider ID가 비어 있는 동안에도 태그로 매칭한다. `20261117110000_feedback_early_match.sql`)

| type | outbox | 수신 거부 |
|---|---|---|
| `email.delivered` | `delivery_state='delivered'` (반송·신고가 이미 있으면 유지) | — |
| `email.delivery_delayed` | 아직 결과가 없을 때만 `delayed` | — |
| `email.bounced` + `Permanent` | `bounced` | `bounce` |
| `email.bounced` 그 외 | `bounced` | — (일시 반송) |
| `email.suppressed` | `bounced` | `bounce` (Resend가 이미 거부 중인 주소) |
| `email.complained` | `complained` | `complaint` (반송보다 우선) |

- `app_private.email_feedback_events(svix_id pk, outbox_id fk cascade, type, received_at)`로 같은 webhook 재전송을
  한 번만 반영한다 (`duplicate`).
- `app_private.email_suppressions(email pk, reason, detail, source_outbox_id fk cascade, created_at, updated_at)`.
  주소는 outbox의 `recipient_email`(이미 소문자)을 쓰고 webhook 본문의 주소는 신뢰하지 않는다.
- 수신 거부 기록 시 같은 주소의 `queued`/`retry` 행을 `cancelled`/`recipient_suppressed`로 바꾼다.
  `sending` 행은 이미 provider로 요청이 나갔으므로 건드리지 않는다.
- outbox BEFORE INSERT 트리거가 수신 거부 주소의 새 알림을 바로 `cancelled`/`recipient_suppressed`로 만든다.
  기존 worker와 enqueue 함수는 다시 정의하지 않는다. 테스트 알림(`is_test`)도 같은 규칙을 따른다.

## 화면

`review_email_status`가 `delivery_state`, `delivery_at`을 함께 반환하도록 반환형을 넓힌다(함수 재생성, 권한 동일).
위원장 화면 알림 항목에 `수신 서버 전달 완료`, `전달 지연`, `반송됨 · 주소 확인 필요`, `스팸 신고됨 · 이후 발송 중지`,
`수신 거부 주소로 취소`를 표시하고 반송·신고·수신 거부 취소를 `확인 필요` 건수에 포함한다.

## 해제·보존

- 주소가 정정된 경우 운영자가 SQL로 해제한다:
  `delete from app_private.email_suppressions where email = lower('<주소>');` 이후 새 알림부터 발송된다.
  취소된 과거 알림은 재생하지 않는다.
- 전달·수신 거부 기록은 원본 outbox 행에 cascade로 묶인다. 기존 행사 후 파기에서 outbox가 지워지면 함께 지워진다.
  별도의 새 개인정보 항목은 없다(기존 수신 주소·발송 기록의 전달 결과).

## 검증

1. 로컬 Supabase에 전체 migration 적용 → RPC 토큰 거부, 일치·불일치 provider ID, 재전송 중복, 우선순위,
   대기 행 취소, 새 행 insert 취소, 권한(anon이 테이블 직접 접근 불가), 상태 RPC 반환을 SQL로 확인한다.
2. route는 Node로 서명 성공·실패·시각 초과·크기·형식을 확인한다. TypeScript·Next build를 통과한다.
3. 운영: migration 적용 후 배포 → Resend Webhooks에 endpoint 등록, 서명 secret을 Vercel production에 저장 →
   지정 테스트 계정 `is_test` 메일로 `delivered` 기록을 확인한다. 반송은 Resend 테스트 주소
   `bounced@resend.dev`로 보낼 수 없으므로(outbox는 인증된 계정만 수신) 로컬 검증으로 대신한다.
4. 롤백: Resend webhook 비활성화 → 이전 배포. 테이블·트리거는 남겨도 webhook이 없으면 동작하지 않는다.
