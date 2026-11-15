-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f scripts/verify-financial-retention.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

do $$
declare
  chair uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); m2 uuid := gen_random_uuid(); m3 uuid := gen_random_uuid();
  r1 uuid; r2 uuid; r3 uuid; doc uuid; result jsonb; preview jsonb; n integer; failed boolean;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'retention-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (m1, 'retention-m1@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (m2, 'retention-m2@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (m3, 'retention-m3@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 참가자 ' || right(email, 14), affiliation = '로컬 검증 기관'
    where user_id in (m1, m2, m3);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  perform set_config('request.jwt.claim.sub', chair::text, true);

  insert into public.document_issuers (edition_year, organization, representative, address, contact_email, enabled)
    values (2026, '로컬 검증 발급기관', '검증 대표', '로컬 주소', 'issuer@example.test', true)
    on conflict (edition_year) do update set organization = excluded.organization, representative = excluded.representative,
      address = excluded.address, contact_email = excluded.contact_email, enabled = true;

  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status, checked_in_at)
    values (m1, 2026, 'faculty', array[date '2027-01-20'], 'confirmed', now()) returning id into r1;
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status, checked_in_at)
    values (m2, 2026, 'student', array[date '2027-01-21'], 'confirmed', now()) returning id into r2;
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status)
    values (m3, 2026, 'industry', array[date '2027-01-20'], 'confirmed') returning id into r3;

  insert into public.registration_billing (registration_id, amount, status, payment_method, paid_at, verified, updated_by)
    values (r1, 50000, 'paid', 'transfer', now() - interval '1 day', true, chair),
           (r2, 0, 'waived', null, null, true, chair),
           (r3, 70000, 'paid', 'cash', now() - interval '1 day', true, chair);
  perform public.issue_registration_document(r1, 'attendance');
  perform public.issue_registration_document(r1, 'receipt');
  doc := public.issue_registration_document(r1, 'statement');
  perform public.revoke_registration_document(doc, '로컬 검증 발급 취소');
  perform public.issue_registration_document(r2, 'attendance');
  perform public.issue_registration_document(r3, 'receipt');
  update public.registration_billing set status = 'refunded' where registration_id = r3; -- auto-revokes receipt
  raise notice 'PASS: synthetic registrations, billing and documents created';

  failed := false;
  begin perform app_private.archive_and_purge_registrations(2026, date '2032-12-31', 'PURGE REGISTRATIONS 2026');
  exception when others then failed := sqlerrm like '%after the conference ends%'; end;
  assert failed, 'Purge must be refused before the conference ends';
  raise notice 'PASS: refused before event end';

  update public.conference_editions set start_date = current_date - 10, end_date = current_date - 9 where year = 2026;
  insert into public.conference_editions (year, title, start_date, end_date, status)
    values (2099, 'Synthetic next edition 2099', date '2099-01-20', date '2099-01-21', 'draft');
  perform public.activate_conference_edition(2099);
  assert (select status from public.conference_editions where year = 2026) = 'archived';

  failed := false;
  begin delete from public.attendee_registrations where id = r2;
  exception when others then failed := sqlerrm like '%Only the current conference%'; end;
  assert failed, 'Ordinary delete of an archived registration must stay blocked';
  raise notice 'PASS: ordinary delete outside the purge is still blocked';

  failed := false;
  begin perform app_private.archive_and_purge_registrations(2026, date '2032-12-31', 'purge 2026');
  exception when others then failed := sqlerrm like '%Confirmation text%'; end;
  assert failed, 'Wrong confirmation must be refused';
  failed := false;
  begin perform app_private.archive_and_purge_registrations(2026, current_date + 365, 'PURGE REGISTRATIONS 2026');
  exception when others then failed := sqlerrm like '%shorter than 5 years%'; end;
  assert failed, 'Retention shorter than 5 years must be refused';
  raise notice 'PASS: confirmation text and minimum 5-year retention enforced';

  preview := app_private.preview_registration_purge(2026);
  assert (preview ->> 'registrations_to_delete')::int = 3, preview::text;
  assert (preview ->> 'billing_rows_to_delete')::int = 3, preview::text;
  assert (preview ->> 'payment_records_to_archive')::int = 2, preview::text;
  assert (preview ->> 'financial_documents_to_archive')::int = 3, preview::text;
  assert (preview ->> 'attendance_documents_to_delete')::int = 2, preview::text;
  assert (preview ->> 'minimum_retain_until')::date = ((now() at time zone 'Asia/Seoul')::date + interval '5 years')::date, preview::text;
  assert (select count(*) from public.attendee_registrations where edition_year = 2026) = 3, 'Preview must not delete';
  raise notice 'PASS: preview counts %', preview;

  result := app_private.archive_and_purge_registrations(2026, date '2032-12-31', 'PURGE REGISTRATIONS 2026');
  assert (result ->> 'payment_records_archived')::int = 2, result::text;
  assert (result ->> 'financial_documents_archived')::int = 3, result::text;
  assert (result ->> 'documents_deleted')::int = 5, result::text;
  assert (result ->> 'billing_rows_deleted')::int = 3, result::text;
  assert (result ->> 'registrations_deleted')::int = 3, result::text;
  assert not exists (select 1 from public.attendee_registrations where edition_year = 2026);
  assert not exists (select 1 from public.registration_billing where registration_id in (r1, r2, r3));
  assert not exists (select 1 from public.registration_documents where registration_id in (r1, r2, r3));
  assert not exists (select 1 from app_private.registration_purge_context), 'Purge context must be cleared';
  raise notice 'PASS: purge result %', result;

  assert (select count(*) from app_private.financial_record_archive where edition_year = 2026) = 5;
  assert exists (select 1 from app_private.financial_record_archive where record_type = 'payment' and source_registration_id = r1
    and amount = 50000 and billing_status = 'paid' and payment_method = 'transfer' and recipient_name like '합성 참가자%'
    and recipient_affiliation = '로컬 검증 기관' and retain_until = date '2032-12-31');
  assert exists (select 1 from app_private.financial_record_archive where record_type = 'payment' and source_registration_id = r3
    and billing_status = 'refunded' and amount = 70000);
  assert not exists (select 1 from app_private.financial_record_archive where source_registration_id = r2), 'Waived/attendance-only data must not be kept';
  assert (select count(*) from app_private.financial_record_archive where record_type = 'document' and document_state = 'revoked') = 2;
  assert exists (select 1 from app_private.financial_record_archive where record_type = 'document' and document_kind = 'receipt'
    and document_state = 'issued' and source_registration_id = r1 and document_snapshot -> 'issuer' ->> 'organization' = '로컬 검증 발급기관');
  assert not exists (select 1 from app_private.financial_record_archive a join auth.users u on u.id = a.source_registration_id),
    'Archive must not reference accounts';
  raise notice 'PASS: archive holds only payment/refund records and receipts/statements with snapshots';

  result := app_private.archive_and_purge_registrations(2026, date '2033-12-31', 'PURGE REGISTRATIONS 2026');
  assert (result ->> 'registrations_deleted')::int = 0 and (result ->> 'payment_records_archived')::int = 0, result::text;
  assert not exists (select 1 from app_private.financial_record_archive where retain_until <> date '2032-12-31');
  raise notice 'PASS: re-run is a no-op and keeps the original retention date';

  update app_private.financial_record_archive set retain_until = current_date - 1 where source_registration_id = r3;
  n := app_private.purge_expired_financial_records();
  assert n = 2, 'Expected r3 payment + receipt expired, got ' || n;
  assert (select count(*) from app_private.financial_record_archive where edition_year = 2026) = 3;
  raise notice 'PASS: expired records destroyed, unexpired kept';

  delete from public.profiles where user_id = m1;
  assert not exists (select 1 from public.profiles where user_id = m1);
  raise notice 'PASS: member profile can now be deleted without financial FK errors';

  assert exists (select 1 from cron.job where jobname = 'co-rnbd-financial-retention'
    and command like '%purge_expired_financial_records%');
  raise notice 'PASS: daily retention cron job registered';
end $$;

-- App roles must not see or run any of it.
set local role authenticated;
do $$
declare failed boolean;
begin
  failed := false; begin perform 1 from app_private.financial_record_archive; exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not read the archive';
  failed := false; begin perform app_private.preview_registration_purge(2026); exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not run preview';
  failed := false; begin perform app_private.archive_and_purge_registrations(2026, date '2032-12-31', 'PURGE REGISTRATIONS 2026');
  exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not run purge';
  failed := false; begin perform app_private.purge_expired_financial_records(); exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not run expiry purge';
  failed := false; begin insert into app_private.registration_purge_context values (pg_current_xact_id(), 2026);
  exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not open a purge context';
  raise notice 'PASS: authenticated role denied on archive, context and all functions';
end $$;
reset role;
set local role service_role;
do $$
declare failed boolean := false;
begin
  begin perform 1 from app_private.financial_record_archive; exception when insufficient_privilege then failed := true; end;
  assert failed, 'service_role must not read the archive';
  raise notice 'PASS: service_role denied on archive';
end $$;
reset role;
rollback;
