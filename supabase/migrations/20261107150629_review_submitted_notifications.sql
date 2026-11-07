-- Review submission mail uses the existing queue and credentials. Opt-in after server deployment.
alter table app_private.review_email_config
  add column review_submitted_enabled boolean not null default false,
  add column review_submitted_chair_ids uuid[] not null default '{}';
alter table app_private.review_email_outbox drop constraint review_email_outbox_kind_check;
alter table app_private.review_email_outbox add constraint review_email_outbox_kind_check
  check(kind in ('reviewer_assignment','decision','review_submitted'));

create function app_private.review_submission_recipients(p_id uuid)
returns table(user_id uuid,email text,full_name text)
language sql stable security definer set search_path='' as $$
  select distinct on (lower(u.email)) u.id,lower(u.email),coalesce(nullif(pr.full_name,''),'회원')
  from public.papers p cross join auth.users u
  left join public.profiles pr on pr.user_id=u.id
  where p.id=p_id and p.edition_year=app_private.current_edition_year()
    and p.status<>'draft' and p.submitted_at is not null and u.email_confirmed_at is not null
    and lower(u.email) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' and char_length(u.email)<=254
    and (
      exists(select 1 from public.staff_roles s cross join app_private.review_email_config cfg
        where s.user_id=u.id and s.role='chair' and cfg.id and u.id=any(cfg.review_submitted_chair_ids))
      or (
        p.owner_id<>u.id
        and exists(select 1 from public.review_committee c where c.edition_year=p.edition_year
          and c.track=p.track and c.committee_role='associate_editor' and c.active and c.email=lower(u.email))
        and not exists(select 1 from public.paper_authors a where a.paper_id=p.id and lower(btrim(a.email))=lower(u.email))
        and not exists(select 1 from public.reviews r where r.paper_id=p.id and r.reviewer_id=u.id and r.review_state='declined')
      )
    )
  order by lower(u.email),u.id;
$$;
revoke all on function app_private.review_submission_recipients(uuid) from public,anon,authenticated;

create or replace function app_private.process_review_email_queue() returns void
language plpgsql security definer set search_path='' as $$
declare q record; cfg app_private.review_email_config; token text; provider text; expired boolean;
begin
  -- Never wait on another scheduler or an enqueue transaction.
  if not pg_try_advisory_xact_lock(6182741301) then return; end if;
  select * into cfg from app_private.review_email_config where id;
  -- Always collect acknowledgments, including while delivery is disabled.
  for q in select o.*,r.id as response_id,r.status_code,r.content,r.timed_out
    from app_private.review_email_outbox o left join net._http_response r on r.id=o.request_id
    where o.status='sending' and (r.id is not null or o.attempted_at<now()-interval '2 minutes')
    order by o.created_at limit 50 for update of o skip locked
  loop
    provider:=null;
    if q.status_code between 200 and 299 and not coalesce(q.timed_out,false) then
      begin provider:=q.content::jsonb->>'id'; exception when others then provider:=null; end;
    end if;
    if provider ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      update app_private.review_email_outbox set status='sent',provider_id=provider,sent_at=now(),last_error='' where id=q.id;
    elsif q.status_code between 400 and 499 and q.status_code not in (408,429) then
      update app_private.review_email_outbox set status='failed',last_error='http_'||q.status_code where id=q.id;
    else
      expired:=q.first_attempt_at<now()-interval '23 hours';
      update app_private.review_email_outbox set
        status=case when expired then 'uncertain' when q.attempts>=8 then 'failed' else 'retry' end,
        last_error=case when expired then 'idempotency_window' when q.response_id is null or coalesce(q.timed_out,false) then 'response_timeout'
          else 'http_'||coalesce(q.status_code::text,'unknown') end,
        next_attempt_at=now()+make_interval(secs=>least(3600,60*power(2,least(q.attempts,6))::integer))
      where id=q.id;
    end if;
  end loop;
  if not coalesce(cfg.enabled,false) then return; end if;
  select decrypted_secret into token from vault.decrypted_secrets where name='review_email_webhook_token' limit 1;
  if token is null or length(token)<32 then
    update app_private.review_email_config set last_error='hook_not_configured' where id; return;
  end if;
  update app_private.review_email_config set last_error='' where id and last_error<>'';
  for q in select * from app_private.review_email_outbox
    where status in ('queued','retry') and next_attempt_at<=now()
      and (kind<>'review_submitted' or cfg.review_submitted_enabled) order by created_at,id limit 2 for update skip locked
  loop
    if q.first_attempt_at is not null and q.first_attempt_at<now()-interval '23 hours' then
      update app_private.review_email_outbox set status='uncertain',last_error='idempotency_window' where id=q.id; continue;
    end if;
    if q.attempts>=8 then
      update app_private.review_email_outbox set status='failed',last_error='attempt_limit' where id=q.id; continue;
    end if;
    if not exists(select 1 from auth.users u where u.id=q.recipient_id and u.email_confirmed_at is not null and lower(u.email)=q.recipient_email) then
      update app_private.review_email_outbox set status='cancelled',last_error='recipient_changed' where id=q.id; continue;
    end if;
    if not q.is_test then
      if q.kind='review_submitted' then
        if not exists(select 1 from public.reviews r join public.papers p on p.id=r.paper_id
          where r.id=q.review_id and r.paper_id=q.paper_id and r.revoked_at is null and r.review_state='submitted'
            and r.manuscript_submitted_at=p.submitted_at and p.status<>'draft'
            and p.edition_year=app_private.current_edition_year()
            and md5(jsonb_build_array(r.recommendation,r.comments)::text)=q.payload->>'reviewFingerprint') then
          update app_private.review_email_outbox set status='cancelled',last_error='review_obsolete' where id=q.id; continue;
        end if;
        if not exists(select 1 from app_private.review_submission_recipients(q.paper_id) t
          where t.user_id=q.recipient_id and t.email=q.recipient_email) then
          update app_private.review_email_outbox set status='cancelled',last_error='recipient_role_changed' where id=q.id; continue;
        end if;
      end if;
      if q.kind='reviewer_assignment' and not exists(
        select 1 from public.reviews r join public.papers p on p.id=r.paper_id
        where r.id=q.review_id and r.revoked_at is null and r.review_state<>'declined'
          and r.manuscript_submitted_at=p.submitted_at and p.status in ('submitted','under_review')) then
        update app_private.review_email_outbox set status='cancelled',last_error='assignment_obsolete' where id=q.id; continue;
      end if;
      if q.kind='decision' and not exists(
        select 1 from public.papers p where p.id=q.paper_id and p.status=q.payload->>'decision'
          and p.decision_published_at=(q.payload->>'publishedAt')::timestamptz
          and p.submitted_at=(q.payload->>'manuscriptAt')::timestamptz) then
        update app_private.review_email_outbox set status='cancelled',last_error='decision_obsolete' where id=q.id; continue;
      end if;
    end if;
    begin
      update app_private.review_email_outbox set status='sending',attempts=attempts+1,
        first_attempt_at=coalesce(first_attempt_at,now()),attempted_at=now(),last_error='',
        request_id=net.http_post(url:=cfg.endpoint,headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||token),
          body:=q.payload||jsonb_build_object('eventId',q.id,'test',q.is_test),timeout_milliseconds:=12000)
      where id=q.id;
    exception when others then
      -- A transient network extension/config issue must not roll back a paper decision.
      update app_private.review_email_outbox set status='retry',last_error='dispatch_unavailable',
        attempts=attempts+1,first_attempt_at=coalesce(first_attempt_at,now()),next_attempt_at=now()+interval '5 minutes' where id=q.id;
    end;
  end loop;
end; $$;
revoke all on function app_private.process_review_email_queue() from public,anon,authenticated;

create function app_private.enqueue_review_submission_email() returns trigger
language plpgsql security definer set search_path='' as $$
declare p public.papers; r public.reviews; target record; snapshot text;
begin
  if not exists(select 1 from app_private.review_email_config where id and review_submitted_enabled)
    or new.after_data->>'review_state' is distinct from 'submitted' then return new; end if;
  -- A retry of an identical save updates submitted_at, but is not a new review submission.
  if new.before_data->>'review_state'='submitted'
    and new.before_data->'comments' is not distinct from new.after_data->'comments'
    and new.before_data->'recommendation' is not distinct from new.after_data->'recommendation' then return new; end if;
  select * into p from public.papers where id=new.paper_id;
  select * into r from public.reviews where id=(new.after_data->>'id')::uuid and paper_id=p.id
    and review_state='submitted' and revoked_at is null and manuscript_submitted_at=p.submitted_at;
  if r.id is null then return new; end if;
  snapshot:=md5(jsonb_build_array(new.after_data->>'recommendation',new.after_data->>'comments')::text);
  for target in select * from app_private.review_submission_recipients(p.id) loop
    insert into app_private.review_email_outbox(event_key,paper_id,review_id,recipient_id,recipient_email,kind,payload)
    values('review-submitted:'||new.id::text||':'||target.user_id::text,p.id,r.id,target.user_id,target.email,'review_submitted',
      jsonb_build_object('version',2,'kind','review_submitted','recipient',target.email,'recipientName',target.full_name,
        'paperId',p.id,'paperTitle',p.title,'editionYear',p.edition_year,'track',p.track,
        'conferenceTitle',(select title from public.conference_editions where year=p.edition_year),
        'reviewId',r.id,'reviewFingerprint',snapshot,'note','','exceptionReason',''))
    on conflict(event_key) do nothing;
  end loop;
  if exists(select 1 from app_private.review_email_config where id and enabled) then
    perform app_private.process_review_email_queue();
  end if;
  return new;
end; $$;
revoke all on function app_private.enqueue_review_submission_email() from public,anon,authenticated;
create trigger enqueue_review_submission_email after insert on public.paper_events
  for each row when (new.action='review_submitted') execute function app_private.enqueue_review_submission_email();

-- Report whether this specific mail kind is enabled, including during a v2-only rollback.
create or replace function app_private.review_email_status(p_id uuid) returns table(
  id uuid,kind text,status text,recipient_email text,attempts integer,created_at timestamptz,sent_at timestamptz,last_error text,enabled boolean)
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null or not(app_private.is_chair() or app_private.is_paper_editor(p_id)) then
    raise exception 'Editorial permission required';
  end if;
  return query select q.id,q.kind,q.status,q.recipient_email,q.attempts,q.created_at,q.sent_at,
    coalesce(nullif(q.last_error,''),nullif(c.last_error,''),''),c.enabled and (q.kind<>'review_submitted' or c.review_submitted_enabled)
    from app_private.review_email_outbox q cross join app_private.review_email_config c
    where q.paper_id=p_id order by q.created_at desc,q.id limit 100;
end; $$;
revoke all on function app_private.review_email_status(uuid) from public,anon;
grant execute on function app_private.review_email_status(uuid) to authenticated;
