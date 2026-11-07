-- A declared review conflict also excludes a dual-role associate editor.
-- Preserve the declaration across manuscript revisions and assignment replacements.
create or replace function app_private.is_paper_editor(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists (
    select 1 from public.papers p where p.id=p_id and p.status<>'draft' and p.submitted_at is not null
    and app_private.is_associate_editor(p.edition_year,p.track) and p.owner_id<>auth.uid()
    and not exists(select 1 from public.reviews r where r.paper_id=p.id
      and r.reviewer_id=auth.uid() and r.review_state='declined')
    and not exists(select 1 from public.paper_authors a join auth.users u on u.id=auth.uid()
      where a.paper_id=p.id and lower(btrim(a.email))=lower(u.email)));
$$;
revoke all on function app_private.is_paper_editor(uuid) from public,anon;
grant execute on function app_private.is_paper_editor(uuid) to authenticated;
