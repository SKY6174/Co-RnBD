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

현재 사이트는 원고·참가정보를 수집하지 않습니다. 논문 일정, 주최기관, 접수처, 건물·호실은 확정 전이며 사이트에 초안으로 표시됩니다. 데이터 수집 기능은 개인정보·권한·보존기간 설계 후 추가합니다.
