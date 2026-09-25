# Co-R&BD Conference 2026

제1회 전문대학 산학공동 R&BD 컨퍼런스의 공개 안내 사이트와 논문·실천사례 모집공고 초안입니다. 행사일은 **2026년 12월 17–18일**, 장소는 **울산과학대학교 동부캠퍼스**입니다. 일반 참가신청 마감은 **2026년 10월 30일(금) 18:00 KST**이며, 발표자는 채택 후 별도 등록합니다.

- 공개 사이트: [`site/`](site/README.md)
- 국·영문 CFP 원문: [`outputs/co-rbd-2026-cfp-draft.md`](outputs/co-rbd-2026-cfp-draft.md)
- 행사 기획·설계: [`docs/`](docs/02-design/features/college-tech-conference-2026.design.md)

## 로컬 미리보기

```sh
python3 -m http.server 8765 --directory site
```

`http://127.0.0.1:8765/`에서 첫 화면을, `/cfp.html`에서 모집공고 전문을 볼 수 있습니다.

## 서비스 연결

| 서비스 | 연결 대상 | 현재 역할 |
|---|---|---|
| GitHub | `SKY6174/Co-RnBD` · `main` | 소스 및 CFP 버전 관리 |
| Vercel | `ucsky6174/co-rnbd` · 루트 `site/` · `co-rnbd.org` | 정적 사이트 배포 |
| Supabase | `Co-RnBD/Co-RnBD-2026` · ref `lvtdnrmwunahgwutafhv` | 프로젝트 연결 및 향후 데이터 기능 준비 |

Vercel에는 `SUPABASE_URL`과 `SUPABASE_PUBLISHABLE_KEY`가 설정되어 있습니다. 로컬 연결은 `supabase link --project-ref lvtdnrmwunahgwutafhv`로 재현할 수 있습니다. 키 값과 `.env.local`은 Git에 올리지 않습니다.

## 논문 투고·심사

[`site/submission.html`](site/submission.html)은 저자·심사위원·위원장 작업 공간입니다. 원고, 공동저자, PDF 버전, 심사 배정과 판정은 Supabase Postgres·비공개 Storage에 저장되며 RLS가 역할별 접근을 제한합니다. 참가등록과 투고는 별개입니다.

DB 마이그레이션은 `supabase/migrations/`에 있고 연결된 `Co-RnBD-2026` 프로젝트에 적용했습니다. 접수 스위치는 기본적으로 **닫힘**입니다. 논문 일정·주최기관·개인정보 보존 기준이 확정되면 위원장 계정에서 접수를 열 수 있습니다. Google/Naver OAuth 제공자 등록과 최초 위원장 지정 방법은 [운영 설정](site/README.md#투고-시스템-운영-설정)에 있습니다.

기존 `python3 -m http.server` 미리보기는 정적 화면만 제공합니다. 투고 기능은 Vercel의 `/api/config`와 `/api/naver-userinfo` 함수가 동작하는 환경에서 확인해야 합니다.
