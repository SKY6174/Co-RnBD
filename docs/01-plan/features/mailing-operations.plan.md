# 메일링 운영 체계 (Zoho + Resend) — Plan

2026-11-16. 자동 알림은 이미 구현되어 운영 중이다. 이 문서는 **현재 구현을 기준으로 남은 영역**
(주소 역할, 일괄 운영 공지, 홍보 메일)과 운영 절차를 정한다. 기존 설계는
[심사 이메일](../../02-design/features/review-email-notifications.design.md),
[심사의견 제출](../../02-design/features/review-submitted-notifications.design.md),
[신규 투고](../../02-design/features/paper-submitted-notifications.design.md)를 따른다.

## 1. 현재 상태 (2026-11-16 확인)

| 영역 | 상태 | 근거 |
|---|---|---|
| 인증 메일 (가입·재설정·초대·비밀번호 변경) | 운영 중. Supabase Auth SMTP → Resend, `no-reply@auth.co-rnbd.org` | `supabase/templates/`, `site/README.md` |
| 이벤트 메일 큐 | 운영 중. `app_private.review_email_outbox` → pg_net → `/api/review-notifications` → Resend, `no-reply@co-rnbd.org`. 8회 재시도, 23시간 컷오프, idempotency | 운영 config `enabled=true` |
| 심사 배정·판정·심사의견 제출 | 켜짐 | `review_submitted_enabled=true` |
| 신규 투고·수정본 알림 (편집 담당자), 투고자 접수 확인 | 켜짐 | `paper_submitted_enabled`, `author_receipt_enabled` = true |
| 참가 신청 접수·확정·취소 | 구현됨, **꺼짐** | `registration_enabled=false`, 운영 등록 0건 |
| 자동 메일 답장 → Zoho `office@` | 운영 중. PR #94 병합·배포(2aad310), migration `20261115165917` 적용. 지정 계정 `is_test` 1통으로 도착·회신·Zoho 수신 확인 (2026-11-16) | API는 `replyTo=office@co-rnbd.org`만 허용 |
| 개인정보처리방침의 Resend 위탁·국외이전 | 거래성 알림까지 기재됨. 홍보 메일은 없음 | `site/content/privacy.html` §5·§6 |
| DNS | Zoho MX·SPF·DKIM, Resend `co-rnbd.org`·`auth.co-rnbd.org`. **DMARC `p=none` 2026-11-16 추가** (`rua=office@`) | 공개 DNS 조회 |
| 반송·스팸 신고 처리 | 없음. `sent`는 provider 접수까지만 의미 | 코드 검색 |
| 일괄 운영 공지, 홍보 메일 | 없음 | — |

## 2. 주소 역할

자동 발신 주소(`no-reply@…`)는 그대로 두고, **답장과 사람 응대만 Zoho로** 모은다. 발신 주소를
바꾸면 Resend 도메인·Auth SMTP·기존 재시도 본문과 충돌하므로 바꾸지 않는다.

| 주소 | 역할 |
|---|---|
| `office@co-rnbd.org` | 모든 자동 메일의 Reply-To(PR #94). 등록·투고 문의, DMARC 리포트(필터로 분리), 일괄 운영 공지 발신 표시 |
| `chair@co-rnbd.org` | 위원장 개인 응대용 메일함. 심사위원·저자와의 개별 서신. 자동 메일의 Reply-To로는 쓰지 않는다 (사무국 한 곳에서 분류) |
| `info@co-rnbd.org` | 사이트 공개 문의처, 홍보 메일 Reply-To |

`chair@`를 판정·배정 메일 Reply-To로 쓰려면 API의 고정 주소 검사를 kind별 허용 목록으로 바꿔야 한다.
지금은 필요성이 낮아 제외한다.

## 3. 메일 유형과 처리 방식

| 유형 | 예 | 방식 | 상태 |
|---|---|---|---|
| 인증 | 가입 확인, 재설정 | Supabase Auth SMTP | 운영 중 |
| 이벤트 (1:1) | 배정, 판정, 접수 확인, 참가 신청 | outbox 자동 | 운영 중 / 등록은 꺼짐 |
| 일괄 운영 공지 | 마감 리마인더, 프로그램 안내, 행사 전 안내, 일정 변경 | **신규: chair 승인형 공지** | 제안 |
| 홍보 (광고성) | CFP 홍보, 차기 학회 안내 | **신규: 동의자 대상 Resend Broadcast** | 제안 |

### 3.1 일괄 운영 공지 (제안)

기존 outbox를 재사용하고 새 kind `announcement`를 추가한다. 별도 발송 경로를 만들지 않는다.

- 대상은 고정 세그먼트만 허용: 확정 등록자, 신청 등록자, 채택 저자(원고 소유자), 활성 심사위원, 초안 보유 투고자.
  자유 주소 입력·CSV 업로드는 허용하지 않는다.
- 위원장 화면: 제목·본문 작성 → 수신자 수 미리보기 → 본인에게 `is_test=true` 발송 → 확정. 확정 시
  수신자별 outbox 행을 한 트랜잭션에 만든다. 확정 후 대기 행은 취소할 수 있다.
- 본문은 텍스트 + 고정 레이아웃. 사용자 입력은 escape하고 첨부·외부 링크 단축은 쓰지 않는다.
- 비광고성 안내로 한정한다. 홍보 문구가 섞이면 3.2를 따른다.
- 별도 flag `announcement_enabled=false`로 배포하고 지정 계정 시험 후 켠다.

### 3.2 홍보 메일 (제안)

- 정보통신망법 제50조: 사전 명시 동의, 제목 `(광고)`, 발신자·연락처·수신거부 방법 표기,
  21시~08시 발송 금지(별도 동의 없으면), 2년마다 동의 재확인.
- 동의 저장: 회원 프로필 또는 등록 폼에 선택 항목(기본 해제)과 동의·철회 시각. 기존 회원·저자·심사위원
  명단을 동의 없이 홍보 대상으로 쓰지 않는다.
- 발송: 동의자만 Resend Contacts/Segment로 동기화하고 Broadcast로 보낸다. Resend 구독해지와
  DB 철회를 양방향 반영한다.
- 개인정보처리방침 §5·§6에 "홍보 메일 발송(동의자)" 목적과 Contacts 보관을 추가한 뒤 시작한다.
- 발송량이 늘면 평판 분리를 위해 `news.co-rnbd.org`를 별도 Resend 도메인으로 검토한다.

## 4. 운영 절차

### 즉시 (코드 변경 없음 또는 기존 PR)

1. ~~PR #94 병합·배포~~ — 2026-11-16 완료 (API 배포 → migration → 테스트 메일 회신 확인).
2. **Zoho 설정** — 세 주소의 표시명·서명, office@에 DMARC 리포트 필터(`DMARC` 폴더).
   여러 운영자가 보면 office@를 공유 메일함으로.
3. **DMARC 모니터링** — 2~4주 리포트에서 Zoho(`zmail` DKIM)와 Resend(`co-rnbd.org`, `auth.co-rnbd.org`)가
   모두 통과하면 `p=quarantine`으로 올린다.
4. **참가 신청 메일 활성화** — 등록 개시 시점에 지정 계정 시험 후 `registration_enabled=true`.

### 다음 개발 단위 (각각 별도 PR)

5. **반송·스팸 신고 수신** — Resend webhook(서명 검증) → private suppression 기록 → outbox가 발송 전
   차단, 위원장 화면에 반송 주소 표시. 일괄 공지 전에 필요하다.
6. **일괄 운영 공지** (3.1)
7. **홍보 동의 + Broadcast** (3.2) — 방침 개정과 함께.

## 5. 용량·비용

Resend 플랜과 한도는 계정의 현재 플랜을 대시보드에서 확인한다. 공개 자료 기준 무료 플랜은 월 3,000통·
일 100통이며, Auth 메일과 이벤트 메일이 같은 계정 한도를 공유한다. 등록 개시·마감 주간·판정 일괄 공개·
운영 공지 시점에 일 100통을 넘을 수 있으면 그 전에 Pro로 전환한다. Zoho는 발송 경로가 아니므로
무료 플랜으로도 이 구조에 영향이 없다.

## 6. 결정이 필요한 항목

1. 일괄 운영 공지를 outbox 확장(권장)으로 할지, 초기에는 Zoho에서 수동 발송할지
2. 홍보 동의를 받을 위치(회원가입, 참가 신청, 별도 구독 폼)
3. `chair@`를 자동 메일 Reply-To로 쓸 필요가 있는지
4. Resend 플랜 전환 시점

## 검증 원칙

기존 메일 설계와 같다. 격리 로컬 Supabase → pg_net → Next → loopback 수집기로 흐름을 검증하고,
운영에서는 flag를 끈 채 배포 → 지정 테스트 계정 `is_test=true` 발송 → provider Delivered 확인 →
활성화한다. 실제 참가자에게 시험 메일을 보내지 않는다.
