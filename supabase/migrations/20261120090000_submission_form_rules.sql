-- Submission form rules, simplified for authors and reviewers:
--  * keywords stay optional and may be 1–5 (was 0 or 2–5 on submission);
--  * paper types follow the CFP's four types: the former 'case' is the
--    산학공동기술개발 사례, and 'education' (교육·운영 사례) is added;
--  * a reviewer listed on the active committee roster for the paper's edition
--    no longer has to repeat expertise tracks in their profile to submit a review.

alter table public.papers drop constraint papers_submission_contact;
alter table public.papers add constraint papers_submission_contact check (
  status in ('draft', 'revision')
  or (btrim(contact_name) <> '' and btrim(contact_email) <> '')
);

alter table public.papers drop constraint papers_paper_type_check;
alter table public.papers add constraint papers_paper_type_check
  check (paper_type in ('research', 'case', 'education', 'poster'));
comment on column public.papers.paper_type is
  'research = 응용연구, case = 산학공동기술개발 사례, education = 교육·운영 사례, poster = 진행연구 포스터·데모';

create or replace function app_private.require_reviewer_profile()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.review_state = 'submitted' and not exists (
    select 1 from public.profiles p
    where p.user_id = new.reviewer_id
      and btrim(p.full_name) <> '' and btrim(p.affiliation) <> ''
      and (cardinality(p.expertise_tracks) between 1 and 3
        or exists (
          select 1 from public.review_committee c
          join public.papers x on x.id = new.paper_id and x.edition_year = c.edition_year
          where c.user_id = new.reviewer_id and c.active))
  ) then
    raise exception 'Complete your profile and expertise before submitting a review';
  end if;
  return new;
end;
$$;
