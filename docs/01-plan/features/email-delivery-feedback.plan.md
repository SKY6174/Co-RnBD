# 반송·스팸 신고 처리 — Plan

2026-11-17. [메일링 운영 계획](mailing-operations.plan.md) 4절 5번 항목.
기존 outbox의 `sent`는 Resend 접수까지만 뜻한다. Resend의 전달 결과를 받아 기록하고,
영구 반송·스팸 신고 주소로는 이후 알림을 보내지 않는다.

- Resend webhook(`email.delivered`, `email.delivery_delayed`, `email.bounced`, `email.complained`,
  `email.suppressed`)을 운영 Vercel `/api/resend-webhook`에서 받는다. Svix 서명과 5분 시각 허용 범위를 검증한다.
- 서버는 서명이 맞는 이벤트에서 provider 이메일 ID·알림 ID·결과 종류·반송 유형만 추려 DB에 넘긴다.
  주소·제목·본문은 넘기지 않는다. Vercel에 Supabase service-role key를 추가하지 않는다.
- 이 학회 outbox에서 보낸 메일과 일치하는 이벤트만 기록한다. Auth 메일 등 다른 발송은 무시한다.
- 영구 반송·스팸 신고·Resend suppression 주소는 수신 거부 목록에 넣고, 같은 주소의 대기 알림과
  이후 새 알림을 `recipient_suppressed`로 취소한다. 일시 반송은 기록만 한다.
- 위원장·담당 AE의 원고 상세 알림 목록에 `수신 서버 전달`, `반송`, `스팸 신고`, `수신 거부로 취소`를 표시한다.
- 기존 발송 worker, 재시도, 중복 방지, 판정·배정 RPC는 바꾸지 않는다.
- 수신 거부와 전달 기록은 원본 outbox 행에 묶여 기존 행사 후 개인정보 파기 때 함께 삭제된다.
- 배포: migration → production 배포 → Resend webhook 등록과 서명 secret 저장 → 지정 계정 시험.
  webhook을 등록하기 전에는 아무 동작도 하지 않는다.
