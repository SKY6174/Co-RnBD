# 분야별 편집위원 심사 흐름 — Design

## CMT 참고

[CMT workflow](https://cmt3.research.microsoft.com/docs/help/overview/tasks.html), [revision](https://cmt3.research.microsoft.com/docs/help/chair/revision.html)의 Reviewer → Meta-Reviewer → Author notification 역할과 단계 분리를 참고한다. 외부 시스템 코드·디자인은 복제하지 않는다. 이 행사에서는 meta-reviewer를 Associate Editor(AE)로 표현한다.

## 데이터·권한

- `review_committee`: 회차, 분야, reviewer/associate_editor, 표시 이름, 이메일, 활성 여부. chair만 변경한다. 이메일은 정규화·검증하며 기존 인증 계정과 연결한다. 회원 프로필 이름은 바꾸지 않는다.
- private helper가 인증 사용자와 현재 회차의 명부를 비교한다. 원고별 AE 권한은 해당 분야 + 비초안 + 본인/공동저자 제외 조건이다. 자기 분야 이외 원고와 운영 설정·프로필 전체·최종 PDF는 허용하지 않는다.
- papers/reviews에 한정된 AE 조회 정책을 추가한다. 기존 paper_authors와 투고 PDF/Storage 조회는 papers RLS를 따른다. 감사 이력은 기존 심사위원장 전용으로 유지하고 AE에는 제출된 심사의견을 표시한다.
- AE 판정은 기존 snapshot 비교 RPC를 재사용한다. 원고/심사 잠금, 현재 제출본, 정확히 2인 심사, 최신 화면 검증을 유지한다. AE는 심사 미완료 예외 판정을 할 수 없다. DB 트리거가 AE의 수정 가능 필드를 판정·공개 메타데이터로 제한한다.
- 저자는 판정 공개 뒤 익명화된 추천·심사의견만 받는 RPC를 사용한다. 초안·심사 중·이전 제출본 의견을 노출하지 않는다. reviewer_id나 이메일은 반환하지 않는다.
- 운영 심사 입력은 사용자의 별도 승인(2026-11-07)에 따라 배포 후 연다. 원고 접수·최종본·일반 참가 단계와 마감은 보존한다. 외부 자동 메일은 추가하지 않으며 요청·통보는 로그인 포털에서 확인한다.

## 화면

- `/chair.html`: chair는 전체 접수 + 분야별 위원 명부 관리. AE는 같은 화면에서 담당 분야 접수·의견·판정만 표시한다. 심사 배정과 운영 설정·최종본 확인 UI는 chair만 보인다.
- `/submission.html`: AE 작업 화면 연결, 세 가지 추천의 명시적 표현, 저자에게 공개된 심사의견 표시. 기존 URL·폼 ID와 수정본 투고 흐름 유지.
- 명부는 가입 회원 이메일로 등록/활성 해제하며 이름·이메일·분야·역할·계정 연결 상태를 보여 준다.

## 검증·운영

- 새 로컬 Supabase에서 전체 마이그레이션 적용. 합성 PDF 투고 → chair 2인 배정 → 세 가지 추천 → AE 판정 → 저자 의견 확인 → 수정 PDF·재투고 → 재심·채택, reject 경로를 검증한다.
- 익명/다른 분야/저자 AE/일반 회원의 차단, 판정 전 의견 비공개, 임의 원고 수정·운영 쓰기 차단, 오래된 snapshot 거절을 실제 API로 확인한다.
- desktop 1440px·mobile 390px에서 위원 명부·심사·판정 화면과 키보드 접근을 확인한다. typecheck/build, legacy JS syntax, diff check.
- 운영은 추가 schema/명부만 적용. 되돌릴 때 이전 배포로 복귀하고 명부 AE를 비활성화하면 추가 권한이 회수된다. 기존 원고와 심사 이력을 삭제하지 않는다.
