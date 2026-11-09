# T-VET Co-R&BD Conference

제1회 전문대학 산학공동 R&BD 컨퍼런스의 공개 안내 사이트와 논문·현장사례 모집공고 초안입니다. 행사일은 **2027년 1월 20–21일**, 장소는 **울산과학대학교 동부캠퍼스**입니다. 일반 참가신청 마감은 **2027년 1월 5일(화) 18:00 KST**이며, 발표자는 채택 후 별도 등록합니다.

## 연도별 운영

2026은 첫 회차입니다. Supabase의 `conference_editions`가 연도별 행사 정보와 상태(준비 중·현재·지난 학회)를 보관합니다. 투고 원고, 참가 신청, 연사, 세션과 운영 설정은 각 회차에 연결됩니다. 위원장은 [운영 화면](https://co-rnbd.org/operations.html)에서 2027 이후 회차를 미리 만들고 날짜·장소를 입력할 수 있습니다. 기존 회차가 끝난 뒤 새 회차를 활성화하면 이전 회차의 접수·심사·등록이 닫힙니다.

공개가 승인된 종료 회차만 [지난 학회](https://co-rnbd.org/archive.html)에 표시됩니다. 이 화면은 공개 행사 정보와 확정 프로그램만 보여 줍니다. 원고 PDF, 심사 내용, 참가자 목록은 아카이브에서 공개하지 않습니다. 새 연도를 실제로 열기 전에는 그해의 모집공고, 개인정보 안내, 운영 일정과 자료집 공개 범위를 별도로 확정해야 합니다.

마이그레이션: `supabase/migrations/20260927014640_annual_conferences.sql`. 2026 운영 데이터는 이 마이그레이션에서 2026 회차로 자동 연결되며, 운영 Supabase DB에 적용했습니다.

- 공개 사이트: [`site/`](site/README.md)
- 국·영문 CFP 원문: [`outputs/co-rbd-2026-cfp-draft.md`](outputs/co-rbd-2026-cfp-draft.md)
- 행사 기획·설계: [`docs/`](docs/02-design/features/college-tech-conference-2026.design.md)

## 로컬 개발

```sh
cd site
npm ci
npm run dev
```

`http://localhost:3000/`에서 첫 화면을, `/cfp.html`에서 모집공고 전문을 볼 수 있습니다. TypeScript 검사는 `npm run typecheck`, 배포 빌드는 `npm run build`입니다. 로컬 Supabase 연결은 루트 `.env.example`을 참고해 `site/.env.local`에 공개 가능 설정만 입력합니다.

## 서비스 연결

| 서비스 | 연결 대상 | 현재 역할 |
|---|---|---|
| GitHub | `SKY6174/Co-RnBD` · `main` | 소스 및 CFP 버전 관리 |
| Vercel | `ucsky6174/co-rnbd` · 루트 `site/` · `co-rnbd.org` | Next.js App Router 배포 |
| Supabase | `SKY6174/Co-R&BD` · ref `lvtdnrmwunahgwutafhv` | Auth·Postgres·비공개 PDF Storage |

Vercel에는 `SUPABASE_URL`과 `SUPABASE_PUBLISHABLE_KEY`가 설정되어 있습니다. Supabase CLI 버전과 원격 명령은 아래 기준을 따릅니다. 키 값과 `.env.local`은 Git에 올리지 않습니다.

## Supabase CLI 3

CLI는 [`.supabase-cli-version`](.supabase-cli-version)의 **3.0.0**으로 통일합니다(2026-11-07 공식 최신 안정판). Homebrew에서는 `brew update && brew upgrade supabase` 후 `supabase --version`을 확인합니다. 정확한 버전이 필요하면 [공식 릴리스](https://github.com/supabase/cli/releases/tag/v3.0.0)의 OS·CPU별 바이너리를 사용합니다. PR CI도 같은 파일에서 버전을 읽어 설치합니다. `latest`나 beta를 별도로 설치하지 않습니다. 업데이트 시 이 파일과 호환성 검증을 함께 검토합니다.

저장소 루트에서 `sh scripts/supabase.sh ...`로 실행합니다. 이 진입점은 버전 불일치를 차단하고 기본 workdir를 이 저장소로 고정합니다. 별도 로컬 테스트 환경은 명시적 `--workdir`로 지정할 수 있습니다.

```sh
sh scripts/supabase.sh --version
python3 scripts/verify-supabase-cli.py
# 로컬 DB가 기본 대상입니다. status는 운영 상태 확인 명령이 아닙니다.
sh scripts/supabase.sh status
# 운영 DB 읽기는 대상을 명시하며 읽기 전용으로 실행합니다.
sh scripts/supabase.sh db query --remote=lvtdnrmwunahgwutafhv --read-only 'select current_database()'
sh scripts/supabase.sh migration list --remote=lvtdnrmwunahgwutafhv
```

CLI 3에서 `db push/pull/dump`, `migration list`, `gen types`, Storage 명령은 **기본적으로 로컬**입니다. 원격은 `--remote=<project-ref>`로 지정합니다. 원격 변경은 대화형 확인이 필요하며 사전 검토·승인된 자동화에서만 `--yes`를 명시합니다. 파이프의 `y`나 `.env`의 `SUPABASE_YES`는 동의로 인정되지 않습니다. 원격 설정은 먼저 `sh scripts/supabase.sh config diff --remote=lvtdnrmwunahgwutafhv`로 비교합니다. 로컬 개발용 `config.toml` 전체를 운영에 push하지 않습니다. 현재 PR 품질 검사는 원격 DB에 배포하지 않습니다.

CLI 버전은 개발 도구의 버전입니다. 브라우저의 `supabase-js` SDK 버전과 별개이며 CLI 변경만으로 운영 DB·Auth·Storage가 업그레이드되지는 않습니다. [공식 CLI 3 이전 안내](https://supabase.com/docs/guides/local-development/cli/migrating-to-v3).

## 논문 투고·심사

[`/submission.html`](https://co-rnbd.org/submission.html)은 저자·심사위원·위원장 작업 공간입니다. 이메일·비밀번호 가입/로그인/재설정과 Google/Naver 로그인 연결을 지원합니다. 원고, 공동저자, PDF 버전, 심사 배정과 판정은 Supabase Postgres·비공개 Storage에 저장되며 RLS가 역할별 접근을 제한합니다. 참가등록과 투고는 별개입니다.

DB 마이그레이션은 `supabase/migrations/`에 있고 연결된 `Co-R&BD` 프로젝트에 적용했습니다. 2026 회차의 원고 접수는 시범 운영으로 열며, 심사·최종본 단계는 별도로 관리합니다. 접수 상태와 안내문은 위원장이 [학회 운영 관리](https://co-rnbd.org/operations.html)에서 조정할 수 있습니다. 시범 원고와 PDF도 운영 DB에 저장되므로 공식 심사 여부는 별도 공지를 확인해야 합니다. Google/Naver OAuth 제공자 등록과 최초 위원장 지정 방법은 [운영 설정](site/README.md#투고-시스템-운영-설정)에 있습니다.

Next.js Route Handler가 `/api/config`와 `/api/naver-userinfo`를 제공합니다. 로컬 공개 설정이 없으면 데이터 화면에는 연결 안내가 표시되며, 실제 투고 흐름은 별도의 안전한 Supabase 환경에서 검증해야 합니다.

공동위원장의 [현황 모니터링](https://co-rnbd.org/monitor.html)은 현재 회차의 일반 참가신청과 논문투고 집계를 한곳에 보여 줍니다. `staff_roles`의 위원장 역할과 슈퍼 관리자 표식으로 접근을 제한합니다. 실제 배포 전에는 이 링크가 아직 제공되지 않을 수 있습니다.
