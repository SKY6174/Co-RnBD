-- Automatic documents from verified registration/billing data. No online payment processing.
create table public.document_issuers (
  edition_year integer primary key references public.conference_editions(year),
  organization text not null default '' check (char_length(organization)<=150),
  representative text not null default '' check (char_length(representative)<=80),
  address text not null default '' check (char_length(address)<=300),
  organization_number text not null default '' check (char_length(organization_number)<=40),
  contact_email text not null default '' check (char_length(contact_email)<=254),
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  check (not enabled or (btrim(organization)<>'' and btrim(representative)<>'' and btrim(address)<>'' and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
);
create table public.registration_billing (
  registration_id uuid primary key references public.attendee_registrations(id),
  amount integer not null check (amount between 0 and 100000000),
  status text not null check (status in ('unpaid','paid','waived','refunded')),
  payment_method text check (payment_method in ('transfer','cash','other')),
  paid_at timestamptz,
  verified boolean not null check (verified),
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  check ((status in ('paid','refunded') and amount>0 and payment_method is not null and paid_at is not null)
    or (status in ('unpaid','waived') and payment_method is null and paid_at is null)),
  check (status<>'waived' or amount=0)
);
create index registration_billing_actor_idx on public.registration_billing(updated_by);
create table public.registration_documents (
  id uuid primary key default gen_random_uuid(),
  serial bigint generated always as identity unique,
  document_no text not null unique,
  registration_id uuid not null references public.attendee_registrations(id),
  kind text not null check (kind in ('attendance','receipt','statement')),
  snapshot jsonb not null,
  state text not null default 'issued' check (state in ('issued','revoked')),
  issued_by uuid not null references auth.users(id),
  issued_at timestamptz not null default now(),
  revoked_by uuid references auth.users(id),
  revoked_at timestamptz,
  revocation_reason text not null default '',
  check ((state='issued' and revoked_by is null and revoked_at is null and revocation_reason='') or
    (state='revoked' and revoked_by is not null and revoked_at is not null and char_length(btrim(revocation_reason)) between 5 and 500))
);
create unique index registration_documents_current_idx on public.registration_documents(registration_id,kind) where state='issued';
create index registration_documents_history_idx on public.registration_documents(registration_id,issued_at desc);
create index registration_documents_issued_by_idx on public.registration_documents(issued_by);
create index registration_documents_revoked_by_idx on public.registration_documents(revoked_by) where revoked_by is not null;
alter table public.document_issuers enable row level security;
alter table public.registration_billing enable row level security;
alter table public.registration_documents enable row level security;
revoke all on public.document_issuers,public.registration_billing,public.registration_documents from anon,authenticated;
grant select,insert,update on public.document_issuers,public.registration_billing,public.registration_documents to authenticated;
grant usage on sequence public.registration_documents_serial_seq to authenticated;
create policy issuers_read on public.document_issuers for select to authenticated using (true);
create policy issuers_insert on public.document_issuers for insert to authenticated with check ((select app_private.is_chair()));
create policy issuers_update on public.document_issuers for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
create policy billing_read on public.registration_billing for select to authenticated using ((select app_private.is_chair()) or exists(
 select 1 from public.attendee_registrations r where r.id=registration_id and r.user_id=(select auth.uid())));
create policy billing_insert on public.registration_billing for insert to authenticated with check ((select app_private.is_chair()));
create policy billing_update on public.registration_billing for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
create policy documents_read on public.registration_documents for select to authenticated using ((select app_private.is_chair()) or exists(
 select 1 from public.attendee_registrations r where r.id=registration_id and r.user_id=(select auth.uid())));
create policy documents_insert on public.registration_documents for insert to authenticated with check ((select app_private.is_chair()) or exists(
 select 1 from public.attendee_registrations r where r.id=registration_id and r.user_id=(select auth.uid())));
create policy documents_update on public.registration_documents for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()));

create function app_private.guard_document_billing() returns trigger
language plpgsql set search_path='' as $$
begin
 if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
 if tg_op='UPDATE' and new.registration_id<>old.registration_id then raise exception 'Registration cannot change'; end if;
 perform 1 from public.attendee_registrations where id=new.registration_id for no key update;
 if not found then raise exception 'Registration not found'; end if;
 if new.paid_at>now() then raise exception 'Payment date cannot be in the future'; end if;
 new.updated_by:=auth.uid(); new.updated_at:=now(); return new;
end; $$;
revoke all on function app_private.guard_document_billing() from public,anon,authenticated;
create trigger guard_document_billing before insert or update on public.registration_billing for each row execute function app_private.guard_document_billing();

create function app_private.guard_registration_document() returns trigger
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
 select * into b from public.registration_billing where registration_id=r.id;
 if new.kind in ('receipt','statement') and not found then raise exception 'Registration fee configuration required'; end if;
 if new.kind='receipt' and (b.status is distinct from 'paid' or b.amount<=0) then raise exception 'Verified payment required'; end if;
 if new.kind='attendance' and r.checked_in_at is null then raise exception 'Attendance check-in required'; end if;
 select * into p from public.profiles where user_id=r.user_id;
 if not found or btrim(p.full_name)='' or btrim(p.affiliation)='' then raise exception 'Name and affiliation required'; end if;
 select * into e from public.conference_editions where year=r.edition_year;
 new.document_no:='CRBD-'||r.edition_year||'-'||upper(substr(new.kind,1,1))||'-'||lpad(new.serial::text,greatest(6,length(new.serial::text)),'0');
 new.snapshot:=jsonb_build_object('version',1,'recipient',jsonb_build_object('name',p.full_name,'affiliation',p.affiliation),
   'conference',jsonb_build_object('year',e.year,'title',e.title,'start_date',e.start_date,'end_date',e.end_date,'venue',e.venue),
   'attendance_days',r.attendance_days,'issuer',to_jsonb(i)-array['enabled','updated_at'],
   'billing',case when new.kind='attendance' then null else to_jsonb(b)-array['updated_by','updated_at','verified','registration_id'] end);
 new.issued_by:=auth.uid(); new.issued_at:=now(); new.revoked_by:=null; new.revoked_at:=null; new.revocation_reason:='';
 return new;
end; $$;
revoke all on function app_private.guard_registration_document() from public,anon,authenticated;
create trigger guard_registration_document before insert or update on public.registration_documents for each row execute function app_private.guard_registration_document();

create function app_private.revoke_changed_registration_documents() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if tg_table_name='registration_billing' then
   if not app_private.is_chair() then raise exception 'Chair permission required'; end if;
   if (new.amount,new.status,new.payment_method,new.paid_at) is distinct from (old.amount,old.status,old.payment_method,old.paid_at) then
     update public.registration_documents set state='revoked',revocation_reason='등록비 또는 납부 확인 내역 변경' where registration_id=new.registration_id and kind in ('receipt','statement') and state='issued';
   end if;
 elsif new.status<>'confirmed' or new.checked_in_at is distinct from old.checked_in_at then
   if new.user_id<>auth.uid() and not app_private.is_chair() then raise exception 'Registration permission required'; end if;
   update public.registration_documents set state='revoked',revocation_reason='참가 취소 또는 체크인 확인 내역 변경'
    where registration_id=new.id and state='issued' and (new.status<>'confirmed' or (kind='attendance' and new.checked_in_at is null));
 end if;
 return new;
end; $$;
revoke all on function app_private.revoke_changed_registration_documents() from public,anon,authenticated;
create trigger revoke_billing_documents after update on public.registration_billing for each row execute function app_private.revoke_changed_registration_documents();
create trigger revoke_attendance_documents after update on public.attendee_registrations for each row execute function app_private.revoke_changed_registration_documents();

create function public.issue_registration_document(p_registration_id uuid,p_kind text) returns uuid
language plpgsql security invoker set search_path='' as $$
declare document_id uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 perform 1 from public.attendee_registrations where id=p_registration_id and (user_id=auth.uid() or app_private.is_chair()) for no key update;
 if not found then raise exception 'Registration permission required'; end if;
 select id into document_id from public.registration_documents where registration_id=p_registration_id and kind=p_kind and state='issued';
 if document_id is not null then return document_id; end if;
 insert into public.registration_documents(registration_id,kind,document_no,snapshot,issued_by)
 values (p_registration_id,p_kind,'', '{}'::jsonb,auth.uid()) returning id into document_id;
 return document_id;
end; $$;
revoke all on function public.issue_registration_document(uuid,text) from public,anon;
grant execute on function public.issue_registration_document(uuid,text) to authenticated;
create function public.revoke_registration_document(p_id uuid,p_reason text) returns void
language plpgsql security invoker set search_path='' as $$
declare registration uuid;
begin
 if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
 select registration_id into registration from public.registration_documents where id=p_id;
 perform 1 from public.attendee_registrations where id=registration for no key update;
 update public.registration_documents set state='revoked',revocation_reason=btrim(p_reason) where id=p_id and state='issued';
 if not found then raise exception 'Document changed; reload'; end if;
end; $$;
revoke all on function public.revoke_registration_document(uuid,text) from public,anon;
grant execute on function public.revoke_registration_document(uuid,text) to authenticated;
