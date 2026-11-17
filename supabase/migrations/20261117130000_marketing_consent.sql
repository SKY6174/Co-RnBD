-- Optional consent to promotional email, consent history, processing notices, one-click unsubscribe,
-- and a consent-only promotional segment for chair announcements.

create table public.marketing_consents (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  consented boolean not null default false,
  consented_at timestamptz,
  withdrawn_at timestamptz,
  source text not null check (source in ('mypage','registration','unsubscribe_link')),
  unsubscribe_token uuid not null unique default gen_random_uuid(),
  updated_at timestamptz not null default now(),
  constraint marketing_consent_dates check (not consented or consented_at is not null)
);
alter table public.marketing_consents enable row level security;
revoke all on public.marketing_consents from public, anon, authenticated;
grant select (user_id, consented, consented_at, withdrawn_at, source, updated_at) on public.marketing_consents to authenticated;
create policy marketing_consents_own_select on public.marketing_consents for select to authenticated
  using (user_id = (select auth.uid()));

create table app_private.marketing_consent_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  action text not null check (action in ('granted','withdrawn')),
  source text not null check (source in ('mypage','registration','unsubscribe_link')),
  created_at timestamptz not null default now()
);
create index marketing_consent_events_user_idx on app_private.marketing_consent_events(user_id, created_at desc);
alter table app_private.marketing_consent_events enable row level security;
revoke all on app_private.marketing_consent_events from public, anon, authenticated;

alter table app_private.review_email_outbox drop constraint review_email_outbox_kind_check;
alter table app_private.review_email_outbox add constraint review_email_outbox_kind_check
  check (kind in ('reviewer_assignment','decision','review_submitted','paper_submitted','paper_resubmitted',
    'author_submission_receipt','author_resubmission_receipt','registration_received','registration_confirmed',
    'registration_cancelled','announcement','consent_notice'));
alter table app_private.announcements drop constraint announcements_segment_check;
alter table app_private.announcements add constraint announcements_segment_check
  check (segment in ('registrants_confirmed','registrants_active','authors_submitted','authors_accepted','authors_draft',
    'reviewers_active','marketing_consented'));

-- Shared consent change: history, processing notice, and cancellation of pending promotional mail.
create function app_private.apply_marketing_consent(p_user uuid, p_consent boolean, p_source text)
returns text language plpgsql security definer set search_path = '' as $$
declare existing public.marketing_consents; address text; who text; at timestamptz := clock_timestamp();
begin
  select * into existing from public.marketing_consents where user_id = p_user for update;
  if found and existing.consented = p_consent then return 'unchanged'; end if;
  if not found and not p_consent then return 'unchanged'; end if;
  insert into public.marketing_consents(user_id, consented, consented_at, withdrawn_at, source, updated_at)
    values (p_user, p_consent, case when p_consent then at end, case when not p_consent then at end, p_source, at)
    on conflict (user_id) do update set consented = p_consent,
      consented_at = case when p_consent then at else public.marketing_consents.consented_at end,
      withdrawn_at = case when p_consent then null else at end,
      source = p_source, updated_at = at;
  insert into app_private.marketing_consent_events(user_id, action, source)
    values (p_user, case when p_consent then 'granted' else 'withdrawn' end, p_source);
  if not p_consent then
    update app_private.review_email_outbox o set status = 'cancelled', last_error = 'consent_withdrawn'
      where o.recipient_id = p_user and o.status in ('queued','retry') and o.payload->>'promotional' = 'true';
  end if;
  select lower(u.email), coalesce(nullif(btrim(pr.full_name), ''), '회원') into address, who
    from auth.users u left join public.profiles pr on pr.user_id = u.id
    where u.id = p_user and u.email_confirmed_at is not null;
  if address is not null then
    insert into app_private.review_email_outbox(event_key, recipient_id, recipient_email, kind, payload)
      values ('consent:' || p_user || ':' || to_char(at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), p_user, address, 'consent_notice',
        jsonb_build_object('version', 7, 'kind', 'consent_notice', 'recipient', address, 'recipientName', left(who, 120),
          'action', case when p_consent then 'granted' else 'withdrawn' end, 'source', p_source,
          'processedAt', to_char(at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'note', ''))
      on conflict (event_key) do nothing;
  end if;
  return case when p_consent then 'granted' else 'withdrawn' end;
end; $$;
revoke all on function app_private.apply_marketing_consent(uuid, boolean, text) from public, anon, authenticated;

create function public.set_marketing_consent(p_consent boolean, p_source text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null) then
    raise exception 'Verified account required' using errcode = '42501';
  end if;
  if p_consent is null or p_source not in ('mypage','registration') then
    raise exception 'Invalid consent request' using errcode = '22023';
  end if;
  return app_private.apply_marketing_consent(auth.uid(), p_consent, p_source);
end; $$;
revoke all on function public.set_marketing_consent(boolean, text) from public, anon;
grant execute on function public.set_marketing_consent(boolean, text) to authenticated;

create function public.unsubscribe_marketing(p_token uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare owner uuid; active boolean;
begin
  select user_id, consented into owner, active from public.marketing_consents where unsubscribe_token = p_token;
  if owner is null then return 'unknown'; end if;
  if not active then return 'already'; end if;
  perform app_private.apply_marketing_consent(owner, false, 'unsubscribe_link');
  return 'withdrawn';
end; $$;
revoke all on function public.unsubscribe_marketing(uuid) from public;
grant execute on function public.unsubscribe_marketing(uuid) to anon, authenticated;

-- Promotional segment: active consent given within the last two years.
create or replace function app_private.announcement_recipients(p_segment text, p_year integer)
returns table(user_id uuid, email text, full_name text)
language sql stable security definer set search_path = '' as $$
  with members as (
    select r.user_id from public.attendee_registrations r
      where r.edition_year = p_year and p_segment = 'registrants_confirmed' and r.status = 'confirmed'
    union select r.user_id from public.attendee_registrations r
      where r.edition_year = p_year and p_segment = 'registrants_active' and r.status in ('applied','confirmed')
    union select p.owner_id from public.papers p
      where p.edition_year = p_year and p_segment = 'authors_submitted'
        and p.status in ('submitted','under_review','revision','accepted','rejected')
    union select p.owner_id from public.papers p
      where p.edition_year = p_year and p_segment = 'authors_accepted' and p.status = 'accepted'
    union select p.owner_id from public.papers p
      where p.edition_year = p_year and p_segment = 'authors_draft' and p.status = 'draft'
        and not exists (select 1 from public.papers s where s.owner_id = p.owner_id and s.edition_year = p_year and s.status <> 'draft')
    union select v.reviewer_id from public.reviews v join public.papers p on p.id = v.paper_id
      where p.edition_year = p_year and p_segment = 'reviewers_active'
        and v.revoked_at is null and v.review_state <> 'declined' and p.status <> 'withdrawn'
    union select c.user_id from public.marketing_consents c
      where p_segment = 'marketing_consented' and c.consented and c.consented_at > now() - interval '2 years'
  )
  select u.id, lower(u.email), coalesce(nullif(btrim(pr.full_name), ''), '회원')
  from members m
  join auth.users u on u.id = m.user_id and u.email_confirmed_at is not null
  left join public.profiles pr on pr.user_id = u.id
  where lower(u.email) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' and char_length(u.email) <= 254
    and not exists (select 1 from app_private.email_suppressions s where s.email = lower(u.email));
$$;

-- Promotional payloads carry the consent date and the recipient's unsubscribe token.
create or replace function app_private.announcement_payload(a app_private.announcements, p_email text, p_name text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('version', 6, 'kind', 'announcement', 'recipient', p_email,
    'recipientName', left(p_name, 120), 'editionYear', a.edition_year,
    'conferenceTitle', coalesce((select title from public.conference_editions where year = a.edition_year), 'Co-R&BD Conference'),
    'subject', btrim(a.subject), 'body', btrim(a.body), 'note', '')
  || case when a.segment = 'marketing_consented' then jsonb_strip_nulls(jsonb_build_object('promotional', true,
       'consentedAt', (select to_char(c.consented_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
         from public.marketing_consents c join auth.users u on u.id = c.user_id where lower(u.email) = p_email and c.consented),
       'unsubscribeToken', (select c.unsubscribe_token::text
         from public.marketing_consents c join auth.users u on u.id = c.user_id where lower(u.email) = p_email and c.consented)))
     else '{}'::jsonb end;
$$;

-- Promotional mail must be confirmed so the queue finishes between 08:00 and 21:00 KST (2 mails/minute, 30 min margin).
create or replace function public.chair_announcement_confirm(p_id uuid, p_expected_count integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare a app_private.announcements; n integer; local timestamp; finish timestamp;
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  select * into a from app_private.announcements where id = p_id for update;
  if not found then raise exception 'Announcement not found' using errcode = 'P0002'; end if;
  if a.confirmed_at is not null or a.cancelled_at is not null then
    raise exception 'Announcement already confirmed or cancelled' using errcode = '55000';
  end if;
  if a.test_sent_at is null then raise exception 'Send a test to yourself first' using errcode = '55000'; end if;
  if a.edition_year <> app_private.current_edition_year() then
    raise exception 'Announcement belongs to another edition' using errcode = '55000';
  end if;
  select count(*) into n from app_private.announcement_recipients(a.segment, a.edition_year);
  if n <> p_expected_count then
    raise exception 'Recipient count changed: % now', n using errcode = '40001';
  end if;
  if n < 1 or n > 2000 then raise exception 'Recipient count must be 1–2000' using errcode = '22023'; end if;
  if a.segment = 'marketing_consented' then
    local := now() at time zone 'Asia/Seoul';
    finish := local + make_interval(mins => ceil(n / 2.0)::integer + 30);
    if local::time < time '08:00' or finish::date <> local::date or finish::time > time '21:00' then
      raise exception 'Promotional mail must finish between 08:00 and 21:00 KST' using errcode = '55000';
    end if;
  end if;
  insert into app_private.review_email_outbox(event_key, announcement_id, recipient_id, recipient_email, kind, payload)
    select 'announcement:' || a.id || ':' || r.user_id, a.id, r.user_id, r.email, 'announcement',
      app_private.announcement_payload(a, r.email, r.full_name)
    from app_private.announcement_recipients(a.segment, a.edition_year) r
    on conflict (event_key) do nothing;
  update app_private.announcements set confirmed_at = now(), confirmed_by = auth.uid(), recipient_count = n where id = a.id;
  return n;
end; $$;
