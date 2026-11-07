# Supabase CLI 3 호환성 검증

2026-11-07 · [설계](../02-design/features/supabase-cli-v3-compatibility.design.md) · [PR #59](https://github.com/SKY6174/Co-RnBD/pull/59)

## 설계 대비 결과: 9/9 구현

| 설계 항목 | 결과 |
|---|---|
| 공식 최신 안정판 단일 버전 파일 | 3.0.0: GitHub latest와 Homebrew 설치 버전 일치 |
| 버전 검사·기본 workdir·명시적 workdir 보존 | 공통 실행 스크립트, 다른 버전의 DB 명령 실행 차단 검증 |
| 현재 설정 키 사용 | OrioleDB 이동, 이메일/SMS enabled 값 보존, 실제 CLI 경고 없는 파싱 |
| 기존 로컬 생명주기 스크립트 통합 | 동일 버전 검사 진입점으로 변경 |
| CI 설치·호환성 검사 | 공통 버전 파일과 고정 Action SHA 사용, GitHub 검사 통과 |
| 원격 대상·동의·운영 설정 문서 | remote/read-only/yes/config diff와 로컬 설정 push 주의 명시 |
| 전체 페이지·경로·자산 | 레지스트리 17개 페이지, 34개 clean/HTML URL, 전체 legacy 자산 해시 일치 |
| 브라우저·API·권한 | 로컬 프로덕션 빌드 68개 조합 통과, 공개 DB 조회와 7개 비공개 테이블 익명 차단 |
| 변경 범위·복구 절차 | DB/RLS/운영 config 변경 없음, PR revert·이전 Vercel 배포로 복구 |

## 실행 증거

- `npm ci`, `npm audit --omit=dev --audit-level=high`(취약점 0건), typecheck, production build 통과.
- 실제 CLI 3.0.0의 config 파싱·로컬 기본 대상·원격/동의/읽기 전용 플래그 확인 통과.
- 명시적 운영 대상의 `db query --read-only`로 `current_database()` 조회 성공.
- 기존 runtime-config 캐시 회귀 검사, Python 파싱, shell 문법, diff 검사 통과.
- Chromium 156·WebKit 27.2, 1440px·390px에서 17개 페이지 각각 통과(68회).
  JS 예외·HTTP 실패·가로 넘침 없음. 로그인 보호, 잘못된 문서 주소, 모바일 메뉴와 날짜 탭 키보드 동작 확인.
- `/api/config` 공개 가능 필드, Naver API 401, 잘못된 메서드 405, 없는 페이지 404 확인.
- 브라우저 변경 요청 0건. 로컬 빌드의 API에는 공개 가능 운영 연결 값만 전달했고 DB 조회는 익명 읽기만 수행했다.

검증 JSON·화면은 작업 머신의 `/tmp/co-rnbd-cli3-local/`에 저장했다. 운영 사이트의 전체 검사와
배포 이후 결과는 PR의 Validation에 기록한다. Vercel Preview는 이 브랜치에 생성되지 않았으며
Supabase Preview 검사도 연결 서비스에서 skipped로 보고했다.

## 범위와 한계

공개 페이지와 비로그인 권한 보호 상태의 호환성 검사다. 실제 계정 로그인, 원고/PDF 제출,
심사·판정, 참가신청, 문서 발급의 쓰기 생명주기는 실행하지 않았다. CLI 변경은
브라우저 SDK 업그레이드나 운영 Supabase 서비스 업그레이드를 뜻하지 않는다.
