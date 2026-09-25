# Co-R&BD Conference 2026 사이트 시안

행사 안내와 논문 투고·심사 사이트입니다. 첫 화면은 `index.html`, 모집공고 전문은 `cfp.html`, 역할별 투고 화면은 `submission.html`입니다. 모집공고 원문 초안은 [CFP 문서](../outputs/co-rbd-2026-cfp-draft.md)에서 확인할 수 있습니다.

## 로컬 보기

```sh
python3 -m http.server 8765 --directory site
```

브라우저에서 `http://127.0.0.1:8765/`를 엽니다. 정적 파일만 사용하므로 `site/index.html`을 직접 열어도 볼 수 있습니다.

## 현재 범위

- 행사명·목적·발표 분야·1박 2일 프로그램·CFP 요약·참가 안내
- 국·영문 CFP 전문과 확정/가안 일정의 구분
- 모바일 메뉴와 날짜별 프로그램 탭
- 확정 개최일·동부캠퍼스·일반 참가신청 마감과 미확정 투고 일정·접수처 구분 표시

## 공개 전 연결할 항목

1. 동부캠퍼스 건물·호실, 공동주최·주관·로고, 연사, 등록비 승인
2. 기관 발급 행사 URL과 공식 사무국 이메일
3. 승인된 원고 투고·심사 도구와 참가등록 도구의 실제 링크
4. 개인정보 안내, 환불 기준, 숙박·셔틀·자료집 공개 범위
5. 실제 원고 제출·등록·체크인 흐름의 권한별 검수

투고 시스템은 준비 상태로 배포되며 원고 접수는 기본적으로 닫혀 있습니다. 개최일은 2026년 12월 17–18일, 장소는 울산과학대학교 동부캠퍼스, 일반 참가신청 마감은 10월 30일 18:00 KST로 확정됐습니다. 발표자는 채택 후 별도 등록하며 논문 일정과 프로그램은 가안입니다.

## 투고 시스템 운영 설정

1. Vercel 프로젝트 루트가 `site/`인지 확인하고 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`를 설정합니다. 이 두 값만 `/api/config`에서 공개합니다. 서비스 역할 키는 웹·Vercel 공개 환경변수에 넣지 않습니다.
2. Supabase Auth의 Site URL을 `https://co-rnbd.org`로, 허용 Redirect URL에 `https://co-rnbd.org/submission.html`을 등록합니다.
3. Google Cloud OAuth 웹 앱을 만들고 Google 제공자 화면에 표시된 Supabase callback URL을 Google의 승인된 리다이렉트 URI에 등록합니다. Client ID/Secret은 Supabase Auth Providers의 Google 설정에만 입력합니다.
4. Naver 개발자 앱에 Supabase 사용자 지정 provider의 callback URL을 등록합니다. Supabase Auth의 Custom OAuth Provider를 `custom:naver`로 만들고 Authorization URL `https://nid.naver.com/oauth2.0/authorize`, Token URL `https://nid.naver.com/oauth2.0/token`, UserInfo URL `https://co-rnbd.org/api/naver-userinfo`를 사용합니다. Naver 프로필의 중첩된 `response` 객체를 Vercel 함수가 표준 `sub`/`email`/`name`으로 변환합니다. Naver의 PKCE 지원 여부 및 토큰 교환 방식은 실제 앱 자격증명으로 확인해야 합니다. 제공자 설정이 지원하지 않으면 Naver 버튼은 열지 말고 별도 인증 어댑터를 검토합니다.
5. 위원장으로 사용할 계정이 한 번 로그인한 후 Supabase SQL Editor에서 해당 이메일을 확인하고 아래처럼 최초 역할을 부여합니다. 이 역할은 웹에서 셀프 부여할 수 없습니다.

```sql
insert into public.staff_roles (user_id, role)
select id, 'chair' from auth.users where email = 'chair@example.edu'
on conflict (user_id) do update set role = excluded.role;
```

6. 개인정보 보존기간·공고 일정·기관 승인 후 위원장 작업 공간에서 **접수 열기**를 누릅니다. 심사위원은 먼저 로그인한 계정 이메일로 배정합니다. 원고당 2명 배정을 권장합니다.

관련 설계: [`docs/02-design/features/paper-submission-system.design.md`](../docs/02-design/features/paper-submission-system.design.md). [Google OAuth](https://supabase.com/docs/guides/auth/social-login/auth-google), [사용자 지정 OAuth](https://supabase.com/docs/guides/auth/custom-oauth-providers), [Naver API](https://developers.naver.com/docs/login/api/api.md).
