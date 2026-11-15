-- Small document rule fixes:
--  * no 거래명세서 (statement) for a refunded registration fee;
--  * an issued attendance certificate is revoked when the attendance days change,
--    so a reissue reflects the new days.
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
 select * into b from public.registration_billing where registration_id=r.id;
 if new.kind in ('receipt','statement') and not found then raise exception 'Registration fee configuration required'; end if;
 if new.kind='receipt' and (b.status is distinct from 'paid' or b.amount<=0) then raise exception 'Verified payment required'; end if;
 if new.kind='statement' and b.status='refunded' then raise exception 'A statement is not issued for a refunded fee'; end if;
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

create or replace function app_private.revoke_changed_registration_documents() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if tg_table_name='registration_billing' then
   if not app_private.is_chair() then raise exception 'Chair permission required'; end if;
   if (new.amount,new.status,new.payment_method,new.paid_at) is distinct from (old.amount,old.status,old.payment_method,old.paid_at) then
     update public.registration_documents set state='revoked',revocation_reason='등록비 또는 납부 확인 내역 변경' where registration_id=new.registration_id and kind in ('receipt','statement') and state='issued';
   end if;
 elsif new.status<>'confirmed' or new.checked_in_at is distinct from old.checked_in_at
   or new.attendance_days is distinct from old.attendance_days then
   if new.user_id<>auth.uid() and not app_private.is_chair() then raise exception 'Registration permission required'; end if;
   update public.registration_documents set state='revoked',revocation_reason='참가 취소, 체크인 또는 참가일 변경'
    where registration_id=new.id and state='issued' and (new.status<>'confirmed' or (kind='attendance'
      and (new.checked_in_at is null or new.attendance_days is distinct from old.attendance_days)));
 end if;
 return new;
end; $$;
revoke all on function app_private.revoke_changed_registration_documents() from public,anon,authenticated;
