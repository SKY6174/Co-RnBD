# 논문 투고·심사 시스템 작업 보고

> 2026-09-26 · CMT 참고 흐름 추가

## 반영 내용
- 공개 화면에 저자 투고, 심사위원 배정·심사, 위원장 판정 절차를 안내하고 CFP의 분량·가안 일정으로 연결했다.
- 저자가 제출한 원고의 접수번호, 최근 제출 시각, 현재 상태를 확인할 수 있게 했다. 공동저자 이메일은 자동 검증되지 않는다고 명시했다.
- 심사위원이 저자·소속을 확인한 뒤 의견을 임시저장하거나 최종 제출하고, 이해관계가 있으면 사유를 남겨 배정을 거절할 수 있게 했다.
- 거절한 심사위원의 원고·PDF 열람 권한을 회수하고 위원장에게 거절 사유를 보여준다. 기존 원고 조회 정책의 ID 비교 오류도 수정했다.

## 확인
- 원격 Supabase 마이그레이션 `20260925183737`, `20260925184308` 적용 및 이력 확인
- 원격 정책 정의에서 배정 원고 비교가 `r.paper_id = papers.id`임을 확인
- JavaScript 문법 검사와 `git diff --check` 통과
- 공개 화면을 데스크톱과 390px 모바일에서 확인

## 운영 전 남은 일
- Google/Naver OAuth 앱과 운영용 SMTP 연결 및 메일 수신 확인
- 위원장·저자·심사위원 시험 계정으로 투고 → 배정 → 임시저장·거절 → 판정까지 검증
- 행사 일정·위원회·문의처 확정 후 CFP와 공개 안내 갱신

참고 문서: [CMT 컨퍼런스 사이트 요청](https://cmt3.research.microsoft.com/docs/help/general/request-conference.html), [저자 투고](https://cmt3.research.microsoft.com/docs/help/author/author-submission-form.html), [심사위원 안내](https://cmt3.research.microsoft.com/docs/help/reviewer/reviewing-guide.html).
