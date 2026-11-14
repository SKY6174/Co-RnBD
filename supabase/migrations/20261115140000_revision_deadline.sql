-- Optional deadline for resubmitting a revision after a "revision" decision.
-- Null keeps the current behaviour (no limit). The chair can still change status.
alter table public.conference_settings add column revision_deadline timestamptz;

create function app_private.guard_revision_deadline() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status = 'revision' and new.status = 'submitted' and not app_private.is_chair()
    and exists (
      select 1 from public.conference_settings s
      where s.edition_year = new.edition_year
        and s.revision_deadline is not null and now() > s.revision_deadline
    ) then
    raise exception 'The revision resubmission deadline has passed';
  end if;
  return new;
end;
$$;
revoke all on function app_private.guard_revision_deadline() from public, anon, authenticated;
create trigger guard_revision_deadline before update on public.papers
  for each row execute function app_private.guard_revision_deadline();
