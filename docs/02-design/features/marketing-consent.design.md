# 홍보 메일 수신 동의와 발송 — Design

[계획](../../01-plan/features/marketing-consent.plan.md). [운영 공지 설계](chair-announcements.design.md)를 확장한다.

## 데이터

- `public.marketing_consents(user_id pk → profiles, consented, consented_at, withdrawn_at, source, unsubscribe_token unique, updated_at)`.
  RLS: 본인 행 `select`만(마이페이지 표시). 쓰기는 RPC만.
- `app_private.marketing_consent_events(id, user_id, action granted|withdrawn, source, created_at)`: 동의 증빙 이력. 일반 사용자 접근 없음.
  계정이 삭제되면 함께 삭제된다.
- outbox kind에 `consent_notice` 추가. announcements segment에 `marketing_consented` 추가.

## 동의 변경

- `public.set_marketing_consent(p_consent, p_source)` (authenticated, 이메일 인증 필수, source = `mypage`|`registration`).
  상태가 같으면 아무것도 하지 않는다. 바뀌면 이력 1건, 처리 결과 메일 1통(v7 `consent_notice`)을 넣고,
  철회면 그 회원의 대기 중 홍보 메일을 `consent_withdrawn`으로 취소한다. 동의할 때마다 `consented_at`을 새로 기록한다(2년 재확인 기준).
- `public.unsubscribe_marketing(p_token)` (anon): 토큰이 맞고 동의 중이면 철회(source `unsubscribe_link`)하고 같은 후속 처리.
  결과 `withdrawn` / `already` / `unknown`. 토큰은 회원별 무작위 UUID라 추측할 수 없고, 다른 정보를 돌려주지 않는다.

## 홍보 발송 (운영 공지 확장)

- 대상 `marketing_consented`: 동의 중이고 `consented_at`이 2년 이내인 인증 계정, 수신 거부 주소 제외.
- payload v6에 `promotional: true`, `consentedAt`, `unsubscribeToken`(테스트에서 위원장이 동의하지 않았으면 없음)을 더한다.
- 확정(`chair_announcement_confirm`): 홍보면 KST 08:00 이후이고, `현재 + ceil(n/2)분 + 30분`이 같은 날 21:00 이전일 때만 허용.
- API: 홍보면 KST 21:00–08:00 요청을 503으로 돌려 worker가 나중에 재시도하게 한다(안전망). 테스트가 아닌 홍보에 토큰이 없으면 거부.
  제목 `(광고) [T-VET Co-R&BD {연도}] {제목}`, 본문 끝에 동의 일자·전송자·연락처·수신거부 링크,
  헤더 `List-Unsubscribe: <https://co-rnbd.org/api/unsubscribe?t=…>`, `List-Unsubscribe-Post: List-Unsubscribe=One-Click`.

## 수신거부 경로 `/api/unsubscribe`

- `GET ?t=` : 확인 화면(버튼 하나, POST 폼). 이 단계에서는 아무것도 바꾸지 않는다.
- `POST ?t=` : 폼 제출 또는 메일 클라이언트 한 번 클릭(`List-Unsubscribe=One-Click`) → RPC 호출 → 결과 화면.
- 토큰 형식이 틀리면 400. DB 오류는 503.

## 처리 결과 메일 (v7 `consent_notice`)

제목 `[T-VET Co-R&BD] 광고성 정보 수신 동의(또는 철회) 처리 결과`. 본문: 전송자, 처리 일시(KST), 처리 결과, 경로,
변경 방법(마이페이지). Reply-To office@.

## 화면

- 마이페이지: "홍보 메일 수신" 카드. 현재 상태·동의 일자, 동의/철회 버튼, 항목·목적·보유기간 안내.
- 참가 신청: 기본 해제된 선택 체크. 신청 저장이 성공한 뒤 체크된 경우에만 동의를 기록한다(체크 해제는 기존 동의를 바꾸지 않음).
- 운영 공지: 대상 목록에 "홍보 수신 동의자 (광고)"와 야간·광고 표기 안내.

## 검증

로컬 Supabase SQL(롤백): 동의·철회·중복·미인증 거부, 이력·통지 메일, 대기 홍보 취소, 토큰 수신거부, 2년 경과 제외,
홍보 확정 시간 제한, payload 필드, 권한. API: v6 홍보·v7 렌더링, 야간 거절, 헤더, 수신거부 GET/POST. typecheck/build,
로컬 화면(마이페이지·참가 신청·운영 공지·수신거부).
