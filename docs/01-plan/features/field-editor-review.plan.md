# 분야별 편집위원 심사 흐름 — Plan

2026-11-07. 기존 2인 심사에 분야별 AE의 판정·저자 통보를 추가한다.

- Chief editor: 기존 chair 계정 song.kyoung.young@gmail.com. 전 분야 심사 요청·배정·운영 권한을 유지한다.
- 테스트위원1 uc.thomas78@gmail.com, 테스트위원2 thomas78.song@gmail.com: 현행 네 분야 심사위원.
- 같은 두 계정을 테스트AE1(전문기술석사 공학/자연과학), 테스트AE2(산학공동/기타 산학융합)로 임시 지정한다. 위원장이 변경 가능하다.
- 심사위원은 Accept / Accept after revision / Reject와 의견을 제출한다. AE는 두 심사를 확인하고 판정·수정 요구를 저자 포털에 공개한다. 수정 후 채택은 즉시 채택이 아닌 revision → 수정 투고 → 새 심사 → accepted 흐름이다.
- AE는 현재 회차의 담당 분야 제출 원고만 열람·판정한다. 저자·공동저자 원고의 편집 권한은 없다. 운영 설정·심사 배정·최종본 확인은 chair 권한이다.
- 기존 원고·권한·PDF를 보존하는 추가 마이그레이션. 먼저 격리 로컬에서 Auth·RLS·Storage·브라우저 전체 절차를 검증한다.
- 사용자 승인 범위: PR 생성, push, merge, production deploy. 운영 테스트는 합성 원고만 사용하고 실제 원고/접수 단계는 변경하지 않는다.
