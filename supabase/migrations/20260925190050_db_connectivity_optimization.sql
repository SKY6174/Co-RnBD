-- Preserve the existing author/chair permissions while evaluating the chair role
-- once per statement instead of once per row.
drop policy papers_author_update on public.papers;
drop policy papers_chair_update on public.papers;
create policy papers_update on public.papers for update to authenticated
  using (
    (owner_id = (select auth.uid()) and status in ('draft', 'revision'))
    or (select app_private.is_chair())
  )
  with check (
    (owner_id = (select auth.uid()) and status in ('draft', 'submitted'))
    or (select app_private.is_chair())
  );

alter policy settings_chair on public.conference_settings
  using ((select app_private.is_chair()))
  with check ((select app_private.is_chair()));

alter policy profiles_read on public.profiles
  using (user_id = (select auth.uid()) or (select app_private.is_chair()));

alter policy roles_read on public.staff_roles
  using (user_id = (select auth.uid()) or (select app_private.is_chair()));

alter policy papers_read on public.papers
  using (
    owner_id = (select auth.uid())
    or (select app_private.is_chair())
    or exists (
      select 1 from public.reviews r
      where r.paper_id = public.papers.id
        and r.reviewer_id = (select auth.uid())
        and r.review_state <> 'declined'
    )
  );

alter policy reviews_read on public.reviews
  using (reviewer_id = (select auth.uid()) or (select app_private.is_chair()));

alter policy reviews_assign on public.reviews
  with check (
    (select app_private.is_chair()) and review_state = 'assigned'
    and recommendation is null and comments = '' and not conflict_confirmed
    and submitted_at is null and declined_at is null and decline_reason = ''
    and exists (
      select 1 from public.papers p
      where p.id = paper_id and p.owner_id <> reviewer_id
        and p.status in ('submitted', 'under_review')
    )
  );

-- The leading columns continue to cover FK and RLS lookups; the second columns
-- match the descending order used by the author and reviewer lists.
drop index public.papers_owner_idx;
create index papers_owner_created_at_idx
  on public.papers (owner_id, created_at desc);

drop index public.reviews_reviewer_idx;
create index reviews_reviewer_assigned_at_idx
  on public.reviews (reviewer_id, assigned_at desc);

create index paper_files_uploaded_by_idx on public.paper_files (uploaded_by);

-- This platform event-trigger function has no reason to be callable by API roles.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
