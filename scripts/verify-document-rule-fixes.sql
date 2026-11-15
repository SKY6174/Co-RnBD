-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-document-rule-fixes.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

do $$
declare chair uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); m2 uuid := gen_random_uuid();
  r1 uuid; r2 uuid; att uuid; rec uuid; att2 uuid; failed boolean;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'doc-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (m1, 'doc-m1@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (m2, 'doc-m2@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 참가자', affiliation = '로컬 검증 기관' where user_id in (chair, m1, m2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  perform set_config('request.jwt.claim.sub', chair::text, true);
  insert into public.document_issuers (edition_year, organization, representative, address, contact_email, enabled)
    values (2026, '로컬 검증 발급기관', '검증 대표', '로컬 주소', 'issuer@example.test', true)
    on conflict (edition_year) do update set organization = excluded.organization, representative = excluded.representative,
      address = excluded.address, contact_email = excluded.contact_email, enabled = true;
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status, checked_in_at)
    values (m1, 2026, 'faculty', array[date '2027-01-20'], 'confirmed', now()) returning id into r1;
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status)
    values (m2, 2026, 'faculty', array[date '2027-01-20'], 'confirmed') returning id into r2;
  insert into public.registration_billing (registration_id, amount, status, payment_method, paid_at, verified, updated_by)
    values (r1, 50000, 'paid', 'transfer', now() - interval '1 day', true, chair),
           (r2, 50000, 'refunded', 'transfer', now() - interval '1 day', true, chair);

  failed := false;
  begin perform public.issue_registration_document(r2, 'statement');
  exception when others then failed := sqlerrm = 'A statement is not issued for a refunded fee'; end;
  assert failed, 'Statement issued for a refunded fee';
  perform public.issue_registration_document(r1, 'statement');
  raise notice 'PASS: statement refused for a refunded fee, still issued for a paid fee';

  att := public.issue_registration_document(r1, 'attendance');
  rec := public.issue_registration_document(r1, 'receipt');
  update public.attendee_registrations set attendance_days = array[date '2027-01-20', date '2027-01-21'] where id = r1;
  assert (select state from public.registration_documents where id = att) = 'revoked', 'Attendance certificate not revoked after day change';
  assert (select revocation_reason from public.registration_documents where id = att) like '%참가일 변경%';
  assert (select state from public.registration_documents where id = rec) = 'issued', 'Receipt must stay valid when only days change';
  att2 := public.issue_registration_document(r1, 'attendance');
  assert att2 <> att and (select snapshot -> 'attendance_days' from public.registration_documents where id = att2) = '["2027-01-20", "2027-01-21"]'::jsonb,
    (select snapshot -> 'attendance_days' from public.registration_documents where id = att2)::text;
  raise notice 'PASS: day change revokes only the attendance certificate; reissue shows the new days';

  update public.attendee_registrations set checked_in_at = null where id = r1;
  assert (select state from public.registration_documents where id = att2) = 'revoked', 'Check-in undo must still revoke';
  raise notice 'PASS: existing check-in revocation unchanged';
end $$;
rollback;
