-- Attendance certificate (참가확인증) readiness:
--  * one permanent certificate number per person per edition, stored in the DB:
--    제2026-TCR-001호 (re-issue after a revocation keeps the same number);
--  * joint issuers (공동명의) configured by the chair, printed without a seal;
--  * issuance opens only after the event ends (configurable, defaults to the day after end_date KST);
--  * every issued document gets a random verification code and a public, minimal verification RPC.

-- 1. Issuer settings: joint signatories and the certificate opening time.
create function app_private.valid_signatories(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 3 and not exists (
    select 1 from jsonb_array_elements(p) s
    where jsonb_typeof(s) <> 'object'
       or (s - array['organization','title','name']) <> '{}'::jsonb
       or char_length(btrim(coalesce(s->>'organization',''))) not between 1 and 150
       or char_length(btrim(coalesce(s->>'title',''))) not between 1 and 40
       or char_length(btrim(coalesce(s->>'name',''))) not between 1 and 80);
$$;
revoke all on function app_private.valid_signatories(jsonb) from public, anon, authenticated;

alter table public.document_issuers
  add column signatories jsonb not null default '[]'::jsonb
    check (app_private.valid_signatories(signatories)),
  add column attendance_available_at timestamptz;
comment on column public.document_issuers.signatories is
  'Joint issuers printed on attendance certificates: [{organization,title,name}], max 3. Empty = organization/representative.';
comment on column public.document_issuers.attendance_available_at is
  'Attendance certificates can be issued from this time. NULL = 00:00 KST on the day after end_date.';

-- 2. One certificate number per person per edition.
create table app_private.certificate_counters (
  edition_year integer primary key references public.conference_editions(year),
  last_seq integer not null default 0 check (last_seq >= 0)
);
create table public.certificate_numbers (
  edition_year integer not null references public.conference_editions(year),
  user_id uuid not null references auth.users(id) on delete cascade,
  seq integer not null check (seq > 0),
  certificate_no text not null unique,
  assigned_at timestamptz not null default now(),
  primary key (edition_year, user_id),
  unique (edition_year, seq)
);
create index certificate_numbers_user_idx on public.certificate_numbers(user_id);
alter table public.certificate_numbers enable row level security;
revoke all on public.certificate_numbers from anon, authenticated;
grant select on public.certificate_numbers to authenticated;
create policy certificate_numbers_read on public.certificate_numbers for select to authenticated
  using ((select app_private.is_chair()) or user_id = (select auth.uid()));

create function app_private.certificate_number(p_year integer, p_user uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare n integer; result text;
begin
  select certificate_no into result from public.certificate_numbers where edition_year = p_year and user_id = p_user;
  if found then return result; end if;
  insert into app_private.certificate_counters(edition_year, last_seq) values (p_year, 1)
  on conflict (edition_year) do update set last_seq = app_private.certificate_counters.last_seq + 1
  returning last_seq into n;
  result := '제' || p_year || '-TCR-' || lpad(n::text, 3, '0') || '호';
  insert into public.certificate_numbers(edition_year, user_id, seq, certificate_no) values (p_year, p_user, n, result);
  return result;
end; $$;
revoke all on function app_private.certificate_number(integer, uuid) from public, anon, authenticated;

-- 3. Verification code; a reissued certificate keeps its number, so number uniqueness
--    applies to currently issued documents only.
alter table public.registration_documents add column verification_code text;
update public.registration_documents
   set verification_code = upper(encode(extensions.gen_random_bytes(10), 'hex'))
 where verification_code is null;
alter table public.registration_documents
  alter column verification_code set not null,
  add constraint registration_documents_verification_code_key unique (verification_code),
  add constraint registration_documents_verification_code_check check (verification_code ~ '^[0-9A-F]{20}$'),
  drop constraint registration_documents_document_no_key;
create unique index registration_documents_issued_no_idx on public.registration_documents(document_no) where state = 'issued';

create or replace function app_private.guard_registration_document() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.attendee_registrations; b public.registration_billing; i public.document_issuers; p public.profiles; e public.conference_editions;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into r from public.attendee_registrations where id=new.registration_id for no key update;
 if not found or (r.user_id<>auth.uid() and not app_private.is_chair()) then raise exception 'Registration permission required'; end if;
 if tg_op='UPDATE' then
   if not app_private.is_chair() and not (pg_trigger_depth()>1 and r.user_id=auth.uid() and r.status='cancelled') then raise exception 'Chair permission required'; end if;
   if (to_jsonb(new)-array['state','revoked_by','revoked_at','revocation_reason']) is distinct from
      (to_jsonb(old)-array['state','revoked_by','revoked_at','revocation_reason']) then raise exception 'Issued document is immutable'; end if;
   if old.state<>'issued' or new.state<>'revoked' then raise exception 'Only issued documents can be revoked'; end if;
   new.revoked_by:=auth.uid(); new.revoked_at:=now(); return new;
 end if;
 if new.state<>'issued' or r.status<>'confirmed' then raise exception 'Confirmed registration required'; end if;
 select * into i from public.document_issuers where edition_year=r.edition_year;
 if not found or not i.enabled then raise exception 'Issuer configuration required'; end if;
 select * into e from public.conference_editions where year=r.edition_year;
 select * into b from public.registration_billing where registration_id=r.id;
 if new.kind in ('receipt','statement') and not found then raise exception 'Registration fee configuration required'; end if;
 if new.kind='receipt' and (b.status is distinct from 'paid' or b.amount<=0) then raise exception 'Verified payment required'; end if;
 if new.kind='statement' and b.status='refunded' then raise exception 'A statement is not issued for a refunded fee'; end if;
 if new.kind='attendance' then
   if r.checked_in_at is null then raise exception 'Attendance check-in required'; end if;
   if now() < coalesce(i.attendance_available_at, ((e.end_date + 1)::timestamp at time zone 'Asia/Seoul')) then
     raise exception 'Attendance certificate opens after the event';
   end if;
 end if;
 select * into p from public.profiles where user_id=r.user_id;
 if not found or btrim(p.full_name)='' or btrim(p.affiliation)='' then raise exception 'Name and affiliation required'; end if;
 new.document_no:=case when new.kind='attendance' then app_private.certificate_number(r.edition_year, r.user_id)
   else 'CRBD-'||r.edition_year||'-'||upper(substr(new.kind,1,1))||'-'||lpad(new.serial::text,greatest(6,length(new.serial::text)),'0') end;
 new.verification_code:=upper(encode(extensions.gen_random_bytes(10),'hex'));
 new.snapshot:=jsonb_build_object('version',2,'recipient',jsonb_build_object('name',p.full_name,'affiliation',p.affiliation),
   'conference',jsonb_build_object('year',e.year,'title',e.title,'start_date',e.start_date,'end_date',e.end_date,'venue',e.venue),
   'attendance_days',r.attendance_days,'issuer',to_jsonb(i)-array['enabled','updated_at','signatories','attendance_available_at'],
   'signatories',case when jsonb_array_length(i.signatories)>0 then i.signatories
     else jsonb_build_array(jsonb_build_object('organization',i.organization,'title','대표','name',i.representative)) end,
   'billing',case when new.kind='attendance' then null else to_jsonb(b)-array['updated_by','updated_at','verified','registration_id'] end);
 new.issued_by:=auth.uid(); new.issued_at:=now(); new.revoked_by:=null; new.revoked_at:=null; new.revocation_reason:='';
 return new;
end; $$;
revoke all on function app_private.guard_registration_document() from public,anon,authenticated;

-- 4. Public verification: anyone holding the printed code can check validity.
--    Returns only what is needed to compare with the paper copy; the name is masked.
create function app_private.mask_name(p text) returns text
language sql immutable set search_path = '' as $$
  select case when p is null or char_length(btrim(p)) = 0 then ''
    when char_length(btrim(p)) <= 2 then left(btrim(p), 1) || '*'
    else left(btrim(p), 1) || repeat('*', char_length(btrim(p)) - 2) || right(btrim(p), 1) end;
$$;
revoke all on function app_private.mask_name(text) from public, anon, authenticated;

create function public.verify_registration_document(p_code text)
returns table(kind text, document_no text, state text, issued_at timestamptz, revoked_at timestamptz,
  recipient_name text, recipient_affiliation text, conference_title text, start_date date, end_date date, signatories jsonb)
language sql stable security definer set search_path = '' as $$
  select d.kind, d.document_no, d.state, d.issued_at, d.revoked_at,
         app_private.mask_name(d.snapshot->'recipient'->>'name'), d.snapshot->'recipient'->>'affiliation',
         d.snapshot->'conference'->>'title', (d.snapshot->'conference'->>'start_date')::date, (d.snapshot->'conference'->>'end_date')::date,
         coalesce(d.snapshot->'signatories', jsonb_build_array(jsonb_build_object('organization', d.snapshot->'issuer'->>'organization',
           'title', '대표', 'name', d.snapshot->'issuer'->>'representative')))
    from public.registration_documents d
   where char_length(coalesce(p_code, '')) <= 64
     and d.verification_code = upper(regexp_replace(p_code, '[^0-9A-Fa-f]', '', 'g'));
$$;
revoke all on function public.verify_registration_document(text) from public;
grant execute on function public.verify_registration_document(text) to anon, authenticated;
