-- Allow the owner to save a chair-requested revision without changing its stage.
-- A draft still cannot become a revision; only the chair requests revisions.
create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.id <> old.id
      or new.created_at is distinct from old.created_at
      or new.owner_id <> old.owner_id
      or new.edition_year <> old.edition_year
      or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.assigned_session is distinct from old.assigned_session
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at)
    then
      raise exception 'Only chairs may change identity or decision fields';
    end if;
    if old.status not in ('draft', 'revision')
      or (new.status not in ('draft', 'submitted') and not (old.status = 'revision' and new.status = 'revision'))
    then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings s
      where s.edition_year = new.edition_year
        and s.submissions_open
        and (s.submission_deadline is null or now() <= s.submission_deadline)
    ) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_authors where paper_id = new.id)
    then
      raise exception 'At least one author is required';
    end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id and file_stage = 'submission')
    then
      raise exception 'A submission PDF is required';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

alter policy papers_update on public.papers
  with check (
    (owner_id = (select auth.uid()) and status in ('draft', 'revision', 'submitted'))
    or (select app_private.is_chair())
  );

-- Replace author rows atomically so a failed insert keeps the previous authors.
-- Runs with caller privileges and existing RLS; never bypasses ownership checks.
create function public.replace_paper_authors(p_paper_id uuid, p_authors jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_authors is null or jsonb_typeof(p_authors) <> 'array' then
    raise exception 'Authors must be an array';
  end if;
  if jsonb_array_length(p_authors) not between 1 and 30 then
    raise exception 'Provide 1 to 30 authors';
  end if;
  perform 1 from public.papers
    where id = p_paper_id and owner_id = auth.uid()
      and status in ('draft', 'revision')
      and edition_year = app_private.current_edition_year()
    for update;
  if not found then raise exception 'Paper is not editable by this user'; end if;
  delete from public.paper_authors where paper_id = p_paper_id;
  insert into public.paper_authors (paper_id,sort_order,full_name,affiliation,email,note)
    select p_paper_id, ordinal::smallint,
      btrim(author->>'full_name'), btrim(author->>'affiliation'),
      btrim(author->>'email'), nullif(btrim(author->>'note'),'')
    from jsonb_array_elements(p_authors) with ordinality as row(author,ordinal);
end;
$$;
revoke all on function public.replace_paper_authors(uuid,jsonb) from public, anon;
grant execute on function public.replace_paper_authors(uuid,jsonb) to authenticated;
