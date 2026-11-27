# 위원장 승인형 일괄 운영 공지 — Design

[계획](../../01-plan/features/chair-announcements.plan.md). 기존 [심사 이메일](review-email-notifications.design.md)과
[전달 결과 처리](email-delivery-feedback.design.md)를 확장한다.

## 데이터

- `app_private.announcements`: id, edition_year, segment, subject(2–120자, 줄바꿈 없음), body(10–5000자),
  created_by/at, updated_at, test_sent_at, confirmed_at/by, recipient_count, cancelled_at.
  일반 사용자 접근 없음(RLS, 권한 회수). 모든 접근은 위원장 RPC로만.
- outbox: kind에 `announcement` 추가, `announcement_id`(FK, on delete set null) 추가.
  `paper_id`가 없으므로 기존 행사 후 파기에서 outbox 행과 함께 삭제된다.
- payload **version 6**: kind, recipient, recipientName, conferenceTitle, editionYear, subject, body, note=''.
  Reply-To는 기존 트리거가 비편집 종류로 보고 `office@`를 기록한다.

## 대상 그룹 (`app_private.announcement_recipients(segment, year)`)

| segment | 조건 (현재 회차) |
|---|---|
| `registrants_confirmed` | 참가 신청 `confirmed` |
| `registrants_active` | 참가 신청 `applied`, `confirmed` |
| `authors_submitted` | 원고 `submitted`, `under_review`, `revision`, `accepted`, `rejected`의 소유자 |
| `authors_accepted` | 원고 `accepted`의 소유자 |
| `authors_draft` | `draft` 원고만 있고 제출 원고는 없는 소유자 |
| `reviewers_active` | 철회·거절되지 않은 현재 회차 심사 배정의 심사위원 |

모두 `auth.users.email_confirmed_at`이 있는 계정, 계정당 한 행, `email_suppressions` 주소 제외.
helper는 public/anon/authenticated에 실행 권한을 주지 않는다.

## 위원장 RPC (security definer, `is_chair()` 아니면 거부)

- `chair_announcement_preview(segment)` → 수신자 수.
- `chair_announcement_save(id|null, segment, subject, body)` → id. 확정·취소된 공지는 수정 불가.
  수정하면 `test_sent_at`을 지워 테스트를 다시 요구한다.
- `chair_announcement_test(id)` → 호출한 위원장 본인의 인증 이메일로 `is_test` 1통을 넣고 `test_sent_at` 기록.
- `chair_announcement_confirm(id, expected_count)` → 테스트 이후 내용이 바뀌지 않았고, 확정 시점 수신자 수가
  `expected_count`와 같고, 1–2000명일 때만 수신자별 outbox 행을 한 트랜잭션에 넣는다. event key
  `announcement:<id>:<user>`로 같은 공지의 중복 발송을 막는다.
- `chair_announcement_cancel(id)` → 아직 `queued`/`retry`인 행을 `cancelled`/`announcement_cancelled`로 바꾸고 `cancelled_at` 기록.
- `chair_announcements(limit)` → 최근 공지와 발송 상태별 건수(대기·발송·전달·반송·신고·실패·취소).

worker는 다시 정의하지 않는다. `announcement`에는 별도 상태 재검증이 없고, 기존 수신 계정 인증 확인과
수신 거부 insert 트리거가 그대로 적용된다. 발송 전체 중지는 기존 `review_email_config.enabled`.

## 메일 (API v6)

- 제목: `[테스트] `(테스트일 때) + `[TVET Co-R&BD {연도}] {제목}`. 헤더 개행 차단.
- 본문: `{이름}님,` → 학회명 → 위원장 본문(빈 줄로 문단 구분, HTML escape) → "이 메일은 {학회명} 운영 안내입니다.
  회신하면 사무국으로 전달됩니다." 첨부·추적 링크 없음.
- 파서는 subject 120자·body 5000자, 줄바꿈 없는 제목, version 6만 허용한다.

## 화면 (`operations.html` → 운영 공지)

- 대상 선택 시 수신자 수와 예상 소요 시간(분당 2통) 표시. 제목·본문 입력, 비광고성 안내 문구.
- 버튼: 저장 → 나에게 테스트 발송 → 확정(수신자 수 직접 입력 필요, 확인 대화상자). 상태에 따라 비활성화.
- 최근 공지 목록: 대상, 제목, 확정 시각, 상태별 건수, 대기 건이 있으면 취소 버튼.

## 검증

1. 로컬 Supabase SQL(롤백): 권한(일반 회원·anon 거부), 그룹별 대상·중복·미인증·수신 거부 제외,
   테스트 전 확정 거부, 수정 후 재테스트 요구, 수 불일치 거부, 중복 확정 거부, 취소, Reply-To, 목록 집계.
2. API 파서·렌더러: v6 정상, 잘못된 입력 거부, escape, 테스트 접두어.
3. typecheck/build, `node --check`, 데스크톱·390px 화면.
4. 운영: migration 적용 → 배포 → 위원장 계정으로 테스트 발송만 확인. 실제 그룹 확정 발송은 운영자가 결정한다.
