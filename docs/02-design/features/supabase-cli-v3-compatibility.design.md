# Supabase CLI 3 호환성 설계

2026-11-07 · [계획](../../01-plan/features/supabase-cli-v3-compatibility.plan.md)

## 구현

- `.supabase-cli-version`에 공식 안정판 `3.0.0`을 기록한다. 사전 릴리스는 사용하지 않는다.
- `scripts/supabase.sh`는 설치 버전을 이 파일과 비교하고 불일치 시 실행을 중단한다.
  저장소 루트를 기본 workdir로 전달하며 사용자가 명시한 workdir는 존중한다.
  원격 대상이나 `--yes`를 자동 추가하지 않는다. 기존 로컬 생명주기 검사도 이 진입점을 사용한다.
- `supabase/config.toml`의 `orioledb_version`을 `db`로 이동하고 이메일·SMS provider 토글을
  `enabled`로 바꾼다. `auth.enable_signup`과 활성화 값, 로컬 메일함, 포트·권한은 보존한다.
- 기존 PR 품질 검사에 정확한 CLI 버전 설치와 호환성 검사를 추가한다.
  CLI 검사는 버전·설정 키와 실제 CLI 설정 파싱, 원격 플래그 지원을 확인한다.
- README에 동일 CLI 실행, 로컬 기본 대상, 원격 읽기의 `--remote`/`--read-only`,
  사전에 검토·승인한 원격 변경의 `--yes`, 운영 config diff 절차를 명시한다.
  자동 DB 배포는 추가하지 않는다.

## 전체 페이지 검증

`scripts/verify-site-compatibility.py`는 `site/lib/pages.ts`에서 경로를 읽어 새 페이지 누락을 방지한다.
설정한 base URL의 `/`와 17개 HTML URL 및 clean URL을 검사한다. 브라우저는 새 익명 컨텍스트를
사용하고 GET/HEAD/OPTIONS 외 요청을 차단한다. API 설정·공개 회차/프로그램 조회와 7개 비공개
테이블의 익명 접근 차단을 확인하며 실제 개인 정보를 출력하거나 저장하지 않는다.

Chromium에서 1440px·390px로 전체 페이지를 검사한다. 페이지 본문·초기화 결과,
로그인 보호 패널·숨겨진 작업 공간, JS 예외·자산 실패·가로 넘침을 확인한다.
연도 페이지는 현재 회차 파라미터도 검사하고 문서 페이지는 문서 ID가 없는 오류 상태를 검사한다.
결과 JSON과 화면은 저장소 밖 지정 폴더에 저장한다. 실제로 실행한 검사만 통과로 기록한다.

## 검증·배포

설정 검사와 기존 캐시 검사, npm ci/audit/typecheck/build, diff 검사를 실행한다.
실제 CLI의 운영 읽기 전용 SQL, 전체 페이지의 브라우저→API→공개 DB→UI 경로를 검사한다.
GitHub PR 검사가 통과하면 요청된 병합을 수행한다. Vercel Git 배포의 READY·커밋·도메인을
확인하고 운영 사이트에 동일 읽기 전용 검사를 재실행한다.

DB/RLS·운영 설정·사용자 계정·메일·원고/증빙 쓰기는 변경하지 않는다. 문제 시 PR을 revert하고
직전 Vercel 배포로 복구한다. 인증 이후 전체 쓰기 생명주기는 별도 안전한 환경이 필요하다.
