-- A chair's review INSERT checks papers, whose SELECT policy used to read
-- reviews again. Evaluate only the current user's active assignment through a
-- narrow definer function so the two RLS policies cannot recurse.
create function app_private.has_active_review(p_paper_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.reviews r
    where r.paper_id = p_paper_id
      and r.reviewer_id = (select auth.uid())
      and r.review_state <> 'declined'
  );
$$;
revoke all on function app_private.has_active_review(uuid) from public;
grant execute on function app_private.has_active_review(uuid) to authenticated;

drop policy papers_read on public.papers;
create policy papers_read on public.papers for select to authenticated using (
  owner_id = (select auth.uid())
  or (select app_private.is_chair())
  or app_private.has_active_review(id)
);
