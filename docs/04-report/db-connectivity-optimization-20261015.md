# DB 연결 및 포털 최적화 검증 — 2026-10-15

## 변경

- 공개 연결 설정 캐시의 저장/읽기 구조 불일치 수정. 5분 TTL 이후 같은 페이지에서도 재조회하며 실패 후 재시도 가능.
- 위원장 목록은 명시적 요약 열만 조회. 해당 원고 상세와 이력은 필요할 때 병렬 조회하며 전체 심사 스냅샷으로 판정 동시성 검사를 유지.
- 투고 화면 인증 초기화 중복 호출 제거 및 진행 중인 요청 공유. 계정 변경 후 오래된 응답 반영 방지.
- 참가신청의 중복 초기 조회 제거. 동일 계정의 토큰 갱신 시 입력 폼 보존.

## 수정 전후 측정

격리된 로컬 Supabase의 동일 데이터와 동일 위원장 계정으로 각 화면을 3회 방문했다. 로그인 후 같은 탭 내 이동이며 API·Auth·PostgREST 요청을 집계했다. 응답 크기는 압축 해제 후 바이트이다.

| 항목 | 이전 | 변경 후 |
| --- | ---: | ---: |
| 위원장 목록 원고 응답 | 30,611 bytes | 8,920 bytes (70.9% 감소) |
| 위원장 화면 초기 요청 | 6 | 5 |
| 참가신청 초기 요청 | 11 | 6 |
| 투고 화면 초기 요청 | 19 | 8 |
| 유효 캐시 보유 시 화면당 설정 요청 | 1 | 0 |

각 3회 측정에서 요청 수와 바이트 수가 동일했다. 개발 서버 컴파일과 로컬 통신의 영향이 있으므로 측정된 준비 시간을 운영 응답 속도 향상 수치로 제시하지 않는다. 원고가 없는 운영 DB의 부하 성능도 추정하지 않는다.

재현: `uv run --with playwright python scripts/measure-portal-requests.py <label>`.
결과: `outputs/db-response-optimization/{before,after}.json` (커밋하지 않는 로컬 증거).

## 운영 DB 읽기 점검

- 프로젝트 `lvtdnrmwunahgwutafhv`, 마이그레이션 26개가 저장소와 일치. 마지막 `20261014223540_guard_chair_review_snapshot`.
- 원고·회원·심사·파일·이력·최종본 확인·참가신청·설정에 RLS 활성화.
- 접수/등록 열림, 심사/최종본 닫힘 유지. 운영 테이블·데이터·정책 수정 없음.
- 기존 FK 및 주요 필터·정렬 인덱스 확인. 빈 테이블의 미사용 인덱스 통계는 삭제 근거로 사용하지 않음.
- 기존 Advisor 항목: `reviews` UPDATE 및 `program_sessions` SELECT의 복수 허용 정책, 미사용 인덱스, Auth 연결 할당 안내. 정책 합병은 실측 병목이 없어 이번 변경에서 제외.
- 기존 공개 SECURITY DEFINER 안내 2건은 `create_conference_edition`, `activate_conference_edition`이며 함수 내부 로그인/위원장 권한 검사를 확인함.
- Advisor 설명: [복수 허용 정책](https://supabase.com/docs/guides/database/database-linter?lint=0006_multiple_permissive_policies), [공개 SECURITY DEFINER 함수](https://supabase.com/docs/guides/database/database-linter?lint=0028_authenticated_security_definer_function).

## 설계 대조 및 회귀 검증

- `verify-runtime-config.mjs`: 동시 호출, 캐시 적중/만료/손상/잘못된 시간, 저장소 차단, 실패 후 재시도 통과.
- `verify-portal-performance.py`: 요약에 본문·파일 경로 제외, 상세 실패 복구, 최신 전체 심사 조회, 토큰 갱신 시 폼 보존/DB 무요청, 로그아웃, 1440px/390px 화면 통과.
- `verify-chair-desk.py`: 실제 Auth/Postgres/Storage의 제출→배정/교체→수정 요청→재제출/심사→채택→최종본 확인, 권한/이력 불변성 등 9개 그룹 통과.
- `verify-chair-concurrency.py`: 오래된 심사 스냅샷 거부, 양방향 동시성, 모바일 복구/반려, 심사 닫힘 상태의 이해충돌 거절 등 6개 그룹 통과.
- 변경 JS 문법 검사, TypeScript 검사, Next.js 프로덕션 빌드, diff 공백 검사 통과.

## 배포 확인 절차와 한계

사용자가 PR·병합·push·배포를 승인했다. PR Preview에서 변경 소스와 페이지·설정을 확인한 후 main 배포를 사용한다. `scripts/verify-portal-production.py`로 운영 소스 해시, 설정, 공개 조회, 익명 접근 거부, 데스크톱/모바일과 캐시를 확인하고 배포 ID·SHA는 릴리스 결과에 별도 기록한다.

인증된 쓰기 테스트는 로컬 환경에서만 실행했다. 운영 실사용자 계정으로 제출·이메일 발송 테스트를 수행하지 않았다. DB 변경이 없어 롤백은 변경 커밋 되돌리기/이전 Vercel 배포 복원으로 가능하다.
