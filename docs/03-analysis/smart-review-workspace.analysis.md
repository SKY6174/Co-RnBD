# 스마트 투고·심사 작업 공간 — 설계 대조·검증

2026-11-08. [설계](../02-design/features/smart-review-workspace.design.md).

| 요구사항 | 최종 구현·검증 |
| --- | --- |
| 다음 작업 요약 | 프로필/전문분야, 수정 요청, 심사 대기, 초안 순 안내. 실제 단계가 닫혔으면 확인을 안내 |
| 원고 찾기 | 저자·심사위원 제목/접수번호 검색, 상태 필터, 결과 없음, 초기화 및 목록 이동 확인 |
| 정확한 상태 | 원고 4단계와 수정본 대기, 본인 심사 상태를 별도 표시. 판정 후 심사 기록 확인 문구 |
| 편집 우선 업무 | 분야 필터에 따른 통계와 현재 제출본의 유효 심사 2건 native progress/숫자 확인 |
| 역할·권한 | AE의 배정/최종본 권한 추가 없음. 두 분야 AE/저자·공동저자/익명 접근 차단 회귀 PASS |
| 키보드 | 탭 좌우/Home/End, 숨은 심사 탭 제외, 결과 초기화 후 검색 초점, 상세 복귀 시 원래 버튼 초점 |
| 상세·알림 | 빠른 이동 링크, 최신 3건/이전 기록 펼침. 재시도·실패·불확실 기록이 있으면 펼침 표시 |
| 시각 구성 | 기존 forest/teal/lime 스타일, 로그인 뒤 압축 히어로, 요약·진행 카드, 1440/390px 확인 |
| 접근성 | Chromium/WebKit 22개 화면의 axe-core 4.14.0 WCAG A/AA 위반 0, 브라우저 오류/외부 쓰기 0 |
| 기능 회귀 | 실제 Auth/Storage 투고 2건·수정본 1건·2인 심사·AE 수정/채택/반려, 브라우저 8묶음 PASS |
| 메일 호환 | 기존 v1~v4 8묶음 PASS. 30개 workflow 이벤트·36개 provider 접수·41개 요청, 중복/응답 유실 복구 |
| 정적 검사 | TypeScript/build, JS syntax, HTML IDs/label/control 대상, Python compile, CLI 호환, diff PASS |

격리 환경 `/tmp/co-rnbd-smart-review-20261108/`의 editorial-results.json, email-results.json,
accessibility-results.json 및 polished-*.png에 증거를 보존했다. 새 접근성 검사는 완료된 합성 5계정 fixture만
허용하며 3계정의 테스트 비밀번호를 일회성 값으로 바꾼다. 운영 키·계정은 사용하지 않는다.

modern-web-guidance accessibility의 실제 탭 동작/명시적 라벨/포커스 표시, color의 텍스트 대비/상태 텍스트/
forced-colors 대체 경계를 적용했다. 접수 마감 시 초안 안내와 판정 공개 완료 문구는 추가 격리 DB/브라우저 검증 2건을 통과했고 임시 원고·단계를 복원했다. 자동 검사는 보조기술 사용자 검수를 대체하지 않는다.

운영 적용 전 읽기 확인: 논문/심사/대기 메일 0, 기존 모든 발송 flag 활성, 위원장 수신자 1계정, 오류 없음.
이 기능은 DB migration/API/메일 양식/자격증명을 변경하지 않는다. Preview/운영에서는 익명 읽기 검증만 하며
실제 원고·심사·이메일을 생성하지 않는다. 롤백은 이전 production 배포(dpl_BHj6Tnzhhmjq21xYZkwqQagYV7Nx,
main 26d1fc2) 복원이다. 최종 배포/운영 검증 결과는 PR 설명에 기록한다.
