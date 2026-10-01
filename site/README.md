# T-VET Co-R&BD Conference 2026 사이트 시안

행사 안내와 논문 투고·심사 사이트입니다. Next.js App Router가 첫 화면과 `cfp.html`, `submission.html` 등 기존 공개 URL을 제공합니다. 일반 참가 신청은 `registration.html`, 공개 세션·연사는 `program.html`, 위원장 운영 화면은 `operations.html`입니다. 모집공고 원문 초안은 [CFP 문서](../outputs/co-rbd-2026-cfp-draft.md)에서 확인할 수 있습니다.

`archive.html`은 위원장이 공개한 지난 학회를 연도별로 보여 줍니다. `edition.html`은 연도별 행사 정보와 공개 프로그램으로 연결합니다. 2026의 상세 소개와 CFP는 기존 페이지에 남기고, 다음 회차가 활성화되면 첫 화면은 새 회차 안내로 이동합니다. 위원장은 운영 화면에서 미래 회차 초안을 만들고, 기존 회차가 종료된 뒤 현재 회차를 전환합니다. 아카이브에는 공개 승인된 행사 정보와 프로그램만 포함됩니다.

## 구조와 로컬 보기

```sh
cd site
npm ci
npm run dev
```

브라우저에서 `http://localhost:3000/`를 엽니다. `app/`은 TypeScript 라우트와 API, `content/`는 현재 승인된 페이지 본문, `public/legacy/`는 기존 DOM 기반 투고·운영 클라이언트의 호환 계층입니다. `public/assets/`에 이미지가 있습니다. 기존 `*.html` 주소는 Next rewrite로 유지됩니다. `npm run typecheck`와 `npm run build`로 빌드를 확인합니다. 로컬 연결 설정은 `site/.env.local`에 `SUPABASE_URL`과 `SUPABASE_PUBLISHABLE_KEY`를 입력합니다. 서비스 역할 키는 넣지 않습니다.

## 현재 범위

- 행사명·목적·발표 분야·1박 2일 프로그램·CFP 요약·참가 안내
- 국·영문 CFP 전문과 확정/가안 일정의 구분
- 모바일 메뉴와 날짜별 프로그램 탭
- 확정 개최일·동부캠퍼스·일반 참가신청 마감과 미확정 투고 일정·접수처 구분 표시
- Supabase 기반 일반 참가 신청(계정당 1건), 위원장 확인·체크인, 초안/공개 연사·세션 관리. 접수는 기본적으로 닫혀 있으며 등록비·결제 기능은 없습니다.

## 공개 전 연결할 항목

1. 동부캠퍼스 건물·호실, 공동주최·주관·로고, 연사, 등록비 승인
2. 기관 발급 행사 URL과 공식 사무국 이메일
3. 운영 승인 후 참가 신청 단계 열기와 발표자 별도 등록 절차 확정
4. 개인정보 안내, 환불 기준, 숙박·셔틀·자료집 공개 범위
5. 실제 원고 제출·등록·체크인 흐름의 권한별 검수

투고 시스템은 준비 상태로 배포되며 원고 접수는 기본적으로 닫혀 있습니다. 개최일은 2027년 1월 14–15일, 장소는 울산과학대학교 동부캠퍼스, 일반 참가신청 마감은 2026년 11월 27일 18:00 KST로 조정됐습니다. 발표자는 채택 후 별도 등록하며 논문 일정과 프로그램은 가안입니다.

## 투고 시스템 운영 설정

Google OAuth 앱에 입력할 공개 문서: [개인정보처리방침](https://co-rnbd.org/privacy.html), [서비스 이용약관](https://co-rnbd.org/terms.html). 홈페이지와 투고 화면의 푸터에서도 연결됩니다. 개인정보처리자·문의처·보유기간은 운영자가 확인한 값으로 기재했습니다. 계정·투고·심사 자료는 학회 종료일인 2027년 1월 15일까지 보유하므로, 종료 후 Supabase Auth·데이터베이스·Storage 및 백업의 파기 절차를 실제 운영 계획에 반영해야 합니다.

1. Vercel 프로젝트의 Root Directory를 `site/`, Framework Preset을 `Next.js`로 설정하고 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`를 설정합니다. 이 두 값만 `/api/config`에서 공개합니다. 서비스 역할 키는 웹·Vercel 공개 환경변수에 넣지 않습니다.
2. Supabase Auth의 Site URL을 `https://co-rnbd.org`로, 허용 Redirect URL에 `https://co-rnbd.org/submission.html`을 등록합니다. 이메일 제공자와 이메일 확인을 활성화하고, 본운영 전 전용 SMTP를 연결합니다. 이메일·비밀번호 가입, 로그인, 비밀번호 재설정 메일이 이 설정을 사용합니다. 기본 Supabase 발송 서비스는 테스트 용량이 제한됩니다.
   인증 메일 4종의 제목과 HTML은 `supabase/config.toml` 및 `supabase/templates/`에 버전 관리하며, 운영 프로젝트의 Authentication → Emails에도 적용했습니다. `supabase/config.toml`에는 로컬 개발용 값(`auth.email.enable_confirmations = false` 등)이 포함되어 있습니다. 운영 프로젝트에 `supabase config push`를 실행하기 전에는 설정 전체를 운영 값과 비교해야 합니다.
3. Google Cloud OAuth 웹 앱을 만들고 Google 제공자 화면에 표시된 Supabase callback URL을 Google의 승인된 리다이렉트 URI에 등록합니다. Client ID/Secret은 Supabase Auth Providers의 Google 설정에만 입력합니다.
4. Naver 개발자 앱에 Supabase 사용자 지정 provider의 callback URL을 등록합니다. Supabase Auth의 Custom OAuth Provider를 `custom:naver`로 만들고 Authorization URL `https://nid.naver.com/oauth2.0/authorize`, Token URL `https://nid.naver.com/oauth2.0/token`, UserInfo URL `https://co-rnbd.org/api/naver-userinfo`를 사용합니다. Naver 프로필의 중첩된 `response` 객체를 Next.js Route Handler가 표준 `sub`/`email`/`name`으로 변환합니다. Naver의 PKCE 지원 여부 및 토큰 교환 방식은 실제 앱 자격증명으로 확인해야 합니다. 제공자 설정이 지원하지 않으면 Naver 버튼은 열지 말고 별도 인증 어댑터를 검토합니다.
   로그인 검증이 끝나면 Vercel 환경변수 `NAVER_OAUTH_ENABLED=true`를 설정하고 다시 배포합니다. 그전에는 Naver 버튼이 비활성화됩니다. Google 버튼은 Supabase의 제공자 활성화 상태를 자동으로 따릅니다.
5. 위원장으로 사용할 계정이 한 번 로그인한 후 Supabase SQL Editor에서 해당 이메일을 확인하고 아래처럼 최초 역할을 부여합니다. 이 역할은 웹에서 셀프 부여할 수 없습니다.

```sql
insert into public.staff_roles (user_id, role)
select id, 'chair' from auth.users where email = 'chair@example.edu'
on conflict (user_id) do update set role = excluded.role;
```

6. 개인정보 보존기간·공고 일정·기관 승인 후 위원장 작업 공간의 **단계 운영**에서 원고 접수를 엽니다. 마감 시각은 한국시간으로 입력하며, 비워 두면 시간 제한이 없습니다. 심사위원은 먼저 로그인한 계정 이메일로 배정하고 원고당 2명을 권장합니다. 배정 전 저자·소속·과제 이해관계를 확인한 뒤 심사 입력 단계를 엽니다.
7. 판정은 저장 즉시 저자의 작업 공간에 표시되며 자동 이메일은 발송하지 않습니다. 채택 후 최종본 제출 단계를 열면 저자가 같은 원고에서 최종 PDF를 올릴 수 있습니다. 최종본은 저자와 위원장만 열람합니다. 자료집·웹 공개는 별도 승인 후 진행합니다.

## 참가·프로그램 운영

`supabase/migrations/20260927010351_conference_operations.sql`을 적용한 뒤 위원장은 `operations.html`에서 일반 참가 신청을 열고, 신청을 확인·확정하고, 현장 체크인을 기록합니다. 회원은 `registration.html`에서 기존 계정으로 로그인하고 참가 날짜를 선택합니다. 이름과 소속은 기존 `profiles` 정보를 사용합니다. 취소 후 접수 기간 안에는 다시 신청할 수 있습니다. 발표자 등록은 아직 별도 안내 대상이며 이 일반 참가 양식에 포함되지 않습니다.

연사와 세션은 기본적으로 비공개입니다. 위원장이 사용 동의와 일정·장소를 확인하고 각각 공개로 바꾸면 `program.html`에 표시됩니다. 홈페이지의 1박 2일 시간표는 계속 운영 가안으로 표시됩니다. 결제, 자동 확인 메일, 출석증명서 발급은 확정된 운영 정책이 없으므로 구현하지 않았습니다.

### 세션 좌장 업무

`supabase/migrations/20260928005708_kics_session_chair.sql` 적용 후 위원장은 `operations.html`의 **세션 좌장·발표 운영**에서 구두·포스터 세션마다 가입된 계정 이메일로 좌장을 지정합니다. 채택 원고의 최종 발표 형태가 세션과 일치할 때만 해당 원고와 실제 발표자를 배정할 수 있습니다. 공개용 좌장 이름은 세션 편집의 별도 입력란에서 승인 후 설정합니다.

배정된 좌장은 `session-chair.html`에서 자기 세션의 발표 제목과 발표자만 보고, 발표 여부·우수발표 후보 추천·진행 메모를 저장합니다. 모든 발표의 출석을 확인한 후 보고서를 제출하며, 제출 뒤 수정은 위원장이 재개해야 합니다. 이 권한은 원고 심사·채택 판정·PDF·일반 참가자 명단 열람을 포함하지 않습니다. 좌장과 저자 계정이 같은 원고인 경우 배정을 막지만, 같은 기관·과제 등 추가 이해관계는 위원장이 직접 확인해야 합니다.

좌장 선정 방식, 일반 참가 등록 연계, 우수발표 시상 기준은 아직 확정되지 않았습니다. 추천 기록은 비공개 운영 자료이며 수상 결정이 아닙니다. KICS 2026 추계학술발표회의 [좌장 업무 안내](https://conf.kics.or.kr/2026f/journalRegister)를 역할 설계 참고로 사용했으며, KICS의 접수일·등록비·저작권 양도 정책은 적용하지 않았습니다.

## 공동위원장 현황 모니터링

`staff_roles.is_super_admin`은 위원장 역할에 추가되는 운영 권한 표식입니다. 송경영의 확인된 `kysong@uc.ac.kr` 및 `song.kyoung.young@gmail.com` 계정에만 마이그레이션 `20260927151538_super_admin_monitor.sql`이 이를 부여합니다. 셀프 승격은 불가능합니다. 두 계정은 투고·심사 화면에서 로그인한 뒤 **현황 모니터링** 메뉴로 `monitor.html`에 이동할 수 있습니다.

현재 회차의 일반 참가신청과 논문을 상태별로 집계하고, 목록을 검색·필터링·새로고침할 수 있습니다. 초안과 취소 신청은 별도 집계합니다. 변경이 필요하면 기존 참가·프로그램 관리 또는 투고·심사 관리 화면에서 진행합니다. 이 모니터링 화면은 원고 PDF를 노출하거나 개인정보를 다운로드하지 않습니다.

관련 설계: [`docs/02-design/features/paper-submission-system.design.md`](../docs/02-design/features/paper-submission-system.design.md). [Google OAuth](https://supabase.com/docs/guides/auth/social-login/auth-google), [사용자 지정 OAuth](https://supabase.com/docs/guides/auth/custom-oauth-providers), [Naver API](https://developers.naver.com/docs/login/api/api.md).
