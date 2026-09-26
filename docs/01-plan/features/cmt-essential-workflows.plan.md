# CMT 필수 운영 흐름 보강 — Plan

> 2026-09-26 · Dynamic · [기존 투고 시스템 설계](../../02-design/features/paper-submission-system.design.md)를 확장한다.

## 목적

Microsoft CMT 도움말의 메뉴를 역할별로 검토하고, 한 차례 전문대학 컨퍼런스에 필요한 흐름만 현재 투고 시스템에 반영한다. 심사위원 2명과 위원장 최종 판정이라는 단순한 구조를 유지한다.

## 메뉴별 판단

| CMT 메뉴 | 현재 상태 | 이번 범위 |
|---|---|---|
| Workflow | 접수 개폐만 있음 | 접수·심사·최종본 단계와 선택적 마감 시각을 관리 |
| Account | 이메일/Google/Naver 로그인, 프로필, 비밀번호 재설정 | 계정별 사용 안내를 명확히 표시 |
| Chair | 배정·판정 가능 | 공동저자 본인 심사 배정 차단, 저자·심사 현황 표시, 단계 제어 |
| Proceeding Editor | 별도 역할 없음 | 위원장이 채택 원고의 최종본을 확인 |
| Senior Meta-Reviewer / Meta-Reviewer | 별도 역할 없음 | 위원장이 심사 의견 2건을 종합해 판정 |
| Reviewer / External Reviewer | 배정·이해관계 거절·심사 가능 | 단계 개폐와 마감 적용, 심사 PDF 범위 유지 |
| Author | 초안·PDF·제출·수정·결과 확인 가능 | 채택 후 최종 PDF를 별도 단계로 제출 |
| FAQ / Support | 화면 내 설명만 있음 | 이 행사에 맞는 계정·투고·심사·판정·최종본 안내 제공 |

다중 학회 사이트 개설, 자동 배정·입찰, 복잡한 메타심사, 외부심사 재위임, IEEE/ACM/TPMS/iThenticate 연동은 첫 행사 운영에 필요하지 않다. 결정 이메일 자동 발송은 발송 인프라가 준비되지 않았으므로 도입하지 않고, 저자는 로그인 후 결과를 확인한다.

## 작업 범위

1. 실제 Supabase 스키마·마이그레이션·RLS·보안/성능 advisory를 점검한다.
2. 단계별 개폐와 선택적 마감 시각을 위원장 화면과 DB에 연결한다. 수정 요청된 원고는 일반 접수 종료 후에도 재제출할 수 있다.
3. 심사위원의 이메일이 공동저자 이메일과 일치하면 DB에서 배정을 거부한다. 같은 기관·과제 관계는 위원장이 추가 확인한다.
4. 채택 원고의 최종 PDF를 기존 비공개 버킷에 구분 저장하고, 저자·위원장만 열람하게 한다.
5. 역할별 도움말과 접수·심사·최종본 상태를 모바일·웹 화면에 표시한다.

## 성공 조건

- 접수·심사·최종본 개폐와 마감이 DB에서 강제되고 화면에서도 동일하게 안내된다.
- 공동저자 자신에게 심사 배정을 만들 수 없다.
- 채택 전이나 최종본 단계 종료 후 최종 PDF를 올릴 수 없다.
- 최종 PDF는 저자·위원장에게 보이되 심사위원에게는 보이지 않는다.
- 기존 원고와 파일은 마이그레이션 후에도 읽을 수 있다.
- 정적 JS 검사, DB 적용 확인, RLS/보안 advisor, 실제 배포 확인을 마친다.

## 참고

- [CMT Workflow](https://cmt3.research.microsoft.com/docs/help/overview/tasks.html)
- [CMT User Roles](https://cmt3.research.microsoft.com/docs/help/overview/roles.html)
- [CMT Author Submission](https://cmt3.research.microsoft.com/docs/help/author/author-submission-form.html)
- [CMT Review Settings](https://cmt3.research.microsoft.com/docs/help/chair/review-settings.html)
- [CMT Author Notification](https://cmt3.research.microsoft.com/docs/help/chair/author-notification.html)
