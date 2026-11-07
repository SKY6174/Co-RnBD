-- Only the synthetic LOCAL environment used by verify-review-email.py. All writes roll back.
begin;
select pg_advisory_xact_lock(6182741301);
update app_private.review_email_config set enabled=false,paper_submitted_enabled=true;
do $$
declare author_id uuid; chief_id uuid; ae_id uuid; other_id uuid; fixture uuid:=gen_random_uuid(); main_paper uuid;
  file_path text; qid uuid; event_id uuid; source_event public.paper_events; initial_at timestamptz; resubmissions integer;
begin
  if (select count(*) from auth.users where email not like '%@example.test')<>0 then raise exception 'Synthetic local accounts required'; end if;
  select id into author_id from auth.users where email='author@example.test';
  select id into chief_id from auth.users where email='chief@example.test';
  select id into ae_id from auth.users where email='reviewer1@example.test';
  select id into other_id from auth.users where email='outsider@example.test';
  assert author_id is not null and chief_id is not null and ae_id is not null;
  update public.review_committee set active=true where committee_role='associate_editor' and track='master_eng';
  update app_private.review_email_config set review_submitted_chair_ids=array[chief_id];
  perform set_config('request.jwt.claim.sub',author_id::text,true);
  insert into public.papers(id,owner_id,title,abstract,track,paper_type,preferred_presentation,edition_year,contact_name,contact_email)
    values(fixture,author_id,'LOCAL PAPER RECEIPT GUARDS','Synthetic receipt notification fixture, no real data.','master_eng','research','oral',2026,'Synthetic author','author@example.test');
  insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email)
    values(fixture,1,'Synthetic author','Local fixture','author@example.test');
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture),'Draft generated a mail';
  begin
    update public.papers set status='submitted' where id=fixture;
    raise exception 'Expected missing PDF failure';
  exception when others then
    assert SQLERRM like '%submission PDF%','Unexpected failed submission reason';
  end;
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture),'Failed submission generated mail';
  file_path:=author_id::text||'/'||fixture::text||'/submission/fixture.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('paper-pdfs',file_path,author_id::text,'{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files(paper_id,storage_path,original_name,version,uploaded_by,file_stage) values(fixture,file_path,'fixture.pdf',1,author_id,'submission');
  update public.papers set status='submitted' where id=fixture;
  select submitted_at into initial_at from public.papers where id=fixture;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='paper_submitted')=2,'Initial AE/chief mail missing';
  select * into source_event from public.paper_events where paper_id=fixture and action='paper_submitted' limit 1;
  insert into public.paper_events(paper_id,actor_id,actor_label,action,before_data,after_data)
    values(source_event.paper_id,source_event.actor_id,source_event.actor_label,source_event.action,source_event.before_data,source_event.after_data);
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='paper_submitted')=2,'Event replay duplicated receipt';
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  update public.papers set abstract=abstract||' saved' where id=fixture;
  assert (select count(*) from app_private.review_email_outbox where paper_id=fixture and kind='paper_submitted')=2,'Metadata save generated receipt';

  -- A newly eligible address would receive a replay if the disabled flag were ignored.
  insert into public.review_committee(edition_year,track,committee_role,display_name,email) values(2026,'master_eng','associate_editor','Extra AE fixture','outsider@example.test');
  assert exists(select 1 from app_private.review_submission_recipients(fixture) where user_id=other_id);
  update app_private.review_email_config set paper_submitted_enabled=false;
  insert into public.paper_events(paper_id,actor_id,actor_label,action,before_data,after_data)
    values(source_event.paper_id,source_event.actor_id,source_event.actor_label,source_event.action,source_event.before_data,source_event.after_data);
  assert not exists(select 1 from app_private.review_email_outbox where paper_id=fixture and recipient_id=other_id),'Disabled feature enqueued mail';
  delete from public.review_committee where email='outsider@example.test' and track='master_eng' and committee_role='associate_editor';
  update app_private.review_email_config set paper_submitted_enabled=true;

  -- The browser fixture's accepted manuscript predates this transaction, allowing a real new submission timestamp.
  select id into main_paper from public.papers where track='master_eng' and status='accepted' and id<>fixture;
  assert main_paper is not null,'Completed browser fixture required';
  select count(*) into resubmissions from app_private.review_email_outbox where paper_id=main_paper and kind='paper_resubmitted';
  update public.papers set status='revision',decision_note='Synthetic revision request' where id=main_paper;
  perform set_config('request.jwt.claim.sub',author_id::text,true);
  update public.papers set abstract=abstract||' revision draft' where id=main_paper;
  assert (select count(*) from app_private.review_email_outbox where paper_id=main_paper and kind='paper_resubmitted')=resubmissions,'Revision draft generated mail';
  file_path:=author_id::text||'/'||main_paper::text||'/submission/'||fixture::text||'.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('paper-pdfs',file_path,author_id::text,'{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files(paper_id,storage_path,original_name,version,uploaded_by,file_stage)
    select main_paper,file_path,'revision.pdf',coalesce(max(version),0)+1,author_id,'submission' from public.paper_files where paper_id=main_paper;
  update public.papers set status='submitted' where id=main_paper;
  assert (select count(*) from app_private.review_email_outbox where paper_id=main_paper and kind='paper_resubmitted')=resubmissions+2,'Revision resubmission missing AE/chief notices';

  select id into qid from app_private.review_email_outbox where paper_id=fixture and kind='paper_submitted' and recipient_id=ae_id;
  update app_private.review_email_outbox set status='cancelled' where paper_id in (fixture,main_paper) and status='queued';
  update app_private.review_email_outbox set status='queued' where id=qid;
  update app_private.review_email_config set enabled=true,paper_submitted_enabled=false;
  perform app_private.process_review_email_queue();
  assert (select status='queued' from app_private.review_email_outbox where id=qid),'Paused paper mail dispatched';
  perform set_config('request.jwt.claim.sub',chief_id::text,true);
  assert not(select bool_or(enabled) from public.review_email_status(fixture) where kind in ('paper_submitted','paper_resubmitted')),'Status RPC misreported paused paper mail';
  update app_private.review_email_config set paper_submitted_enabled=true;
  update public.review_committee set active=false where email='reviewer1@example.test' and track='master_eng' and committee_role='associate_editor';
  perform app_private.process_review_email_queue();
  assert (select last_error='recipient_role_changed' from app_private.review_email_outbox where id=qid),'Revoked AE received receipt';
  update public.review_committee set active=true where email='reviewer1@example.test' and track='master_eng' and committee_role='associate_editor';
  update app_private.review_email_outbox set status='queued',payload=jsonb_set(payload,'{manuscriptAt}',to_jsonb(initial_at-interval '1 minute')) where id=qid;
  perform app_private.process_review_email_queue();
  assert (select last_error='submission_obsolete' from app_private.review_email_outbox where id=qid),'Stale manuscript receipt sent';
  assert not has_function_privilege('authenticated','app_private.enqueue_paper_submission_email()','execute'),'Private trigger exposed';
end; $$;
rollback;
select 'PASS: initial/revision receipt guards, replay deduplication, pause and permissions; all writes rolled back';
