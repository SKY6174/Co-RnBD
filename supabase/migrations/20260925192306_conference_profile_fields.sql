-- Keep existing accounts and drafts valid; require complete information at activity time.
alter table public.profiles
  add column department text not null default '',
  add column position_title text not null default '',
  add column orcid text not null default '',
  add column expertise_tracks text[] not null default '{}',
  add column committee_listing_consent boolean not null default false,
  add constraint profiles_department_length check (char_length(department) <= 120),
  add constraint profiles_position_length check (char_length(position_title) <= 120),
  add constraint profiles_orcid_format check (
    orcid = '' or orcid ~ '^([0-9]{4}-){3}[0-9]{3}[0-9X]$'
  ),
  add constraint profiles_expertise_tracks check (
    cardinality(expertise_tracks) <= 3
    and expertise_tracks <@ array['applied', 'industry', 'convergence', 'education']::text[]
    and array_position(expertise_tracks, null) is null
  ),
  add constraint profiles_identity_length check (
    char_length(full_name) <= 120 and char_length(affiliation) <= 200
  );

create or replace function app_private.guard_profile_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.user_id <> old.user_id or new.email is distinct from old.email then
    raise exception 'Identity fields cannot be changed';
  end if;
  if btrim(new.full_name) = '' or btrim(new.affiliation) = '' then
    raise exception 'Name and affiliation are required';
  end if;
  return new;
end;
$$;

alter table public.papers
  add column contact_name text not null default '',
  add column contact_email text not null default '',
  add column keywords text[] not null default '{}',
  add constraint papers_contact_name_length check (char_length(contact_name) <= 120),
  add constraint papers_contact_email_format check (
    contact_email = '' or (
      char_length(contact_email) <= 254
      and contact_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    )
  ),
  add constraint papers_keywords_limit check (
    cardinality(keywords) <= 5
    and array_position(keywords, '') is null
    and array_position(keywords, null) is null
    and char_length(array_to_string(keywords, ',')) <= 300
  ),
  add constraint papers_submission_contact check (
    status in ('draft', 'revision') or (
      btrim(contact_name) <> '' and btrim(contact_email) <> ''
      and cardinality(keywords) between 2 and 5
    )
  );

create function app_private.require_submission_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status = 'submitted' and not exists (
    select 1 from public.profiles p
    where p.user_id = new.owner_id
      and btrim(p.full_name) <> '' and btrim(p.affiliation) <> ''
  ) then
    raise exception 'Complete your name and affiliation before submitting';
  end if;
  return new;
end;
$$;
create trigger require_submission_profile before update on public.papers
for each row execute function app_private.require_submission_profile();

create function app_private.require_reviewer_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.review_state = 'submitted' and not exists (
    select 1 from public.profiles p
    where p.user_id = new.reviewer_id
      and btrim(p.full_name) <> '' and btrim(p.affiliation) <> ''
      and cardinality(p.expertise_tracks) between 1 and 3
  ) then
    raise exception 'Complete your profile and expertise before submitting a review';
  end if;
  return new;
end;
$$;
create trigger require_reviewer_profile before update on public.reviews
for each row execute function app_private.require_reviewer_profile();

revoke all on function app_private.require_submission_profile() from public;
revoke all on function app_private.require_reviewer_profile() from public;
