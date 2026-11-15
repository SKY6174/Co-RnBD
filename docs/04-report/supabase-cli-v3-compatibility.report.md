# Supabase CLI 3 호환성 작업 결과

2026-11-07 · [PR #59](https://github.com/SKY6174/Co-RnBD/pull/59) · [검증 상세](../03-analysis/supabase-cli-v3-compatibility.analysis.md)

Supabase CLI를 공식 최신 안정판 3.0.0으로 통일했다. 로컬 명령·기존 생명주기 검증 스크립트·PR CI가
동일한 버전 기준을 사용하며 다른 버전에서는 명령 실행을 차단한다. CLI 3에서 이동된 OrioleDB
설정과 폐기 예정 인증 provider 키를 현재 키로 정리하고 원격 대상·변경 동의 절차를 문서화했다.

전체 17개 페이지의 재실행 가능한 읽기 전용 검사를 추가했다. 로컬 프로덕션 빌드에서 Chromium·WebKit,
1440px·390px의 68개 조합과 API·공개 DB 읽기·익명 권한 차단·URL·자산 검사를 통과했다.
타입 검사·빌드·보안 감사·CLI 회귀·캐시 회귀도 통과했다. 실제 CLI로 운영 DB 읽기 전용 조회가 성공했다.

운영 데이터·RLS·DB 스키마·메일·운영 Auth 설정은 변경하지 않았다. 인증 이후 쓰기 생명주기는
별도 안전한 환경에서 검증해야 한다. 병합·Vercel 운영 배포 커밋과 배포 후 재검증 결과는 PR의
Validation에 기록한다. 복구는 PR revert 또는 직전 Vercel 배포를 사용한다.
