-- Let the CLI's read-only query role (`supabase db query --read-only`) run the
-- read-only purge helpers: previews and the PDF list used by scripts/purge-paper-pdfs.py.
-- That role already reads all tables (pg_read_all_data); this exposes no new data.
-- The functions that delete anything stay owner-only.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_read_only_user') then
    grant execute on function app_private.preview_registration_purge(integer) to supabase_read_only_user;
    grant execute on function app_private.preview_edition_purge(integer) to supabase_read_only_user;
    grant execute on function app_private.proceedings_candidates(integer) to supabase_read_only_user;
    grant execute on function app_private.purgeable_accounts(integer) to supabase_read_only_user;
    grant execute on function app_private.paper_pdf_paths_to_purge() to supabase_read_only_user;
  end if;
end;
$$;
