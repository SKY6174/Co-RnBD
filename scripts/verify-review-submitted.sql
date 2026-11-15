-- Run only in the disposable LOCAL fixture created by verify-review-email.py.
-- Everything, including net requests, rolls back. No bypass of triggers or RLS policies.
begin;
select pg_advisory_xact_lock(6182741301);
update app_private.review_email_config set enabled=false;
do $$
declare author_id uuid; chief_id uuid; ae_id uuid; reviewer_user_id uuid; fixture uuid:=gen_random_uuid();
  rid uuid; other_review uuid; qid uuid; v1qid uuid; original_submission timestamptz; fingerprint text; file_path text;
  old_confirmed timestamptz; n integer;
begin
  if not exists(select 1 from auth.users where email='author@example.test')
    or (select count(*) from auth.users where email not like '%@example.test')<>0 then
    raise exception 'Disposable fixture required'; end if;
  select id into author_id from auth.users where email='author@example.test';
  select id into chief_id from auth.users where email='chief@example.test';
  select id,email_confirmed_at into ae_id,old_confirmed from auth.users where email='reviewer1@example.test';
  select id into reviewer_user_id from auth.users where email='reviewer2@example.test';
  update app_private.review_email_config set review_submitted_enabled=true,review_submitted_chair_ids=array[chief_id];
  update public.review_committee set active=true where committee_role='associate_editor' and track='master_eng';
  perform set_config('request.jwt.claim.sub',author_id::text,true);
  insert into public.papers(id,owner_id,title,abstract,track,paper_type,preferred_presentation,edition_year,contact_name,contact_email)
    values(fixture,author_id,'LOCAL NOTIFICATION GUARDS','Synthetic review-notification transaction fixture only.','master_eng','research','oral',2026,'Synthetic author','author@example.test');
  insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email)
    values(fixture,1,'Synthetic author','Local fixture','author@example.test');
  file_path:=author_id::text||'/'||fixture::text||'/submission/fixture.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
    values('paper-pdfs',file_path,author_id::text,'{"mimetype":"application/pdf","size":100}'::jsonb);
  insert into public.paper_files(paper_id,storage_path,original_name,version,uploaded_by,file_stage)
    values(fixture,file_path,'fixture.pdf',1,author_id,'submission');
  update public.papers set status='submitted' where id=fixture;
  select submitted_at into original_submission from public.papers where id=fixture;
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  perform public.chair_assign_reviewer(fixture,ae_id);
  perform public.chair_assign_reviewer(fixture,reviewer_user_id);
  select id into rid from public.reviews where paper_id=fixture and public.reviews.reviewer_id=reviewer_user_id;
  select id into other_review from public.reviews where paper_id=fixture and public.reviews.reviewer_id=ae_id;
  assert (select count(*) from app_private.review_submission_recipients(fixture))=2,'Expected field AE and chief';

  -- Roles in more than one recipient set still produce one mail to the address.
  insert into public.review_committee(edition_year,track,committee_role,display_name,email)
    values(2026,'master_eng','associate_editor','Chief AE fixture','chief@example.test');
  assert (select count(*) from app_private.review_submission_recipients(fixture))=2,'Dual-role recipient duplicated';
  delete from public.review_committee where email='chief@example.test' and committee_role='associate_editor';
  update public.review_committee set active=false where email='reviewer1@example.test' and committee_role='associate_editor' and track='master_eng';
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=ae_id),'Inactive AE included';
  update public.review_committee set active=true,track='master_sci' where email='reviewer1@example.test' and committee_role='associate_editor' and track='master_eng';
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=ae_id),'Wrong-field AE included';
  update public.review_committee set track='master_eng' where email='reviewer1@example.test' and committee_role='associate_editor' and track='master_sci';
  insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email)
    values(fixture,2,'AE coauthor','Local fixture','reviewer1@example.test');
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=ae_id),'Coauthor AE included';
  delete from public.paper_authors where paper_id=fixture and sort_order=2;
  insert into public.review_committee(edition_year,track,committee_role,display_name,email)
    values(2026,'master_eng','associate_editor','Author AE fixture','author@example.test');
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=author_id),'Author AE included';
  update auth.users set email_confirmed_at=null where id=ae_id;
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=ae_id),'Unverified AE included';
  update auth.users set email_confirmed_at=old_confirmed where id=ae_id;

  perform set_config('request.jwt.claim.sub',reviewer_user_id::text,true);
  update public.reviews set review_state='draft',comments='draft notification fixture' where id=rid;
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted'),'Draft generated mail';
  update public.reviews set review_state='submitted',comments='initial notification fixture',recommendation='accept',conflict_confirmed=true where id=rid;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted')=2,'First submission missing';
  update public.reviews set comments='initial notification fixture' where id=rid;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted')=2,'Identical save generated mail';
  update public.reviews set comments='updated notification fixture',recommendation='revise' where id=rid;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted')=4,'Changed submission missing';
  update app_private.review_email_config set review_submitted_enabled=false;
  update public.reviews set comments='paused notification fixture' where id=rid;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted')=4,'Disabled feature generated mail';
  update app_private.review_email_config set review_submitted_enabled=true;
  update public.reviews set comments='latest notification fixture' where id=rid;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted')=6,'Re-enabled submission missing';
  select md5(jsonb_build_array(recommendation,comments)::text) into fingerprint from public.reviews where id=rid;
  select id into qid from app_private.review_email_outbox where paper_id=fixture and kind='review_submitted'
    and recipient_id=ae_id and payload->>'reviewFingerprint'=fingerprint;
  assert qid is not null,'Expected latest AE notification';
  -- Isolate one pending request while exercising the real private worker in this rollback.
  update app_private.review_email_outbox set status='cancelled' where paper_id=fixture;
  update app_private.review_email_outbox set status='queued' where id=qid;
  select id into v1qid from app_private.review_email_outbox where paper_id=fixture and kind='reviewer_assignment' and recipient_id=ae_id;
  update app_private.review_email_outbox set status='queued' where id=v1qid;
  update app_private.review_email_config set enabled=true,review_submitted_enabled=false;
  perform app_private.process_review_email_queue();
  assert (select status='queued' from app_private.review_email_outbox where id=qid),'Paused v2 was dispatched';
  assert (select status='sending' from app_private.review_email_outbox where id=v1qid),'Paused v2 blocked v1 mail';
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  assert not (select bool_or(enabled) from public.review_email_status(fixture) where kind='review_submitted'),'Status API misreported paused mail';
  update app_private.review_email_config set review_submitted_enabled=true;
  update public.review_committee set active=false where email='reviewer1@example.test' and committee_role='associate_editor' and track='master_eng';
  perform app_private.process_review_email_queue();
  assert (select status='cancelled' and last_error='recipient_role_changed' from app_private.review_email_outbox where id=qid),'Revoked AE was sent mail';
  update public.review_committee set active=true where email='reviewer1@example.test' and committee_role='associate_editor' and track='master_eng';
  update app_private.review_email_outbox set status='queued',payload=jsonb_set(payload,'{reviewFingerprint}','"00000000000000000000000000000000"') where id=qid;
  perform app_private.process_review_email_queue();
  assert (select last_error='review_obsolete' from app_private.review_email_outbox where id=qid),'Old opinion snapshot sent';
  update app_private.review_email_outbox set status='queued',payload=jsonb_set(payload,'{reviewFingerprint}',to_jsonb(fingerprint)) where id=qid;
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  update public.papers set submitted_at=original_submission+interval '1 second' where id=fixture;
  perform app_private.process_review_email_queue();
  assert (select last_error='review_obsolete' from app_private.review_email_outbox where id=qid),'Previous manuscript review sent';
  update public.papers set submitted_at=original_submission where id=fixture;
  perform set_config('request.jwt.claim.sub',ae_id::text,true);
  update public.reviews set review_state='declined',decline_reason='declared conflict fixture' where id=other_review;
  assert not exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=ae_id),'Declared conflict AE included';
  update app_private.review_email_outbox set status='queued' where id=qid;
  perform app_private.process_review_email_queue();
  assert (select last_error='recipient_role_changed' from app_private.review_email_outbox where id=qid),'Conflict AE was sent mail';
  assert not has_function_privilege('authenticated','app_private.review_submission_recipients(uuid)','execute'),'Private helper exposed';
  assert not has_function_privilege('anon','app_private.enqueue_review_submission_email()','execute'),'Private trigger exposed';
end; $$;
rollback;
select 'PASS: review submission event and recipient guards, all fixture writes rolled back';
