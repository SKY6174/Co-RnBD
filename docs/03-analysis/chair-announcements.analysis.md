# 위원장 승인형 일괄 운영 공지 — 설계 대조·검증

2026-11-17. [설계](../02-design/features/chair-announcements.design.md).

| 요구사항 | 결과 |
| --- | --- |
| 대상 그룹 | 6개 그룹 각각의 포함·제외 확인. 미인증 계정·수신 거부 주소 제외, 원고 2편 투고자 1통, 이메일 소문자, 알 수 없는 그룹 0명 |
| 권한 | 일반 회원의 미리보기·저장 거부, 테이블·helper 직접 접근 거부, anon 목록 거부 |
| 입력 검증 | 짧은 제목, 줄바꿈 제목, 알 수 없는 그룹 거부 |
| 승인 절차 | 테스트 전 확정 거부, 동일 내용 재저장은 테스트 유지, 내용 수정 시 재테스트 요구, 수신자 수 불일치 거부, 중복 확정·확정 후 수정 거부 |
| outbox | 수신자별 1행(v6, kind announcement, Reply-To office@, paper 없음), 테스트 행 분리, 목록 집계(대기·발송) |
| 취소 | 대기 행 취소(테스트 포함), 반환값은 수신자 메일 수, 목록에 취소 반영 |
| 메일 렌더링 | v6 파싱, 제목 접두어·테스트 표시, 본문 HTML escape, 잘못된 버전·제목·본문·note·Reply-To·주소 거부 |
| 화면 | 로컬 Next + 로컬 Supabase에서 위원장 계정으로 저장 → 테스트 → 확정(수신자 3명) → 목록 → 취소 확인. 375px 가로 넘침 없음 |

환경: 새 격리 로컬 Supabase에 저장소 전체 migration 적용 성공. `scripts/verify-chair-announcements.sql`,
`verify-email-delivery-feedback.sql`, `verify-registration-emails.sql` PASS(롤백). `verify-paper-submitted.sql`,
`verify-review-submitted.sql`, `verify-author-receipt.sql`은 `verify-review-email.py` 고정 계정이 필요해 이 환경에서
실행되지 않았다(변경과 무관). TypeScript typecheck, Next production build, `node --check`, `git diff --check` PASS.

미검증: 운영 적용, 운영 위원장 계정의 실제 테스트 메일 수신, 실제 그룹 대상 발송(운영자가 결정).
