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

로그인 후 실제 저장 흐름은 별도 일회성 로컬 Supabase에서 검사합니다. 운영 `.env`나 원격 링크를
복사하지 않고, 합성 계정 5개와 합성 원고·PDF·신청·납부 내역만 생성합니다. Docker와 CLI 3.0.0이 필요합니다.
출력 폴더는 새 경로를 사용하고 Git에 올리지 않습니다. 다음 명령은 저장소 루트 기준입니다.

```sh
npm --prefix site ci
npm --prefix site run build
python3 scripts/prepare-lifecycle-env.py --output /tmp/co-rnbd-e2e-my-run
uv run --with playwright playwright install chromium
uv run --with playwright --with pymupdf --with pypdf python scripts/verify-authenticated-lifecycle.py --environment /tmp/co-rnbd-e2e-my-run
```

실제 Auth·RLS·Storage와 브라우저에서 프로필, 초안/PDF, 투고, 2인 심사, 수정·재투고·최종본 확인,
참가 신청·확정·체크인, 발급기관·납부 저장, 문서 3종 발급·인쇄·취소를 검사합니다.
결과는 출력 폴더의 `results.json`과 화면·합성 PDF에서 확인합니다. `.env.local-status.json`은 테스트용
관리자 키가 포함된 비공개 파일이므로 공유하지 않습니다. 종료 시 준비 스크립트가 출력한 해당
workdir의 `stop` 명령으로 **이번 테스트 프로젝트만** 중지합니다. `stop --all`은 사용하지 않습니다.
메일은 로컬 메일함만 사용하며 Google/Naver 실제 OAuth와 외부 결제·메일 발송은 포함하지 않습니다.

전체 페이지 읽기 전용 호환성 검사(Python Playwright, Chromium·WebKit): 저장소 루트에서 실행합니다.
페이지 목록은 `site/lib/pages.ts`에서 읽으며 1440px·390px, 기존 HTML/clean URL, API·공개 DB 조회,
익명 접근 차단, 자산 일치, 메뉴·탭 키보드 동작을 검사합니다. 운영 계정으로 로그인하거나 신청·원고·메일을 생성하지 않습니다.
이 검사는 인증 후 투고·심사·등록·문서 발급의 쓰기 생명주기를 대신하지 않습니다.

```sh
uv run --with playwright playwright install chromium webkit
uv run --with playwright python scripts/verify-site-compatibility.py --base https://co-rnbd.org --output /tmp/co-rnbd-compatibility
```

- 행사명·목적·발표 분야·1박 2일 프로그램·CFP 요약·참가 안내
- 국·영문 CFP 전문과 확정/가안 일정의 구분
- 모바일 메뉴와 날짜별 프로그램 탭
- 확정 개최일·동부캠퍼스·일반 참가신청 마감과 미확정 투고 일정·접수처 구분 표시
- Supabase 기반 일반 참가 신청(계정당 1건), 위원장 확인·체크인, 초안/공개 연사·세션 관리. 현재 참가신청은 시범 운영으로 열려 있으며 등록비·결제 기능은 없습니다.

## 공개 전 연결할 항목

1. 동부캠퍼스 건물·호실, 공동주최·주관·로고, 연사, 등록비 승인
2. 기관 발급 행사 URL과 공식 사무국 이메일
3. 운영 승인 후 참가 신청 단계 열기와 발표자 별도 등록 절차 확정
4. 개인정보 안내, 환불 기준, 숙박·셔틀·자료집 공개 범위
5. 실제 원고 제출·등록·체크인 흐름의 권한별 검수

2026 회차 원고 접수·일반 참가신청·심사 입력은 시범 운영으로 열어 두며, 최종본 접수는 별도로 닫혀 있습니다. 심사 입력은 2026-11-07 운영자 요청으로 개방합니다. 원고와 신청 정보는 운영 DB에 저장됩니다. 위원장은 `operations.html`에서 두 접수 상태와 마감, 투고 안내문을 관리하고, `chair.html`에서 원고 배정·판정을 수행합니다. 개최일은 2027년 1월 20–21일, 장소는 울산과학대학교 동부캠퍼스, 일반 참가신청 마감은 2027년 1월 5일 18:00 KST입니다. 발표자는 채택 후 별도 등록하며 논문 일정과 프로그램은 가안입니다.

## 투고 시스템 운영 설정

Google OAuth 앱에 입력할 공개 문서: [개인정보처리방침](https://co-rnbd.org/privacy.html), [서비스 이용약관](https://co-rnbd.org/terms.html). 홈페이지와 투고 화면의 푸터에서도 연결됩니다. 개인정보처리자·문의처·보유기간은 운영자가 확인한 값으로 기재했습니다. 계정·투고·심사·참가 신청 자료는 학회 종료일인 2027년 1월 21일까지 보유하므로, 종료 후 Supabase Auth·데이터베이스·Storage 및 백업의 파기 절차를 실제 운영 계획에 반영해야 합니다. 등록비 납부·환불 확인 기록과 발급한 영수증·거래명세서는 국세기본법 제85조의3에 따라 5년간 분리 보관한다고 공지했습니다. 현재 `registration_billing`·`registration_documents`는 참가 신청을 `on delete` 규칙 없이 참조하므로, 파기 전에 증빙 스냅샷을 보존하면서 나머지 개인정보를 지우는 절차를 먼저 마련해야 합니다. 방침의 국외 이전 표는 Vercel(미국 등)과 Resend(미국)를 기재하며, Supabase 데이터는 서울 리전(ap-northeast-2)입니다. 처리 업체나 리전이 바뀌면 방침도 함께 수정합니다.

1. Vercel 프로젝트의 Root Directory를 `site/`, Framework Preset을 `Next.js`로 설정하고 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`를 설정합니다. 이 두 값만 `/api/config`에서 공개합니다. 서비스 역할 키는 웹·Vercel 공개 환경변수에 넣지 않습니다.
2. Supabase Auth의 Site URL을 `https://co-rnbd.org`로, 허용 Redirect URL에 `https://co-rnbd.org/submission.html`을 등록합니다. 이메일 제공자와 이메일 확인을 활성화하고, 본운영 전 전용 SMTP를 연결합니다. 이메일·비밀번호 가입, 로그인, 비밀번호 재설정 메일이 이 설정을 사용합니다. 기본 Supabase 발송 서비스는 테스트 용량이 제한됩니다.
   인증 메일 4종의 제목과 HTML은 `supabase/config.toml` 및 `supabase/templates/`에 버전 관리하며, 운영 프로젝트의 Authentication → Emails에도 적용했습니다. `supabase/config.toml`에는 로컬 개발용 값(`auth.email.enable_confirmations = false` 등)이 포함되어 있습니다. CLI는 루트 [버전 기준과 실행 안내](../README.md#supabase-cli-3)를 따릅니다. 운영 설정을 변경하기 전에는 `sh scripts/supabase.sh config diff --remote=lvtdnrmwunahgwutafhv`로 전체 설정을 비교해야 합니다(저장소 루트에서 실행).
3. Google Cloud OAuth 웹 앱을 만들고 Google 제공자 화면에 표시된 Supabase callback URL을 Google의 승인된 리다이렉트 URI에 등록합니다. Client ID/Secret은 Supabase Auth Providers의 Google 설정에만 입력합니다.
4. Naver 개발자 앱에 Supabase 사용자 지정 provider의 callback URL을 등록합니다. Supabase Auth의 Custom OAuth Provider를 `custom:naver`로 만들고 Authorization URL `https://nid.naver.com/oauth2.0/authorize`, Token URL `https://nid.naver.com/oauth2.0/token`, UserInfo URL `https://co-rnbd.org/api/naver-userinfo`를 사용합니다. Naver 프로필의 중첩된 `response` 객체를 Next.js Route Handler가 표준 `sub`/`email`/`name`으로 변환합니다. Naver의 PKCE 지원 여부 및 토큰 교환 방식은 실제 앱 자격증명으로 확인해야 합니다. 제공자 설정이 지원하지 않으면 Naver 버튼은 열지 말고 별도 인증 어댑터를 검토합니다.
   로그인 검증이 끝나면 Vercel 환경변수 `NAVER_OAUTH_ENABLED=true`를 설정하고 다시 배포합니다. 그전에는 Naver 버튼이 비활성화됩니다. Google 버튼은 Supabase의 제공자 활성화 상태를 자동으로 따릅니다.
5. 위원장으로 사용할 계정이 한 번 로그인한 후 Supabase SQL Editor에서 해당 이메일을 확인하고 아래처럼 최초 역할을 부여합니다. 이 역할은 웹에서 셀프 부여할 수 없습니다.

```sql
insert into public.staff_roles (user_id, role)
select id, 'chair' from auth.users where email = 'chair@example.edu'
on conflict (user_id) do update set role = excluded.role;
```

6. 위원장 계정으로 로그인한 뒤 **학회 운영 관리**의 **논문투고·심사 관리**에서 원고 접수, 심사, 최종본 단계와 공개 안내문을 설정합니다. 마감 시각은 한국시간으로 입력하며, 비워 두면 시간 제한이 없습니다. 심사위원은 `chair.html`에서 먼저 로그인한 계정 이메일로 배정하고 원고당 2명을 필수 배정합니다. 배정 전 저자·소속·과제 이해관계를 확인한 뒤 심사 입력 단계를 엽니다.
7. 판정은 저장 즉시 저자의 작업 공간에 표시되며 인증된 투고 계정 이메일에도 안내합니다. 채택 후 최종본 제출 단계를 열면 저자가 같은 원고에서 최종 PDF를 올릴 수 있습니다. 최종본은 저자와 위원장만 열람합니다. 자료집·웹 공개는 별도 승인 후 진행합니다.

## 참가·프로그램 운영

`supabase/migrations/20260927010351_conference_operations.sql`을 적용한 뒤 위원장은 `operations.html`에서 일반 참가 신청을 열고, 신청을 확인·확정하고, 현장 체크인을 기록합니다. 회원은 `registration.html`에서 기존 계정으로 로그인하고 참가 날짜를 선택합니다. 이름과 소속은 기존 `profiles` 정보를 사용합니다. 취소 후 접수 기간 안에는 다시 신청할 수 있습니다. 발표자 등록은 아직 별도 안내 대상이며 이 일반 참가 양식에 포함되지 않습니다.

연사와 세션은 기본적으로 비공개입니다. 위원장이 사용 동의와 일정·장소를 확인하고 각각 공개로 바꾸면 `program.html`에 표시됩니다. 홈페이지의 1박 2일 시간표는 계속 운영 가안으로 표시됩니다. 결제, 자동 확인 메일, 출석증명서 발급은 확정된 운영 정책이 없으므로 구현하지 않았습니다.

### 세션 좌장 업무

`supabase/migrations/20260928005708_kics_session_chair.sql` 적용 후 위원장은 `operations.html`의 **세션 좌장·발표 운영**에서 구두·포스터 세션마다 가입된 계정 이메일로 좌장을 지정합니다. 채택 원고의 최종 발표 형태가 세션과 일치할 때만 해당 원고와 실제 발표자를 배정할 수 있습니다. 공개용 좌장 이름은 세션 편집의 별도 입력란에서 승인 후 설정합니다.

배정된 좌장은 `session-chair.html`에서 자기 세션의 발표 제목과 발표자만 보고, 발표 여부·우수발표 후보 추천·진행 메모를 저장합니다. 모든 발표의 출석을 확인한 후 보고서를 제출하며, 제출 뒤 수정은 위원장이 재개해야 합니다. 이 권한은 원고 심사·채택 판정·PDF·일반 참가자 명단 열람을 포함하지 않습니다. 좌장과 저자 계정이 같은 원고인 경우 배정을 막지만, 같은 기관·과제 등 추가 이해관계는 위원장이 직접 확인해야 합니다.

좌장 선정 방식, 일반 참가 등록 연계, 우수발표 시상 기준은 아직 확정되지 않았습니다. 추천 기록은 비공개 운영 자료이며 수상 결정이 아닙니다. KICS 2026 추계학술발표회의 [좌장 업무 안내](https://conf.kics.or.kr/2026f/journalRegister)를 역할 설계 참고로 사용했으며, KICS의 접수일·등록비·저작권 양도 정책은 적용하지 않았습니다.

## 공동위원장 현황 모니터링

`staff_roles.is_super_admin`은 위원장 역할에 추가되는 운영 권한 표식입니다. 송경영의 확인된 `kysong@uc.ac.kr` 및 `song.kyoung.young@gmail.com` 계정에만 마이그레이션 `20260927151538_super_admin_monitor.sql`이 이를 부여합니다. 셀프 승격은 불가능합니다. 두 계정은 투고·심사 화면에서 로그인한 뒤 **현황 모니터링** 메뉴로 `monitor.html`에 이동할 수 있습니다.

현재 회차의 일반 참가신청과 논문을 상태별로 집계하고, 목록을 검색·필터링·새로고침할 수 있습니다. 초안과 취소 신청은 별도 집계합니다. 단계·참가 설정은 학회 운영 관리에서, 원고 배정·판정은 전용 원고 심사 관리 화면에서 진행합니다. 이 모니터링 화면은 원고 PDF를 노출하거나 개인정보를 다운로드하지 않습니다.

관련 설계: [`docs/02-design/features/paper-submission-system.design.md`](../docs/02-design/features/paper-submission-system.design.md). [Google OAuth](https://supabase.com/docs/guides/auth/social-login/auth-google), [사용자 지정 OAuth](https://supabase.com/docs/guides/auth/custom-oauth-providers), [Naver API](https://developers.naver.com/docs/login/api/api.md).

## 위원장 원고 심사 관리

`/chair.html`은 심사위원장의 전체 접수·배정·판정·최종본 확인과 분야별 편집위원장(AE)의 담당 원고 검토·판정 화면입니다. 로그인 후 돌아오며, 기존 `/submission.html#chair`도 이 화면으로 이동합니다. 초안은 목록에서 제외합니다. 같은 제출본에 유효한 심사위원 2명이 필수이며, 수정본은 새 심사 배정을 만들어 과거 의견을 보존합니다. 교체 시 이전 배정의 접근 권한을 회수하고 사유를 기록합니다.

판정 공개는 저자 포털에 즉시 반영되며 인증된 투고 계정 이메일에도 안내합니다. 2명 미만 배정 상태에서는 판정할 수 없습니다. 심사위원장이 2명 배정 후 심사 미완료 상태에서 예외 판정을 할 때는 저자에게도 공개할 사유가 필요합니다. AE는 2건의 심사가 모두 완료되어야 판정할 수 있습니다. `paper_events`는 DB에서 기록하는 위원장 전용 이력이고, `paper_final_checks`는 확인한 최종 PDF 버전을 기록합니다. 새 최종본 업로드 시 최신 버전은 다시 확인해야 합니다.

## 마이페이지와 증빙 자동 발급

`/mypage.html`에서 회차별 본인 참가 내역과 참가확인증·영수증·거래명세서를 확인하고 인쇄/PDF 저장할 수 있습니다. 위원장은 `/document-admin.html`에서 발급기관 정보를 입력하고 자동 발급을 켠 뒤, 참가자별 등록비와 외부에서 확인한 납부 내역을 저장합니다. 등록비 면제는 0원으로 지정합니다. 온라인 결제/환불은 실행되지 않습니다.

참가 확정이 기본 조건이며 참가확인증은 체크인, 영수증은 양수 금액의 실제 납부 확인이 추가로 필요합니다. 거래명세서는 납부 증명이 아닙니다. 발급 당시 정보를 DB가 생성·고정하며 사용자 입력으로 금액/기관/이름을 위조할 수 없습니다. 납부 내역 변경 시 기존 금융 증빙은 취소되며 새 발급번호로 재발급할 수 있습니다. 이미 내려받거나 인쇄한 사본은 회수할 수 없습니다.

운영 DB에는 기관·등록비·납부 예시를 넣지 않습니다. 실운영자는 확인된 기관 정보와 실제 납부 자료를 입력해야 합니다. 일반 개인정보 보유기간(현재 공지: 2027-01-21)은 연장하지 않았고, 납부·증빙 기록만 5년 분리 보관을 공지했습니다. 행사 후 참가자가 증빙을 다시 내려받는 기능을 운영하려면 그전에 보유기간과 안내를 확정해야 합니다.


### 행사 후 참가 신청 파기와 증빙 5년 분리 보관

`20261115090000_financial_record_retention.sql`은 개인정보처리방침 4항의 파기 절차를 DB에 구현합니다.
행사가 끝난 회차의 참가 신청·납부·증빙 행을 지우되, 실제 납부·환불 확인 기록과 발급한 영수증·거래명세서
(취소분 포함, 발급 당시 스냅샷)는 계정과 연결되지 않은 `app_private.financial_record_archive`에 옮겨 보관합니다.
참가확인증, 면제·미납 납부 행, 참가 날짜·체크인·참가 구분은 보관하지 않습니다. 앱 역할(anon/authenticated)과
service_role은 보관 테이블과 함수에 접근할 수 없으며, 관리자(SQL Editor 또는 CLI의 postgres)만 실행합니다.

1. 행사 종료일 다음 날 이후, 영수증 재발급·환불 처리가 끝났는지 위원장에게 확인합니다.
2. 미리보기로 대상 건수와 최소 보관 종료일을 확인합니다. 아무것도 바꾸지 않습니다.

   ```sql
   select app_private.preview_registration_purge(2026);
   ```

3. 보관 종료일을 정합니다. 기준은 국세기본법 제85조의3의 "법정신고기한이 지난 날부터 5년"이며, 법정신고기한은
   산학협력단의 회계연도·신고 세목에 따라 달라지므로 회계 담당 부서에 확인한 날짜를 사용합니다. 함수는 마지막
   납부·발급·취소일로부터 5년보다 짧은 날짜를 거부합니다.
4. 확인 문구와 함께 실행합니다. 보관 복사 → 누락 검증 → 증빙·납부·신청 삭제가 한 트랜잭션으로 처리되고, 중간에
   실패하면 아무것도 바뀌지 않습니다. 다시 실행해도 이미 보관된 기록과 보관 종료일은 바뀌지 않습니다.

   ```sql
   select app_private.archive_and_purge_registrations(2026, date '<회계 담당 확인 날짜>', 'PURGE REGISTRATIONS 2026');
   ```

5. 결과 JSON의 보관·삭제 건수가 미리보기와 같은지 확인하고 실행 일시와 건수를 운영 기록에 남깁니다. 개인정보는 남기지 않습니다.

보관 종료일이 지난 기록은 pg_cron 작업 `co-rnbd-financial-retention`이 매일 03:30(KST)에 삭제합니다
(`app_private.purge_expired_financial_records()`). 세무 조사 등으로 열람이 필요하면 관리자가 SQL Editor에서 조회합니다.

이 절차는 참가 신청 데이터만 다룹니다. 계정·프로필, 원고·심사 기록, Storage의 PDF, 이메일 발송 기록,
Supabase 백업의 파기는 별도 절차가 필요합니다. 이 절차를 마친 뒤에는 회원 프로필을 지워도 납부·증빙
외래키 때문에 실패하지 않습니다. 격리 검증(롤백 전용, 합성 `@example.test` 계정만 사용):

```sh
docker exec -i <로컬 일회성 DB 컨테이너> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-financial-retention.sql
```

## 분야별 편집위원장(AE) 심사

`20261107133453_field_editor_review.sql`은 회차·분야별 심사위원/AE 명부와 담당 분야 판정 권한을 추가합니다.
심사위원장은 `/chair.html`의 **분야별 심사위원·편집위원장 구성**에서 가입 이메일과 표시 이름을 등록하고
역할을 비활성화할 수 있습니다. 명부가 구성된 분야는 활성 심사위원만 새로 배정됩니다. 비활성화해도 기존
심사 배정은 보존되므로 배정 철회는 원고에서 별도로 수행합니다. 미가입·미인증 이메일은 계정 연결 대기로
표시되며 가입·인증 후 등록을 갱신합니다. 명부의 이름은 회원 개인 프로필을 바꾸지 않습니다.

AE는 투고 화면의 **원고 심사·편집위원장 업무**로 들어갑니다. 담당 분야의 접수된 원고와 심사를 검토하고,
현재 제출본의 두 심사가 모두 제출된 뒤 Accept/수정 후 채택 검토/Reject를 저자 포털에 공개합니다.
수정 후 채택 검토는 수정본 요청이며 저자가 다시 제출하면 새 심사 배정과 판정이 필요합니다. AE는 자기
저자·공동저자 원고 또는 본인이 이해관계로 심사를 거절한 원고를 판정할 수 없으며 운영 설정·심사 배정·최종본 확인 권한을 갖지 않습니다. 같은 계정을
심사위원과 AE에 함께 등록할 수 있습니다. 배정 요청과 판정·수정 요청은 인증된 수신 계정으로 자동 발송하며 상세 내용은 로그인 포털에서
확인합니다. 저자는 공개 판정과 함께 현재 제출본의 익명화된 추천·심사의견을 볼 수 있습니다.

격리된 로컬 환경에서 실제 이메일 로그인·PDF 투고·2인 심사·두 분야 AE·수정/재심/채택/반려 및 접근 차단:

```sh
npm --prefix site ci
npm --prefix site run build
python3 scripts/prepare-lifecycle-env.py --output /tmp/co-rnbd-editorial-new-run
uv run --with playwright --with pymupdf python scripts/verify-field-editor-review.py --environment /tmp/co-rnbd-editorial-new-run
```

운영 `.env`는 사용하지 않습니다. 합성 계정과 원고는 로컬에만 생성되며 `editorial-results.json`과 화면 PNG가
출력됩니다. 로컬 환경 종료는 준비 스크립트가 출력한 해당 프로젝트의 `stop` 명령을 사용합니다.


## 심사 이메일 자동 알림

`20261107142850_review_email_notifications.sql`은 배정·판정 트랜잭션에 비공개 outbox를 기록합니다.
발송은 pg_net → 운영 Vercel `/api/review-notifications` → Resend로 진행하며 pg_cron이 매분 응답을
회수하고 최대 8회 재시도합니다. 이벤트·provider 중복 방지 키를 고정하고 최초 시도 23시간 이후에는
불명확한 요청을 자동 재전송하지 않습니다. 철회/거절/새 제출본/새 판정/수신 주소 변경으로 오래된
대기 요청은 취소합니다. 이미 서비스가 접수한 메일은 회수할 수 없습니다.

배정·판정 수신자는 심사 배정 계정 또는 원고 소유자의 **인증된 로그인 이메일**입니다. 임의 연락 이메일이나
공동저자 전체에 보내지 않습니다. PDF·서명 URL·심사위원 신원은 보내지 않습니다. 위원장과 유효한
담당 AE만 원고 상세의 **이메일 알림 처리 상태**를 볼 수 있습니다. ‘발송 서비스 접수 완료’는 수신함
도착 확인이 아닙니다. 실패·불확실 상태는 운영자가 provider 기록을 확인한 뒤 처리해야 합니다.

초기 migration은 발송 비활성입니다. 다음 순서로 연결합니다.

1. Resend에서 `co-rnbd.org` 발신 도메인을 인증하고 해당 도메인 발송 전용 API key를 준비합니다.
   기존 Supabase Auth의 `auth.co-rnbd.org` SMTP key는 교체하지 않습니다.
2. Vercel `co-rnbd` 프로젝트의 **production 서버 환경변수**로 `RESEND_API_KEY`와
   최소 32자 무작위 `REVIEW_MAIL_WEBHOOK_SECRET`을 저장하고 재배포합니다. Preview에는 넣지 않습니다.
3. 같은 hook 비밀을 Supabase Vault의 `review_email_webhook_token`으로 저장합니다. SQL Editor의
   secret 입력 또는 인증된 운영 도구를 사용하며 값은 저장소·문서·로그에 기록하지 않습니다.
4. production의 무인증 POST가 401인지, 두 비밀이 일치하는지 확인한 뒤 관리자 권한으로
   `update app_private.review_email_config set enabled=true where id;`를 실행합니다.
5. 지정된 테스트 계정에만 `is_test=true`인 명시적 연결 확인 메일을 보내고 provider 상태를 확인합니다.
   실제 논문 배정/판정은 기존 RPC를 사용합니다. 과거 이벤트를 일괄 재생하지 않습니다.

중지/롤백은 `update app_private.review_email_config set enabled=false where id;` 후 이전 production
배포를 복원합니다. 응답 회수는 계속 진행되며 대기열과 발송 기록을 삭제하지 않습니다. Auth SMTP,
논문·심사·운영 단계는 바꾸지 않습니다. 학회 종료 후 개인정보 파기 범위에 outbox와 provider 기록도
포함해야 합니다. private config/worker/outbox는 일반 사용자에게 공개하지 않습니다.

격리 검증은 위 준비 명령 후 아래를 실행합니다. localhost 수집기 외 provider는 허용하지 않습니다.

```sh
uv run --with playwright --with pymupdf python scripts/verify-review-email.py --environment /tmp/co-rnbd-email-new-run
```


## 심사의견 제출 → AE·심사위원장 알림

`20261107150629_review_submitted_notifications.sql`은 실제 최초 제출 및 제출 후 의견·추천 변경 시
담당 분야의 유효한 AE와 알림 수신으로 지정한 심사위원장에게 개별 통보합니다. 임시저장과 같은 내용
재저장은 제외하며 겸임 계정은 같은 이벤트에 한 통만 받습니다. 심사 본문·추천·심사위원 신원은 메일에
넣지 않으며 `/chair.html`에서 확인합니다. 현재 회차·분야·인증·AE 이해관계와 발송 직전 권한을 검사합니다.

새 알림은 기본 비활성입니다. migration → v2 메일을 지원하는 production 배포 후 관리자 권한으로
`app_private.review_email_config.review_submitted_chair_ids`에 실제 chair 권한 계정의 UUID 목록을 넣고
`review_submitted_enabled=true`로 켭니다. 심사위원장 권한이 있다는 이유만으로 모든 계정에 발송하지 않습니다.
수신 계정을 바꾸면 해당 목록과 staff_roles를 함께 확인합니다. 기존 enabled 설정과 키를 재사용합니다.

새 알림만 중지/롤백하려면 `review_submitted_enabled=false`로 바꾼 뒤 이전 배포를 복원합니다.
새 kind 대기 요청은 보존·정지되며 기존 배정·판정 큐는 계속 처리합니다. 이미 접수한 메일은 회수할 수 없습니다.


## 신규 투고·수정본 재제출 → AE·심사위원장 알림

`20261107153715_paper_submitted_notifications.sql`은 정상 완료된 신규 투고와 수정본 재제출을 구분해
담당 AE와 지정 심사위원장에게 알립니다. 초안·임시저장·실패한 제출은 제외하고 같은 제출본의 감사
이벤트를 다시 기록해도 수신자별 한 통만 생성합니다. PDF·초록·저자 목록은 이메일로 보내지 않습니다.

기존 편집 담당자 선택기와 `review_submitted_chair_ids` 수신 설정을 공유합니다. 같은 종류의 현재
회차·분야·인증·이해관계·역할 회수 검사를 적용하며 발송 전 제출본 시각을 다시 확인합니다.
이전 제출본과 권한이 회수된 수신자는 대기 메일을 취소합니다. 기존 키·SMTP·hook을 재사용합니다.

기본 `paper_submitted_enabled=false`입니다. migration → v3 지원 production 배포 → 기존 위원장 수신자
확인 후 이 flag만 true로 켭니다. 중지/롤백은 이 flag를 false로 한 뒤 이전 배포를 복원합니다.
새 두 kind 대기열을 보존하며 기존 배정·판정·심사의견 제출 알림은 계속 처리합니다.


## 투고자 접수 확인 메일

`20261107160147_author_receipt_notifications.sql`은 신규 투고·수정본 재제출이 완료되면 원고 소유자의
인증된 로그인 이메일로 각각 접수 확인을 보냅니다. 연락 이메일·공동저자 전체에 보내지 않습니다.
제목·접수번호·분야·해당 접수 시각(KST)·내 원고 링크를 안내하며 PDF·초록·심사 결과를 넣지 않습니다.

과거의 정상 제출 이벤트를 대조하므로 이후 판정·재제출이 있어도 해당 제출본의 접수 확인은 유효합니다.
소유권/인증 주소 변경이나 제출 증거 삭제·불일치는 취소합니다. 같은 제출본 이벤트 replay는 한 통으로
합칩니다. 초안·임시저장·실패한 제출은 접수 확인 대상이 아닙니다. 새 trigger는 enqueue만 합니다.

기본 `author_receipt_enabled=false`이며 migration → v4 서버 배포 후 true로 켭니다. 기존 편집자 알림과
독립적이고 기존 dispatcher/cron이 처리합니다. 중지/롤백은 새 flag=false와 이전 배포 복원으로 진행하며
큐/접수 기록을 보존합니다. 키·SMTP·운영 단계를 재설정하지 않습니다.

## 투고·심사 작업 공간

로그인 작업 공간은 내 원고·수정 요청·남은 심사를 요약하고, 현재 프로필/원고/심사 단계에 맞는 다음 작업을
안내합니다. 내 원고와 심사 배정은 제목·접수번호 검색, 상태 필터와 초기화를 지원합니다. 탭은 좌우 화살표와
Home/End 키로 이동합니다. 필터를 바꿔도 열려 있는 양식의 입력을 지우지 않습니다.

편집 화면은 선택한 분야의 배정/심사/판정/최종본 상태를 집계합니다. 원고의 현재 제출본에 해당하는 유효 심사
2건만 진행률에 반영하며, AE의 배정·최종본 확인 권한을 추가하지 않습니다. 상세 빠른 이동과 이메일 이력
접기를 제공하고, 확인이 필요한 발송 기록이 있으면 이력을 펼칩니다. 자동 발송 규칙/키/DB 권한은 유지합니다.

위 `verify-review-email.py`를 마친 **같은 격리 환경**에서 후속 UI 접근성 검사를 실행합니다.
이 검사는 해당 합성 `example.test` 계정 3개의 비밀번호를 일회성 값으로 바꾸며 운영 계정에는 접근하지 않습니다.
axe-core 4.14.0의 SHA-256을 검사하고 Chromium/WebKit의 WCAG A/AA·반응형·읽기 상태를 검증합니다.

```sh
curl --fail --silent --show-error https://cdn.jsdelivr.net/npm/axe-core@4.14.0/axe.min.js -o /tmp/co-rnbd-axe-4.14.0.min.js
uv run --with playwright python scripts/verify-review-workspace.py --environment /tmp/co-rnbd-email-new-run --axe-script /tmp/co-rnbd-axe-4.14.0.min.js
```

결과는 `accessibility-results.json`과 `polished-*.png`에 기록합니다. 자동 검사 외 실제 보조기술 사용자 검수는
별도이며, 위 검사는 격리 환경의 로그인/투고/심사 생명주기 검증을 대체하지 않습니다.

## 지정 계정 운영 생명주기 검증

AE 겸임 계정의 편집 목록은 활성 담당 분야만 조회하고, 본인 소유·공동저자·이해관계 거절 원고를 제외합니다.
개인 심사 배정은 투고·심사 화면에서 그대로 확인합니다. DB의 판정 권한 검사를 대체하지 않습니다.

`scripts/verify-live-editorial.py`는 운영자가 특정 계정·수신자·테스트 원고로 **명시적으로 요청한 운영 검증**용이며
일반 CI에서 실행하지 않습니다. 비공개 JSON은 `chief`, `reviewer1`, `reviewer2` 이메일을 지정합니다.
기존 관리자 CLI 연결로 해당 인증 계정의 일회성 로그인을 준비하고, 이후 실제 화면에서만 제출·배정·심사·판정합니다.
비밀번호·회원 역할·운영 단계는 변경하지 않습니다. 원고 제목과 PDF에는 E2E TEST가 표시됩니다.

`--allow-production-test` 동의 인자와 Git 작업 폴더 밖의 비공개 출력 경로가 필수입니다. 다음 명령은 실제 원고
1건과 정상 workflow 알림 20건을 생성하므로 격리 검증 대신 일상적으로 실행하지 않습니다.

```sh
uv run --with playwright --with pymupdf --with certifi python scripts/verify-live-editorial.py --accounts /private/path/accounts.json --output /private/path/e2e-run --allow-production-test
```

중단 시 같은 출력 경로/`--phase`로 재개하며 완료 단계를 반복하지 않습니다. 수정 배포 뒤 `--phase audit`는 같은
원고의 AE 범위·판정 거절·두 심사위원의 PDF 두 버전 다운로드·저자 최종 의견을 확인합니다. `--phase close`로
테스트 세션만 만료하고 임시 인증 파일을 제거합니다. 본문/세션/수신 주소가 있는 결과와 PNG는 커밋하지 않으며,
메일은 provider ID와 실제 Delivered 기록을 별도로 대조합니다. 테스트 원고·심사·발송 이력은 보존합니다.
