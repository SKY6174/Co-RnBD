-- Only the disposable LOCAL browser fixture. All rows and net requests roll back.
begin;
select pg_advisory_xact_lock(6182741301);
update app_private.review_email_config set enabled=false,author_receipt_enabled=true;
do $$
declare author_id uuid; chief_id uuid; outsider_id uuid; fixture uuid:=gen_random_uuid(); main_paper uuid;
  file_path text; qid uuid; n integer; source_event public.paper_events; event_copy uuid;
begin
  if (select count(*) from auth.users where email not like '%@example.test')<>0 then raise exception 'Synthetic fixture only'; end if;
  select id into author_id from auth.users where email='author@example.test';
  select id into chief_id from auth.users where email='chief@example.test';
  select id into outsider_id from auth.users where email='outsider@example.test';
  assert author_id is not null and chief_id is not null and outsider_id is not null;
  perform set_config('request.jwt.claim.sub',author_id::text,true);
  insert into public.papers(id,owner_id,title,abstract,track,paper_type,preferred_presentation,edition_year,contact_name,contact_email)
    values(fixture,author_id,'LOCAL AUTHOR RECEIPT GUARDS','Synthetic author receipt transaction fixture only.','master_eng','research','oral',2026,'Other contact','outsider@example.test');
  insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email) values
    (fixture,1,'Synthetic author','Local fixture','author@example.test'),(fixture,2,'Synthetic coauthor','Local fixture','reviewer2@example.test');
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture),'Draft produced a receipt';
  begin
    update public.papers set status='submitted' where id=fixture;
    raise exception 'Expected missing PDF failure';
  exception when others then assert SQLERRM like '%submission PDF%','Unexpected submit error'; end;
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture),'Failed submit produced a receipt';
  file_path:=author_id::text||'/'||fixture::text||'/submission/fixture.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('paper-pdfs',file_path,author_id::text,'{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files(paper_id,storage_path,original_name,version,uploaded_by,file_stage) values(fixture,file_path,'fixture.pdf',1,author_id,'submission');
  update public.papers set status='submitted' where id=fixture;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='author_submission_receipt')=1,'Expected one owner receipt';
  select id into qid from app_private.review_email_outbox where paper_id=fixture and kind='author_submission_receipt';
  assert (select recipient_id=author_id and recipient_email='author@example.test' from app_private.review_email_outbox where id=qid),'Contact/coauthor used instead of owner';
  select * into source_event from public.paper_events where paper_id=fixture and action='paper_submitted' limit 1;
  insert into public.paper_events(paper_id,actor_id,actor_label,action,before_data,after_data)
    values(source_event.paper_id,source_event.actor_id,source_event.actor_label,source_event.action,source_event.before_data,source_event.after_data);
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='author_submission_receipt')=1,'Replay duplicated receipt';

  -- Disable receipts during a real revision submission; editorial notices remain independent.
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  select id into main_paper from public.papers where track='master_eng' and status='accepted' and id<>fixture;
  assert main_paper is not null;
  select count(*) into n from app_private.review_email_outbox where paper_id=main_paper and kind='author_resubmission_receipt';
  update public.papers set status='revision',decision_note='Synthetic receipt revision request' where id=main_paper;
  perform set_config('request.jwt.claim.sub',author_id::text,true);
  update public.papers set abstract=abstract||' receipt revision draft' where id=main_paper;
  assert (select count(*) from app_private.review_email_outbox where paper_id=main_paper and kind='author_resubmission_receipt')=n,'Revision draft produced receipt';
  update app_private.review_email_config set author_receipt_enabled=false;
  file_path:=author_id::text||'/'||main_paper::text||'/submission/'||fixture::text||'.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('paper-pdfs',file_path,author_id::text,'{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files(paper_id,storage_path,original_name,version,uploaded_by,file_stage)
    select main_paper,file_path,'revision.pdf',coalesce(max(version),0)+1,author_id,'submission' from public.paper_files where paper_id=main_paper;
  update public.papers set status='submitted' where id=main_paper;
  assert (select count(*) from app_private.review_email_outbox where paper_id=main_paper and kind='author_resubmission_receipt')=n,'Disabled receipt was enqueued';
  -- Compare timestamps rather than text because JSON and timestamptz use different separators.
  select * into source_event from public.paper_events where paper_id=main_paper and action='paper_submitted' and (after_data->>'submitted_at')::timestamptz=(select submitted_at from public.papers where id=main_paper) limit 1;
  assert source_event.id is not null;
  update app_private.review_email_config set author_receipt_enabled=true;
  insert into public.paper_events(paper_id,actor_id,actor_label,action,before_data,after_data)
    values(source_event.paper_id,source_event.actor_id,source_event.actor_label,source_event.action,source_event.before_data,source_event.after_data);
  assert (select count(*) from app_private.review_email_outbox where paper_id=main_paper and kind='author_resubmission_receipt')=n+1,'Valid resubmission receipt missing';

  -- Isolate the first receipt, and verify historical evidence survives a changed current submission.
  update app_private.review_email_outbox set status='cancelled' where paper_id in (fixture,main_paper) and status='queued';
  update app_private.review_email_outbox set status='queued' where id=qid;
  update app_private.review_email_config set enabled=true,author_receipt_enabled=false;
  perform app_private.process_review_email_queue();
  assert (select status='queued' from app_private.review_email_outbox where id=qid),'Paused receipt dispatched';
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  assert not(select bool_or(enabled) from public.review_email_status(fixture) where kind='author_submission_receipt'),'Receipt flag missing in status RPC';
  update app_private.review_email_config set author_receipt_enabled=true,paper_submitted_enabled=false;
  update public.papers set submitted_at=submitted_at+interval '1 minute' where id=fixture;
  perform app_private.process_review_email_queue();
  assert (select status='sending' from app_private.review_email_outbox where id=qid),'Historical receipt was cancelled by current manuscript';
  update app_private.review_email_outbox set status='queued',payload=jsonb_set(payload,'{submissionEventId}',to_jsonb(gen_random_uuid())) where id=qid;
  perform app_private.process_review_email_queue();
  assert (select last_error='receipt_unavailable' from app_private.review_email_outbox where id=qid),'Missing submission evidence accepted';
  update app_private.review_email_outbox set status='queued',payload=jsonb_set(payload,'{submissionEventId}',(select to_jsonb(id) from public.paper_events where paper_id=fixture and action='paper_submitted' order by created_at,id limit 1)) where id=qid;
  update public.papers set owner_id=outsider_id where id=fixture;
  perform app_private.process_review_email_queue();
  assert (select last_error='receipt_unavailable' from app_private.review_email_outbox where id=qid),'Changed owner received old receipt';
  update public.papers set owner_id=author_id where id=fixture;
  update app_private.review_email_outbox set status='queued',recipient_email='outsider@example.test' where id=qid;
  perform app_private.process_review_email_queue();
  assert (select last_error='recipient_changed' from app_private.review_email_outbox where id=qid),'Changed address accepted';
  assert not has_function_privilege('authenticated','app_private.enqueue_author_receipt_email()','execute'),'Receipt trigger exposed';
end; $$;
rollback;
select 'PASS: author receipt ownership, proof, contact isolation, duplicate and independent flags; all writes rolled back';
