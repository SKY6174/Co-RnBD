# Next.js·TypeScript 전환 기획

> 2026-09-27 · 기능 브랜치 작업 · 기준: origin/main 4c6f28d

## 목적

현재 `site/`의 여러 HTML, 브라우저 JavaScript, Vercel Functions를 Next.js App Router와 TypeScript 기반 프로젝트로 옮긴다. 현재 학회와 지난 학회의 공개 경로, 2026 CFP 원문, 투고·심사, 참가 신청, 위원장 운영 흐름을 유지한다.

## 범위와 성공 기준

- Vercel의 Root Directory `site/`를 유지하고 그 안에 Next.js 앱을 둔다.
- 모든 기존 `*.html` URL, `/api/config`, `/api/naver-userinfo`, OAuth 회귀 URL을 유지한다.
- 공통 라우팅, 메타데이터, API 계약, 클라이언트 설정을 TypeScript로 정의한다.
- 공개 콘텐츠와 폼의 모든 ID, 데이터 흐름, 확정/가안 표기를 보존한다.
- 기존 Supabase 스키마, RLS, Storage 정책, 개인정보에는 변경하지 않는다.
- 설치, TypeScript 검사, 프로덕션 빌드, 주요 경로와 API의 로컬 HTTP 확인, 모바일/데스크톱 시각 확인을 통과한다.
- 새 브랜치에 커밋·푸시하고 PR과 Vercel Preview를 확인한다. `main` 병합과 프로덕션 배포는 별도 승인 대상이다.

## 이행 원칙

기능 회귀 위험이 큰 DOM 기반 투고·운영 스크립트는 첫 전환에서 호환성 계층으로 옮겨 동작을 보존한다. 새 공개 셸과 라우트·API는 TypeScript로 구성하고 후속 단계에서 각 역할별 UI를 선언형 컴포넌트로 분리한다. 기존 HTML을 Next가 정적 페이지로 제공하되 URL과 인증 콜백을 유지한다.

## 위험과 확인

| 위험 | 대응 |
|---|---|
| HTML URL 변경으로 OAuth/북마크 중단 | `*.html` 경로를 Next rewrite로 유지 |
| DOM 스크립트 초기화 순서 변경 | 페이지별 스크립트를 hydrate 이후 한 번만 로드하고 주요 상태 확인 |
| 배포 빌드가 원격 데이터에 의존 | 공개 페이지는 정적 렌더, Supabase 요청은 브라우저에서 수행 |
| Preview가 운영 DB 사용 | 계정 생성·데이터 쓰기 검증은 수행하지 않고 읽기·권한 경로만 확인 |
| 기존 시각 스타일 훼손 | CSS·콘텐츠 유지, 공통 탐색/응답형 개선만 적용 |
