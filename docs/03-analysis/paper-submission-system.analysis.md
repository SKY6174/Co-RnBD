# 투고·심사 시스템 설계 대비 확인

> 2026-09-26 · 설계: `docs/02-design/features/paper-submission-system.design.md`

## 일치율: 85% (17/20)

정적 사이트와 Vercel 설정 함수, 프로필, 원고·공동저자·PDF 버전, 심사 배정·권고·판정, 상태 흐름, RLS, 비공개 Storage, 접수 제어, 이메일 가입·로그인·재설정, Naver/Google 브랜드 버튼, 모바일 화면 등 17개 설계 항목을 구현했다.

## 확인한 동작
- Supabase 원격 마이그레이션 `20260925170900` 적용 및 이력 확인
- `conference_settings` 익명 조회 200·기본 `submissions_open=false`; 원고·심사 테이블 익명 조회 401
- Vercel 생산 배포 및 실제 도메인 `/submission.html` 200, `/api/config` 응답
- `/api/naver-userinfo`에 토큰이 없으면 401
- 로그인 전 화면의 모바일 390px·데스크톱 1280px 렌더 확인
- JavaScript 문법 검사와 `git diff --check` 통과
- Supabase Auth 설정상 이메일 제공자 활성화·가입 허용·이메일 확인 사용 중 확인

## 아직 확인되지 않은 3개 항목
1. Google/Naver OAuth 앱 Client ID·Secret과 콜백 URL을 등록하고 실제 로그인 흐름을 검증해야 한다. 현재 두 소셜 로그인은 비활성화 상태다.
2. 이메일 확인 및 비밀번호 재설정 메일을 실제 수신하고, 본운영용 SMTP 발송을 검증해야 한다. 현재 Supabase 기본 발송 설정을 사용한다.
3. 사용자 로그인 후 저자 제출 → 심사위원 배정·PDF 열람 → 위원장 판정까지 역할별 통합 검증이 필요하다. 최초 위원장 계정 지정과 시험 계정이 필요하다.

## 부가 관찰
원격 Supabase 보안 Advisor는 이번 마이그레이션 객체가 아닌 기존 `public.rls_auto_enable()`의 익명·로그인 사용자 실행 권한을 경고한다. 별도 권한 검토가 필요하다. `supabase db lint --linked` 및 `db query --linked`는 연결 후 응답이 없어 중단했고, 마이그레이션 이력·Advisor·Data API 직접 조회로 적용 상태를 확인했다.

## 다음 작업
OAuth 앱과 SMTP를 연결하고 위원장 계정을 지정한 뒤 역할별 실제 접수 흐름을 검증한다. 개인정보 보존기간과 투고 일정 확정 전에는 접수 스위치를 닫아 둔다.
