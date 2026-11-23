-- Extend the audited submission list with the final type for accepted papers.
-- PostgreSQL requires recreating the function to change its OUT columns.
drop function public.staff_list_submissions(integer);

create function public.staff_list_submissions(p_year integer)
returns table (paper_no text, title text, track text, paper_type text, preferred_presentation text, status text,
  submitted_at timestamptz, submitter_name text, submitter_affiliation text, submitter_email text, authors text,
  reviewers_assigned integer, reviews_submitted integer, final_presentation text)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app_private.staff_access_role(p_year) is null then raise exception 'Staff list access required'; end if;
  return query
    select upper(left(x.id::text, 8)), x.title, x.track, x.paper_type, x.preferred_presentation, x.status, x.submitted_at,
      p.full_name, p.affiliation, p.email,
      (select string_agg(a.full_name || coalesce(' (' || nullif(btrim(a.affiliation), '') || ')', ''), ', ' order by a.sort_order)
        from public.paper_authors a where a.paper_id = x.id),
      progress.assigned, progress.submitted,
      case when x.status = 'accepted' then x.final_presentation end
    from public.papers x
    left join public.profiles p on p.user_id = x.owner_id
    cross join lateral (
      select count(*)::integer as assigned,
        (count(*) filter (where v.review_state = 'submitted'))::integer as submitted
      from public.reviews v
      where v.paper_id = x.id and v.revoked_at is null
        and v.manuscript_submitted_at = x.submitted_at and v.review_state <> 'declined'
    ) progress
    where x.edition_year = p_year and x.status <> 'draft'
    order by x.submitted_at nulls last, x.created_at, x.id;
  get diagnostics n = row_count;
  perform app_private.log_staff_access(p_year, 'submissions', n);
end; $$;

revoke all on function public.staff_list_submissions(integer) from public, anon, authenticated, service_role;
grant execute on function public.staff_list_submissions(integer) to authenticated;

notify pgrst, 'reload schema';
