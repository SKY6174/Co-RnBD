-- [001] 제1회 전문대학 산학공동 Co-R&BD 컨퍼런스 모집 분야 개편 및 세션 편성 필드 추가
-- 1. 모집 분야(track):
--    - master_eng      : 전문기술석사 (공학)
--    - master_sci      : 전문기술석사 (자연과학)
--    - industry_joint  : 산학공동기술개발과제
--    - convergence_etc : 기타 산학융합과제
--    (기존 데이터 호환을 위해 applied, industry, convergence, education 값도 허용 유지)
-- 2. 배정 세션(assigned_session):
--    - oral_1, oral_2, oral_3 : 구두발표 세션 1~3 (최소 20편 이상 모집 목표)
--    - poster_1               : 포스터 세션 1 (최소 30편 이상 모집 목표)

-- 1) papers 테이블의 모집 분야(track) 체크 제약조건 확장
alter table public.papers drop constraint if exists papers_track_check;
alter table public.papers add constraint papers_track_check check (
  track in (
    'master_eng',
    'master_sci',
    'industry_joint',
    'convergence_etc',
    'applied',
    'industry',
    'convergence',
    'education'
  )
);

-- 2) profiles 테이블의 심사위원 전문 분야(expertise_tracks) 체크 제약조건 확장
alter table public.profiles drop constraint if exists profiles_expertise_tracks;
alter table public.profiles add constraint profiles_expertise_tracks check (
  cardinality(expertise_tracks) <= 3
  and expertise_tracks <@ array[
    'master_eng',
    'master_sci',
    'industry_joint',
    'convergence_etc',
    'applied',
    'industry',
    'convergence',
    'education'
  ]::text[]
  and array_position(expertise_tracks, null) is null
);

-- 3) papers 테이블에 위원장이 지정하는 배정 세션(assigned_session) 컬럼 추가
alter table public.papers
  add column if not exists assigned_session text
    check (assigned_session in ('oral_1', 'oral_2', 'oral_3', 'poster_1'));

-- 배정 세션은 최종 발표 형태(final_presentation)와 일치해야 함 (Oral 1~3은 oral, Poster 1은 poster)
alter table public.papers drop constraint if exists papers_session_matches_presentation;
alter table public.papers add constraint papers_session_matches_presentation check (
  assigned_session is null
  or (assigned_session in ('oral_1', 'oral_2', 'oral_3') and final_presentation = 'oral')
  or (assigned_session = 'poster_1' and final_presentation = 'poster')
);

-- 4) 저자가 새 초안을 생성할 때 assigned_session을 임의로 넣지 못하도록 RLS 정책 보강
drop policy if exists papers_insert on public.papers;
create policy papers_insert on public.papers for insert to authenticated with check (
  owner_id = (select auth.uid())
  and status = 'draft'
  and decision_note = ''
  and final_presentation is null
  and assigned_session is null
  and submitted_at is null
  and decided_at is null
  and edition_year = (select app_private.current_edition_year())
  and exists (
    select 1 from public.conference_settings s
    where s.edition_year = papers.edition_year
      and s.submissions_open
      and (s.submission_deadline is null or now() <= s.submission_deadline)
  )
);

-- 5) 일반 저자가 assigned_session 등 위원장 전용 판정 필드를 수정하지 못하도록 트리거 함수 보강
create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.id <> old.id
      or new.created_at is distinct from old.created_at
      or new.owner_id <> old.owner_id
      or new.edition_year <> old.edition_year
      or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.assigned_session is distinct from old.assigned_session
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at)
    then
      raise exception 'Only chairs may change identity or decision fields';
    end if;
    if old.status not in ('draft', 'revision') or new.status not in ('draft', 'submitted')
    then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings s
      where s.edition_year = new.edition_year
        and s.submissions_open
        and (s.submission_deadline is null or now() <= s.submission_deadline)
    ) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_authors where paper_id = new.id)
    then
      raise exception 'At least one author is required';
    end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id and file_stage = 'submission')
    then
      raise exception 'A submission PDF is required';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;
