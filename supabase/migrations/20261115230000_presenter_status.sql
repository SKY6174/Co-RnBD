-- Chair view: for each accepted paper, its authors and whether they registered as presenters.
-- Uses the same matching rule as presenter eligibility (owner, or listed author whose verified
-- login email matches). Chair only; returns no data to anyone else.
create function public.chair_presenter_status(p_year integer)
returns table (
  paper_id uuid,
  paper_title text,
  sort_order integer,
  author_name text,
  author_email text,
  has_account boolean,
  registration_id uuid,
  registration_category text,
  registration_status text
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_chair() then
    raise exception 'Only the chair can view presenter status';
  end if;
  return query
  with accepted as (
    select p.id, p.title, p.owner_id from public.papers p
    where p.edition_year = p_year and p.status = 'accepted'
  ), listed as (
    select a.paper_id, a.sort_order, a.full_name, a.email,
      (select u.id from auth.users u
        where u.email_confirmed_at is not null and lower(btrim(u.email)) = lower(btrim(a.email))
        order by u.created_at limit 1) as user_id
    from public.paper_authors a join accepted x on x.id = a.paper_id
  ), people as (
    select l.paper_id, l.sort_order, l.full_name, l.email, l.user_id from listed l
    union all
    -- The submitting account, when it is not already one of the matched author rows.
    select x.id, 0, coalesce(pr.full_name, ''), coalesce(pr.email, ''), x.owner_id
    from accepted x left join public.profiles pr on pr.user_id = x.owner_id
    where not exists (select 1 from listed l where l.paper_id = x.id and l.user_id = x.owner_id)
  )
  select x.id, x.title::text, pe.sort_order::integer, pe.full_name::text, pe.email::text, pe.user_id is not null,
    r.id, r.category::text, r.status::text
  from people pe
  join accepted x on x.id = pe.paper_id
  left join public.attendee_registrations r on r.user_id = pe.user_id and r.edition_year = p_year
  order by x.title, x.id, pe.sort_order;
end;
$$;
revoke all on function public.chair_presenter_status(integer) from public, anon;
grant execute on function public.chair_presenter_status(integer) to authenticated;
