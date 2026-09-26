-- Browser validation is not a substitute for submission data integrity.
alter table public.paper_authors add constraint paper_authors_email_format check (
  email is null or (
    char_length(email) <= 254
    and email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  )
);

create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.id <> old.id
      or new.created_at is distinct from old.created_at
      or new.owner_id <> old.owner_id
      or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at) then
      raise exception 'Only chairs may change identity or decision fields';
    end if;
    if old.status not in ('draft', 'revision') or new.status not in ('draft', 'submitted') then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings
      where submissions_open and (submission_deadline is null or now() <= submission_deadline)
    ) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_authors where paper_id = new.id) then
      raise exception 'At least one author is required';
    end if;
    if not exists (
      select 1 from public.paper_files
      where paper_id = new.id and file_stage = 'submission'
    ) then
      raise exception 'A submission PDF is required';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;
