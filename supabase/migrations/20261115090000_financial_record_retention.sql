-- Post-event registration purge with separate 5-year retention of financial records.
-- Privacy policy: registration data is destroyed after the event, while payment/refund
-- confirmations and issued receipts/statements are kept apart for 5 years
-- (Framework Act on National Taxes art. 85-3). Only a database administrator
-- (SQL Editor / CLI as postgres) can run these functions; no app role can.

create table app_private.financial_record_archive (
  id uuid primary key default gen_random_uuid(),
  edition_year integer not null,
  source_registration_id uuid not null,
  record_type text not null check (record_type in ('payment', 'document')),
  recipient_name text not null default '',
  recipient_affiliation text not null default '',
  amount integer,
  billing_status text check (billing_status in ('unpaid', 'paid', 'waived', 'refunded')),
  payment_method text,
  paid_at timestamptz,
  document_no text unique,
  document_kind text check (document_kind in ('receipt', 'statement')),
  document_state text check (document_state in ('issued', 'revoked')),
  document_snapshot jsonb,
  issued_at timestamptz,
  revoked_at timestamptz,
  revocation_reason text,
  archived_at timestamptz not null default now(),
  retain_until date not null,
  check (
    (record_type = 'payment' and amount is not null and billing_status in ('paid', 'refunded')
      and document_no is null and document_snapshot is null)
    or (record_type = 'document' and document_no is not null and document_kind is not null
      and document_state is not null and document_snapshot is not null and issued_at is not null)
  )
);
comment on table app_private.financial_record_archive is
  'Separately retained payment confirmations and receipts/statements after registration purge. No link to accounts. Deleted after retain_until.';
create unique index financial_record_archive_payment_idx
  on app_private.financial_record_archive (source_registration_id) where record_type = 'payment';
create index financial_record_archive_retention_idx on app_private.financial_record_archive (retain_until);
alter table app_private.financial_record_archive enable row level security;
revoke all on app_private.financial_record_archive from public, anon, authenticated, service_role;

-- Marks the single transaction allowed to delete registrations of a non-current edition.
create table app_private.registration_purge_context (
  tx_id xid8 primary key,
  edition_year integer not null
);
alter table app_private.registration_purge_context enable row level security;
revoke all on app_private.registration_purge_context from public, anon, authenticated, service_role;

-- Same rules as before, plus the purge-transaction exception for registration deletes.
create or replace function app_private.guard_current_edition_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target_year integer;
begin
  target_year := case when tg_op = 'DELETE' then old.edition_year else new.edition_year end;
  if tg_op = 'DELETE' and tg_table_name = 'attendee_registrations' and exists (
    select 1 from app_private.registration_purge_context c
    where c.tx_id = pg_current_xact_id() and c.edition_year = target_year
  ) then return old; end if;
  if tg_op = 'UPDATE' and new.edition_year <> old.edition_year then
    raise exception 'Conference year cannot be changed';
  end if;
  if tg_op = 'INSERT' and tg_table_name = 'conference_settings'
    and app_private.is_chair() and exists (
      select 1 from public.conference_editions where year = target_year and status = 'draft'
    ) then return new; end if;
  if not exists (select 1 from public.conference_editions where year = target_year and status = 'current') then
    raise exception 'Only the current conference may be changed';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function app_private.guard_current_edition_row() from public;

-- Read-only dry run: what the purge would archive and delete.
create function app_private.preview_registration_purge(p_year integer) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  e public.conference_editions;
  latest timestamptz;
begin
  select * into e from public.conference_editions where year = p_year;
  if not found then raise exception 'Unknown conference year %', p_year; end if;
  select greatest(
    (select max(b.paid_at) from public.registration_billing b
       join public.attendee_registrations r on r.id = b.registration_id
      where r.edition_year = p_year and b.status in ('paid', 'refunded')),
    (select max(greatest(d.issued_at, coalesce(d.revoked_at, d.issued_at))) from public.registration_documents d
       join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = p_year and d.kind in ('receipt', 'statement'))
  ) into latest;
  return jsonb_build_object(
    'edition_year', p_year,
    'edition_status', e.status,
    'edition_end_date', e.end_date,
    'purge_allowed_from', e.end_date + 1,
    'registrations_to_delete', (select count(*) from public.attendee_registrations where edition_year = p_year),
    'billing_rows_to_delete', (select count(*) from public.registration_billing b
       join public.attendee_registrations r on r.id = b.registration_id where r.edition_year = p_year),
    'payment_records_to_archive', (select count(*) from public.registration_billing b
       join public.attendee_registrations r on r.id = b.registration_id
      where r.edition_year = p_year and b.status in ('paid', 'refunded')),
    'financial_documents_to_archive', (select count(*) from public.registration_documents d
       join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = p_year and d.kind in ('receipt', 'statement')),
    'attendance_documents_to_delete', (select count(*) from public.registration_documents d
       join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = p_year and d.kind = 'attendance'),
    'latest_financial_activity', latest,
    'minimum_retain_until', case when latest is null then null
      else ((latest at time zone 'Asia/Seoul')::date + interval '5 years')::date end,
    'already_archived', (select count(*) from app_private.financial_record_archive where edition_year = p_year),
    'confirmation_text', format('PURGE REGISTRATIONS %s', p_year)
  );
end;
$$;

-- Archive financial records, verify the copy, then delete every registration,
-- billing and document row of the edition in one transaction.
create function app_private.archive_and_purge_registrations(
  p_year integer, p_retain_until date, p_confirmation text
) returns jsonb
language plpgsql set search_path = '' as $$
declare
  e public.conference_editions;
  today date := (now() at time zone 'Asia/Seoul')::date;
  latest timestamptz;
  n_payments integer; n_documents integer; missing integer;
  n_doc_deleted integer; n_billing_deleted integer; n_reg_deleted integer;
begin
  if p_confirmation is distinct from format('PURGE REGISTRATIONS %s', p_year) then
    raise exception 'Confirmation text must be exactly: PURGE REGISTRATIONS %', p_year;
  end if;
  select * into e from public.conference_editions where year = p_year for update;
  if not found then raise exception 'Unknown conference year %', p_year; end if;
  if e.end_date is null or today <= e.end_date then
    raise exception 'Registrations can be purged only after the conference ends (end date %)', e.end_date;
  end if;
  if p_retain_until is null or p_retain_until <= today then
    raise exception 'Retention end date must be in the future';
  end if;

  -- Block concurrent registration edits and document issuance for this edition.
  perform 1 from public.attendee_registrations where edition_year = p_year for update;

  select greatest(
    (select max(b.paid_at) from public.registration_billing b
       join public.attendee_registrations r on r.id = b.registration_id
      where r.edition_year = p_year and b.status in ('paid', 'refunded')),
    (select max(greatest(d.issued_at, coalesce(d.revoked_at, d.issued_at))) from public.registration_documents d
       join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = p_year and d.kind in ('receipt', 'statement'))
  ) into latest;
  if latest is not null
     and p_retain_until < ((latest at time zone 'Asia/Seoul')::date + interval '5 years')::date then
    raise exception 'Retention end date % is shorter than 5 years after the latest financial record (%)',
      p_retain_until, (latest at time zone 'Asia/Seoul')::date;
  end if;

  insert into app_private.financial_record_archive (
    edition_year, source_registration_id, record_type, recipient_name, recipient_affiliation,
    amount, billing_status, payment_method, paid_at, retain_until)
  select p_year, r.id, 'payment',
    coalesce(nullif(btrim(p.full_name), ''), last_doc.snapshot -> 'recipient' ->> 'name', ''),
    coalesce(nullif(btrim(p.affiliation), ''), last_doc.snapshot -> 'recipient' ->> 'affiliation', ''),
    b.amount, b.status, b.payment_method, b.paid_at, p_retain_until
  from public.registration_billing b
  join public.attendee_registrations r on r.id = b.registration_id
  left join public.profiles p on p.user_id = r.user_id
  left join lateral (
    select d.snapshot from public.registration_documents d
    where d.registration_id = r.id order by d.issued_at desc limit 1
  ) last_doc on true
  where r.edition_year = p_year and b.status in ('paid', 'refunded')
  on conflict (source_registration_id) where record_type = 'payment' do nothing;
  get diagnostics n_payments = row_count;

  insert into app_private.financial_record_archive (
    edition_year, source_registration_id, record_type, recipient_name, recipient_affiliation,
    amount, billing_status, payment_method, paid_at,
    document_no, document_kind, document_state, document_snapshot, issued_at, revoked_at,
    revocation_reason, retain_until)
  select p_year, d.registration_id, 'document',
    coalesce(d.snapshot -> 'recipient' ->> 'name', ''),
    coalesce(d.snapshot -> 'recipient' ->> 'affiliation', ''),
    (d.snapshot -> 'billing' ->> 'amount')::integer,
    d.snapshot -> 'billing' ->> 'status',
    d.snapshot -> 'billing' ->> 'payment_method',
    (d.snapshot -> 'billing' ->> 'paid_at')::timestamptz,
    d.document_no, d.kind, d.state, d.snapshot, d.issued_at, d.revoked_at,
    nullif(d.revocation_reason, ''), p_retain_until
  from public.registration_documents d
  join public.attendee_registrations r on r.id = d.registration_id
  where r.edition_year = p_year and d.kind in ('receipt', 'statement')
  on conflict (document_no) do nothing;
  get diagnostics n_documents = row_count;

  select
    (select count(*) from public.registration_billing b
       join public.attendee_registrations r on r.id = b.registration_id
      where r.edition_year = p_year and b.status in ('paid', 'refunded')
        and not exists (select 1 from app_private.financial_record_archive a
          where a.record_type = 'payment' and a.source_registration_id = b.registration_id))
    + (select count(*) from public.registration_documents d
       join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = p_year and d.kind in ('receipt', 'statement')
        and not exists (select 1 from app_private.financial_record_archive a
          where a.record_type = 'document' and a.document_no = d.document_no))
  into missing;
  if missing <> 0 then raise exception 'Archive verification failed: % financial records not copied', missing; end if;

  insert into app_private.registration_purge_context (tx_id, edition_year) values (pg_current_xact_id(), p_year);
  delete from public.registration_documents d using public.attendee_registrations r
    where d.registration_id = r.id and r.edition_year = p_year;
  get diagnostics n_doc_deleted = row_count;
  delete from public.registration_billing b using public.attendee_registrations r
    where b.registration_id = r.id and r.edition_year = p_year;
  get diagnostics n_billing_deleted = row_count;
  delete from public.attendee_registrations where edition_year = p_year;
  get diagnostics n_reg_deleted = row_count;
  delete from app_private.registration_purge_context where tx_id = pg_current_xact_id();

  return jsonb_build_object(
    'edition_year', p_year,
    'retain_until', p_retain_until,
    'payment_records_archived', n_payments,
    'financial_documents_archived', n_documents,
    'documents_deleted', n_doc_deleted,
    'billing_rows_deleted', n_billing_deleted,
    'registrations_deleted', n_reg_deleted
  );
end;
$$;

-- Destroy archived financial records whose retention period has ended (KST).
create function app_private.purge_expired_financial_records() returns integer
language plpgsql set search_path = '' as $$
declare n integer;
begin
  delete from app_private.financial_record_archive
  where retain_until < (now() at time zone 'Asia/Seoul')::date;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function app_private.preview_registration_purge(integer) from public, anon, authenticated, service_role;
revoke all on function app_private.archive_and_purge_registrations(integer, date, text) from public, anon, authenticated, service_role;
revoke all on function app_private.purge_expired_financial_records() from public, anon, authenticated, service_role;

-- Daily at 03:30 KST.
select cron.schedule('co-rnbd-financial-retention', '30 18 * * *',
  'select app_private.purge_expired_financial_records();');
