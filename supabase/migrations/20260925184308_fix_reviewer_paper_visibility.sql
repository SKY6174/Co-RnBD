drop policy papers_read on public.papers;
create policy papers_read on public.papers for select to authenticated using (
  owner_id = (select auth.uid()) or app_private.is_chair() or
  exists (select 1 from public.reviews r
    where r.paper_id = public.papers.id
      and r.reviewer_id = (select auth.uid())
      and r.review_state <> 'declined')
);
