# 투고·위원회 기본 정보 입력 설계

## 구조와 화면

정적 `site/submission.html`의 내 정보, 원고 입력, 위원장·심사위원 화면과 `site/submission.js`의 Supabase Data API 호출만 확장한다. 기존 반응형 2열/모바일 1열 폼을 유지한다. 프로필이 미완성이어도 로그인·기존 원고 조회·초안 편집은 허용하고 제출 직전 내 정보 탭으로 안내한다.

### 공통 프로필

`full_name`과 `affiliation`은 필수, Auth에서 온 `email`은 읽기 전용이다. `department`, `position_title`, `orcid`는 선택이다. 위원회 활동 항목에서 `expertise_tracks`를 기존 원고 분야 네 가지의 복수 선택(최대 3개)으로 저장한다. `committee_listing_consent`는 기본 false이며 공개 위원 명단 페이지가 도입되기 전에는 어디에도 노출하지 않는다. 전문 분야는 심사 제출 전에 최소 1개 필요하지만 저자만 활동하는 회원에게는 강제하지 않는다.

### 원고

`papers.contact_name`과 `papers.contact_email`은 교신·운영 연락 담당자의 제출 당시 스냅샷이며 새 원고에서 프로필 이름·인증 이메일로 채운다. 수정할 수 있지만 제출 시 필수다. `papers.keywords`는 선택 항목이며, 입력할 경우 쉼표로 구분한 2~5개를 받는다. 연락 담당자가 공동저자인지 여부는 요구하지 않는다. 기존 저자 목록의 이름·소속과 PDF 필수 규칙은 유지한다. 위원장 원고 상세에 연락처·키워드를 표시한다.

### 심사

심사 배정은 현재처럼 위원장이 계정 이메일로 수행한다. 심사위원은 배정 원고를 열 수 있으나 전문 분야와 필수 프로필이 없으면 심사 제출을 내 정보 탭으로 안내한다. 원고별 이해관계 확인/배정 거절은 현행 절차를 쓴다. 공개 명단 동의는 역할 부여나 심사 권한을 변경하지 않는다.

## DB 모델과 검증

- `profiles`: `department text not null default ''`(최대 120자), `position_title text not null default ''`(최대 120자), `orcid text not null default ''`(빈 값 또는 ORCID iD 형식), `expertise_tracks text[] not null default '{}'`(기존 분야 코드만, 최대 3개), `committee_listing_consent boolean not null default false`. 기존 이메일·사용자 ID 보호 트리거를 유지하고 프로필 수정 시 필수 이름·소속의 빈 문자열을 막는다.
- `papers`: `contact_name text not null default ''`(최대 120자), `contact_email text not null default ''`(최대 254자·기본 이메일 형식), `keywords text[] not null default '{}'`(선택, 입력 시 2~5개). 기존 `draft`/`revision` 원고에는 빈 값이 허용된다. `submitted`/`under_review`/`accepted`/`rejected` 상태에는 연락처를 요구하며 키워드는 비워둘 수 있다.
- 제출 전 DB 트리거는 원고 소유자의 프로필 이름·소속을 검사한다. 심사 제출 전 트리거는 심사위원의 이름·소속 및 전문 분야 1~3개를 검사한다. 브라우저 검사와 별도로 API 직접 호출에도 적용된다.
- 기존 `profiles`, `papers`, `reviews` RLS를 유지한다. 새 컬럼은 해당 행과 동일한 접근 범위를 갖는다. `staff_roles`는 바꾸지 않으며 전문 분야 입력만으로 심사위원 역할을 얻지 못한다.
- 기존 자료의 신규 칼럼은 안전한 기본값으로 채워진다. 적용 전 운영 원고 건수·상태를 확인한다.

## 구현 파일

1. Supabase CLI로 새 마이그레이션을 생성한다. 운영 DB에 이미 적용된 선행 마이그레이션 파일이 원격 Git에 없다면 사본을 이 브랜치에 포함한다.
2. `site/submission.html`: 선택 프로필 필드, 전문 분야·공개 동의, 연락 담당자·키워드 입력 및 안내.
3. `site/submission.js`: 프로필 로딩/저장, 새 원고 기본값, 원고 로딩/저장, 검증 및 위원장 상세 표시.
4. `site/submission.css`: 체크박스 그룹, 연락처 안내, 모바일 배치.

## 검증

- SQL 마이그레이션 적용 후 컬럼·제약·트리거·RLS를 조회한다. 익명 계정은 개인 정보를 조회할 수 없어야 한다.
- 프로필·원고 필드가 저장·재조회되며 미완성 초안은 유지, 미완성 제출은 거부되는지 확인한다.
- 전문 분야가 없는 심사 제출은 거부되고 1~3개 선택 시 정상 진행되는지 확인한다.
- JS 문법과 브라우저 390px/데스크톱 렌더, 기존 로그인 및 목록을 확인한다. 실제 사용자의 OAuth 세션은 대리 로그인하지 않는다.
