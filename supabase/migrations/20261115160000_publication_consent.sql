-- Proceedings publication consent for accepted papers.
-- The CFP states that only finals with publication consent are included in the proceedings.
-- The submitting author records consent (confirming co-author agreement) or refusal;
-- they can change it while the paper is accepted in the current edition. Chairs read it.
create table public.paper_publication_consents (
  paper_id uuid primary key references public.papers(id) on delete cascade,
  consented boolean not null,
  coauthors_confirmed boolean not null default false,
  decided_by uuid not null references public.profiles(user_id),
  decided_at timestamptz not null default now(),
  check (not consented or coauthors_confirmed)
);
create index paper_publication_consents_decided_by_idx on public.paper_publication_consents (decided_by);
alter table public.paper_publication_consents enable row level security;
revoke all on public.paper_publication_consents from public, anon, authenticated;
grant select, insert, update on public.paper_publication_consents to authenticated;

create policy publication_consents_read on public.paper_publication_consents for select to authenticated using (
  (select app_private.is_chair()) or exists (
    select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid()))
);
create policy publication_consents_insert on public.paper_publication_consents for insert to authenticated with check (
  exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid())
    and p.status = 'accepted' and p.edition_year = (select app_private.current_edition_year()))
);
create policy publication_consents_update on public.paper_publication_consents for update to authenticated
  using (exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid())
    and p.status = 'accepted' and p.edition_year = (select app_private.current_edition_year())))
  with check (exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid())
    and p.status = 'accepted' and p.edition_year = (select app_private.current_edition_year())));

-- Server sets who/when; the paper cannot be switched on update.
create function app_private.stamp_publication_consent() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.paper_id <> old.paper_id then raise exception 'Paper cannot change'; end if;
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  new.decided_by := auth.uid();
  new.decided_at := now();
  return new;
end;
$$;
revoke all on function app_private.stamp_publication_consent() from public, anon, authenticated;
create trigger stamp_publication_consent before insert or update on public.paper_publication_consents
  for each row execute function app_private.stamp_publication_consent();
