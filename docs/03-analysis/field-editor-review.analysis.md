# 분야별 편집위원 심사 — 설계 대조 및 검증

2026-11-07. [설계](../02-design/features/field-editor-review.design.md), [PR #61](https://github.com/SKY6174/Co-RnBD/pull/61).

| 요구사항 | 구현·검증 |
| --- | --- |
| 분야별 심사위원·AE 구성 | `review_committee` RLS, 위원장 명부 폼, 인증 계정 연결·활성 해제. 브라우저 저장 검증 통과 |
| Chief editor의 심사 요청 | 현재 제출본에 활성 분야 심사위원 2인 배정. 일반 회원·AE의 배정 변경 차단 검증 통과 |
| Accept / 수정 후 채택 / Reject + 의견 | 세 추천을 실제 계정과 브라우저에서 저장. 임시저장과 제출 구분 유지 |
| AE 검토·저자 통보 | 두 심사 완료, 분야·현재 회차·비저자 조건을 private 판정 경계에서 재검증. 두 분야 AE 판정 통과 |
| 저자 심사의견 열람 | 공개 판정 이후 현재 제출본의 추천·의견만 반환. 판정 전·타인 열람 차단 및 reviewer_id/email 비포함 검증 |
| 수정본·재심 | 수정 요청 → 새 PDF·재투고 → 새 심사 2건 → 채택 통과. 과거 2건의 심사도 보존 |
| 접근 권한·동시 변경 | 임의 원고 수정·운영 설정·다른 분야 판정·미완료 예외 우회·공동저자 AE·이해관계 거절 겸임 AE·역할 회수·오래된 snapshot 차단 통과 |
| 반응형 UI | 1440px/390px 위원 명부와 AE 상세 화면의 overflow 없음. 생성 PNG 직접 확인 |

격리 로컬 Supabase의 실제 Auth/Postgres/Storage와 Chromium에서 **7개 검증 묶음 PASS**.
`/tmp/co-rnbd-field-editor-test-20261107/editorial-results.json` 및 `committee-*.png`, `editor-accepted-*.png`에 결과를 보존했다.
운영 자격증명·실제 논문·외부 메일은 사용하지 않았다. 새 migration 전체 적용과 롤백 전용 SQL도 로컬에서 검증했다.

검증 중 수정본 저장 규칙 회귀를 발견해 기존 최신 guard를 보존하도록 수정했다. 원고 비동기 로딩 전 폼이
노출되어 너무 빠른 제출이 무시될 수 있던 경로는 데이터 로딩 완료 후 폼을 표시하도록 수정했다.
로그인 완료 시 이전 익명/다른 계정의 진행 중인 로드를 무효화하고 새 검증 로드를 시작하도록 보완했다.

정적 검증: TypeScript, Next.js production build, legacy JS syntax, HTML ID 중복, diff check, CLI 호환성 모두 PASS.
PR quality gate SUCCESS. Preview `co-rnbd-o0wvoatyb-ucsky6174.vercel.app` READY, HTML·JS·config HTTP 200 확인.
Preview config가 운영 Supabase를 사용하므로 Preview 쓰기 검증은 하지 않았다.

운영 `20261107133453` 적용 및 지정 계정 명부 12행 연결 완료. 실제 세 계정의 권한으로
롤백 전용 SQL 검증 PASS. 확인 당시 운영 논문·심사·PDF는 각각 0건이며 합성 기록은 남기지 않았다.
`review_committee` RLS 활성, 신규 공개 RPC의 anon 실행 금지 확인. 테스트위원2의 빈 프로필에 승인된
임시 소속·전문분야를 적용했다. 보안 advisory는 기존 회차 관리 함수 2건만 유지되고 신규 경고는 없다.
[기존 advisory 안내](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).
최종 전체 회귀 및 production 배포 결과는 PR #61의 최종 검증 설명에서 확인한다.
자동 메일·Google/Naver 실로그인은 이번 기능의 검증 범위에 포함하지 않는다.


기존 전체 생명주기 회귀(`verify-authenticated-lifecycle.py`) **9개 검증 묶음 PASS**:
계정 5개의 로그인·프로필, PDF/초안/저자, 2인 심사, 수정본·재심·채택·최종본 확인,
참가 신청·확정·체크인, 발급기관·납부·문서 3종·A4 인쇄, 소유권·중복·취소·로그아웃.
브라우저 예외와 운영 대상 요청은 0건이다. 이 결과는 `results.json`에 보존했다.

추가 migration `20261107140511`은 심사위원과 AE를 겸하는 계정이 이해관계를 이유로 거절한 원고를
AE 역할로 다시 열거나 판정하지 못하게 한다. 제출본 교체와 배정 철회로도 거절 이력이 지워지지 않는다.
로컬 및 운영 롤백 검증은 해당 원고 열람·판정 차단까지 포함한다.
