# Next.js·TypeScript 전환 보고

> 2026-09-27 · PR: https://github.com/SKY6174/Co-RnBD/pull/11

## 결과

- `site/`를 Next.js 16 App Router와 TypeScript 기반으로 전환했다. Vercel Root Directory는 `site/`를 유지했다.
- 2026 공개 페이지와 연도별 공개 페이지, 투고·심사, 참가 신청, 위원장 운영 및 정책 문서를 새 라우트로 제공한다. 기존 `.html` 주소와 Auth 회귀 URL은 유지한다.
- 공개 페이지 메뉴·날짜 탭은 TypeScript 컴포넌트로 옮겼다. 데이터 포털의 DOM 스크립트는 기능 보존을 위해 호환 계층으로 옮겼다.
- `/api/config`와 `/api/naver-userinfo`는 TypeScript Route Handler다. 역할별 로컬 검증에서 발견한 심사위원 배정 RLS 순환을 수정하는 마이그레이션을 PR에 추가했다. 운영 DB에는 적용하지 않았다.
- Vercel Framework Preset을 `Other`에서 `Next.js`로 바꾸고 Preview를 다시 배포했다. 현재 프로덕션 배포는 변경하지 않았다.

## 검증

`npm ci`, TypeScript 검사, 프로덕션 빌드, 로컬 HTTP, 데스크톱·390px 시각/상호작용 확인, Preview 읽기 요청, `git diff --check`가 통과했다. Preview 배포는 Ready이고 주요 경로와 API가 200으로 응답했다. 별도 로컬 Supabase에서는 저자 제출·PDF, 위원장 배정·판정, 심사위원 조회·심사 제출·배정 거절, 미배정 사용자의 접근 차단을 Data API와 브라우저에서 확인했다.

## 남은 운영 작업

Preview가 운영 Supabase를 사용하므로 운영 환경의 실제 계정·파일·원고·심사·참가 신청 쓰기 흐름은 검증하지 않았다. 새 RLS 마이그레이션은 운영 반영 시 별도로 적용하고 배정·조회·거절 경로를 다시 확인해야 한다. `main` 병합과 프로덕션 배포는 승인 전까지 보류한다. OAuth 제공자 가용성은 이 작업에서 변경·검증하지 않았다.
