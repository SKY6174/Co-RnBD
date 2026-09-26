# CMT 필수 운영 흐름 보강 — Report

> 2026-09-26 · [분석](../03-analysis/cmt-essential-workflows.analysis.md)

CMT 도움말의 Workflow, Account, Chair, Proceeding Editor, Senior Meta Reviewer, Meta Reviewer, Reviewer, External Reviewer, Author 및 FAQ를 검토했다. 전문대학 행사에는 저자·심사위원·위원장 3개 역할만 두고, 원고 제출부터 간단한 심사·판정·채택 후 최종 PDF까지 이어지도록 보강했다.

공개 투고 화면에 단계 상태와 역할별 안내를 추가했다. 위원장은 접수·심사·최종본 단계와 마감 시각을 관리하고, 저자는 채택 후 최종본을 제출한다. DB는 마감, 저자 정보, 심사 배정의 이메일 이해관계, 최종본 권한을 강제한다. 최종본은 기존 비공개 저장소를 사용하며 심사위원에게 노출되지 않는다.

Supabase 마이그레이션 적용과 RLS/트리거 롤백 검증을 마쳤다. 공개 사이트 화면과 Vercel 배포를 확인했다. 운영자는 일정 확정 후 단계와 마감을 설정하면 된다.
