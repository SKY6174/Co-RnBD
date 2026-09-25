create schema if not exists app_private;

create table public.conference_settings (
  id boolean primary key default true check (id),
  submissions_open boolean not null default false,
  notice text not null default '투고 접수 일정은 확정 후 안내합니다.'
);
insert into public.conference_settings (id) values (true);

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text not null default '',
  affiliation text not null default '',
  created_at timestamptz not null default now()
);
create unique index profiles_email_idx on public.profiles (lower(email)) where email is not null;

create table public.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role = 'chair')
);

create function app_private.is_chair() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff_roles where user_id = (select auth.uid()) and role = 'chair');
$$;
revoke all on function app_private.is_chair() from public;
grant usage on schema app_private to authenticated;
grant execute on function app_private.is_chair() to authenticated;

create function app_private.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function app_private.create_profile();
insert into public.profiles (user_id, email, full_name)
select id, email, coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', '')
from auth.users on conflict (user_id) do nothing;

create function app_private.guard_profile_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.user_id <> old.user_id or new.email is distinct from old.email then
    raise exception 'Identity fields cannot be changed';
  end if;
  return new;
end;
$$;
create trigger guard_profile_update before update on public.profiles
for each row execute function app_private.guard_profile_update();

create table public.papers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(user_id),
  title text not null check (char_length(title) between 5 and 250),
  abstract text not null check (char_length(abstract) between 20 and 5000),
  track text not null check (track in ('applied', 'industry', 'convergence', 'education')),
  paper_type text not null check (paper_type in ('research', 'case', 'poster')),
  preferred_presentation text not null check (preferred_presentation in ('oral', 'poster', 'demo')),
  final_presentation text check (final_presentation in ('oral', 'poster', 'demo')),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'under_review', 'revision', 'accepted', 'rejected')),
  decision_note text not null default '',
  submitted_at timestamptz,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index papers_owner_idx on public.papers(owner_id);
create index papers_status_idx on public.papers(status);

create table public.paper_authors (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  sort_order smallint not null check (sort_order between 1 and 30),
  full_name text not null check (char_length(full_name) between 1 and 120),
  affiliation text not null check (char_length(affiliation) between 1 and 200),
  email text,
  unique (paper_id, sort_order)
);

create table public.paper_files (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  storage_path text not null unique,
  original_name text not null,
  version integer not null check (version > 0),
  uploaded_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  unique (paper_id, version)
);

create function app_private.guard_file_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from storage.objects
    where bucket_id = 'paper-pdfs' and name = new.storage_path) then
    raise exception 'Uploaded PDF not found';
  end if;
  return new;
end;
$$;
create trigger guard_file_insert before insert on public.paper_files
for each row execute function app_private.guard_file_insert();

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(user_id),
  recommendation text check (recommendation in ('accept', 'revise', 'reject')),
  comments text not null default '',
  conflict_confirmed boolean not null default false,
  submitted_at timestamptz,
  assigned_at timestamptz not null default now(),
  unique (paper_id, reviewer_id)
);
create index reviews_reviewer_idx on public.reviews(reviewer_id);

create function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.owner_id <> old.owner_id or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at) then
      raise exception 'Only chairs may change decision fields';
    end if;
    if old.status not in ('draft', 'revision') or new.status not in ('draft', 'submitted') then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and not exists
      (select 1 from public.conference_settings where submissions_open) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id) then
      raise exception 'A PDF is required before submission';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger guard_paper_update before update on public.papers
for each row execute function app_private.guard_paper_update();

create function app_private.guard_review_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.paper_id <> old.paper_id or new.reviewer_id <> old.reviewer_id then
    raise exception 'Review assignment cannot be changed';
  end if;
  if new.recommendation is not null and (new.comments = '' or not new.conflict_confirmed) then
    raise exception 'Comment and conflict confirmation are required';
  end if;
  if new.recommendation is not null then new.submitted_at := now(); end if;
  return new;
end;
$$;
create trigger guard_review_update before update on public.reviews
for each row execute function app_private.guard_review_update();

alter table public.conference_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.staff_roles enable row level security;
alter table public.papers enable row level security;
alter table public.paper_authors enable row level security;
alter table public.paper_files enable row level security;
alter table public.reviews enable row level security;

create policy settings_read on public.conference_settings for select to anon, authenticated using (true);
create policy settings_chair on public.conference_settings for update to authenticated
  using (app_private.is_chair()) with check (app_private.is_chair());
create policy profiles_read on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or app_private.is_chair());
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy roles_read on public.staff_roles for select to authenticated
  using (user_id = (select auth.uid()) or app_private.is_chair());

create policy papers_read on public.papers for select to authenticated using (
  owner_id = (select auth.uid()) or app_private.is_chair() or
  exists (select 1 from public.reviews r where r.paper_id = id and r.reviewer_id = (select auth.uid()))
);
create policy papers_insert on public.papers for insert to authenticated with check (
  owner_id = (select auth.uid()) and status = 'draft' and
  exists (select 1 from public.conference_settings where submissions_open)
);
create policy papers_author_update on public.papers for update to authenticated
  using (owner_id = (select auth.uid()) and status in ('draft', 'revision'))
  with check (owner_id = (select auth.uid()) and status in ('draft', 'submitted'));
create policy papers_chair_update on public.papers for update to authenticated
  using (app_private.is_chair()) with check (app_private.is_chair());

create policy authors_read on public.paper_authors for select to authenticated
  using (exists (select 1 from public.papers p where p.id = paper_id));
create policy authors_insert on public.paper_authors for insert to authenticated with check (
  exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid()) and p.status in ('draft', 'revision'))
);
create policy authors_delete on public.paper_authors for delete to authenticated using (
  exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid()) and p.status in ('draft', 'revision'))
);

create policy files_read on public.paper_files for select to authenticated
  using (exists (select 1 from public.papers p where p.id = paper_id));
create policy files_insert on public.paper_files for insert to authenticated with check (
  uploaded_by = (select auth.uid()) and
  split_part(storage_path, '/', 1) = (select auth.uid())::text and
  split_part(storage_path, '/', 2) = paper_id::text and
  exists (select 1 from public.papers p where p.id = paper_id and p.owner_id = (select auth.uid()) and p.status in ('draft', 'revision'))
);

create policy reviews_read on public.reviews for select to authenticated using (
  reviewer_id = (select auth.uid()) or app_private.is_chair()
);
create policy reviews_assign on public.reviews for insert to authenticated with check (
  app_private.is_chair() and
  exists (select 1 from public.papers p where p.id = paper_id and p.owner_id <> reviewer_id and p.status in ('submitted', 'under_review'))
);
create policy reviews_reviewer_update on public.reviews for update to authenticated
  using (reviewer_id = (select auth.uid()) and exists
    (select 1 from public.papers p where p.id = paper_id and p.status = 'under_review'))
  with check (reviewer_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('paper-pdfs', 'paper-pdfs', false, 20971520, array['application/pdf'])
on conflict (id) do nothing;
create policy paper_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'paper-pdfs' and
  (storage.foldername(name))[1] = (select auth.uid())::text and
  exists (select 1 from public.papers p where p.id::text = (storage.foldername(name))[2]
    and p.owner_id = (select auth.uid()) and p.status in ('draft', 'revision'))
);
create policy paper_storage_read on storage.objects for select to authenticated using (
  bucket_id = 'paper-pdfs' and exists (
    select 1 from public.paper_files f join public.papers p on p.id = f.paper_id
    where f.storage_path = name
  )
);
create policy paper_storage_cleanup on storage.objects for delete to authenticated using (
  bucket_id = 'paper-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text
  and not exists (select 1 from public.paper_files f where f.storage_path = name)
);

grant select on public.conference_settings to anon, authenticated;
grant update on public.conference_settings to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.staff_roles to authenticated;
grant select, insert, update on public.papers to authenticated;
grant select, insert, delete on public.paper_authors to authenticated;
grant select, insert on public.paper_files to authenticated;
grant select, insert, update on public.reviews to authenticated;
