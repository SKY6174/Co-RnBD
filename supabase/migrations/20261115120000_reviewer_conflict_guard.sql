-- Extend the existing reviewer conflict check (owner / listed author) so the database,
-- not only chair.js, also refuses
--   * the paper's contact person (matched by the reviewer's account email), and
--   * a reviewer who declined this paper with a conflict declaration on any manuscript
--     version (declarations persist across revisions and replacements).
create or replace function app_private.reject_author_reviewer_assignment() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (
    select 1 from public.papers p
    join public.profiles reviewer on reviewer.user_id = new.reviewer_id
    where p.id = new.paper_id
      and (p.owner_id = new.reviewer_id or exists (
        select 1 from public.paper_authors author
        where author.paper_id = p.id and author.email is not null
          and reviewer.email is not null
          and lower(btrim(author.email)) = lower(btrim(reviewer.email))
      ))
  ) then
    raise exception 'Reviewer is an author of this paper';
  end if;
  if exists (
    select 1 from public.papers p
    join public.profiles reviewer on reviewer.user_id = new.reviewer_id
    where p.id = new.paper_id and reviewer.email is not null and btrim(p.contact_email) <> ''
      and lower(btrim(p.contact_email)) = lower(btrim(reviewer.email))
  ) then
    raise exception 'Reviewer is the contact person of this paper';
  end if;
  if exists (
    select 1 from public.reviews r
    where r.paper_id = new.paper_id and r.reviewer_id = new.reviewer_id and r.review_state = 'declined'
  ) then
    raise exception 'Reviewer declared a conflict for this paper';
  end if;
  return new;
end;
$$;
revoke all on function app_private.reject_author_reviewer_assignment() from public;
