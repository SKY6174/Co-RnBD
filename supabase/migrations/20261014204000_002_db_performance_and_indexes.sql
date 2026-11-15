-- 002_db_performance_and_indexes.sql
-- 제1회 전문대학 산학공동 Co-R&BD 컨퍼런스 데이터베이스 조회 속도 및 인덱스 최적화

-- 1. 위원장 데스크(loadChairPapers) 및 운영 모니터(monitor.js)의 회차별 최신순 원고 조회 인덱스
create index if not exists papers_edition_created_at_idx
  on public.papers (edition_year, created_at desc);

-- 2. 투고자 워크스페이스(loadMyPapers)의 회차별·저자별 최신순 원고 조회 복합 인덱스
create index if not exists papers_edition_owner_created_at_idx
  on public.papers (edition_year, owner_id, created_at desc);

-- 3. 4개 세션(oral_1, oral_2, oral_3, poster_1) 배정 현황 집계용 부분 인덱스
create index if not exists papers_edition_assigned_session_idx
  on public.papers (edition_year, assigned_session)
  where assigned_session is not null;

-- 4. 원고 PDF 파일 목록 열람 및 최신 버전 계산(version desc) 최적화 인덱스
create index if not exists paper_files_paper_version_idx
  on public.paper_files (paper_id, version desc);

-- 5. 참가 신청 관리(operations.js) 및 모니터(monitor.js)의 회차별 최신순 조회 인덱스
create index if not exists attendee_registrations_edition_created_at_idx
  on public.attendee_registrations (edition_year, created_at desc);

-- 6. 공개 프로그램 페이지(program.js)의 회차별 공개 세션 시간순 조회 인덱스
create index if not exists program_sessions_edition_published_starts_idx
  on public.program_sessions (edition_year, is_published, starts_at);

-- 7. PostgreSQL 쿼리 플래너 통계 갱신 (최적 실행 계획 수립)
analyze public.conference_editions;
analyze public.conference_settings;
analyze public.profiles;
analyze public.staff_roles;
analyze public.papers;
analyze public.paper_authors;
analyze public.paper_files;
analyze public.reviews;
analyze public.attendee_registrations;
analyze public.program_sessions;
analyze public.program_speakers;
analyze public.program_session_speakers;
analyze public.session_chairs;
analyze public.session_presentations;
