-- Chair-approved operational announcements sent through the existing outbox.
-- Nothing is sent until a chair saves, test-sends and confirms an announcement.

create table app_private.announcements (
  id uuid primary key default gen_random_uuid(),
  edition_year integer not null,
  segment text not null check (segment in ('registrants_confirmed','registrants_active','authors_submitted','authors_accepted','authors_draft','reviewers_active')),
  subject text not null check (char_length(btrim(subject)) between 2 and 120 and subject !~ '[\r\n]'),
  body text not null check (char_length(btrim(body)) between 10 and 5000),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  test_sent_at timestamptz,
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  recipient_count integer,
  cancelled_at timestamptz
);
create index announcements_year_idx on app_private.announcements(edition_year, created_at desc);
alter table app_private.announcements enable row level security;
revoke all on app_private.announcements from public, anon, authenticated;

alter table app_private.review_email_outbox
  add column announcement_id uuid references app_private.announcements(id) on delete set null;
create index review_email_announcement_idx on app_private.review_email_outbox(announcement_id) where announcement_id is not null;
alter table app_private.review_email_outbox drop constraint review_email_outbox_kind_check;
alter table app_private.review_email_outbox add constraint review_email_outbox_kind_check
  check (kind in ('reviewer_assignment','decision','review_submitted','paper_submitted','paper_resubmitted',
    'author_submission_receipt','author_resubmission_receipt','registration_received','registration_confirmed',
    'registration_cancelled','announcement'));

-- Verified accounts in a fixed group for one edition: one row per account, suppressed addresses excluded.
create function app_private.announcement_recipients(p_segment text, p_year integer)
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
  )
  select u.id, lower(u.email), coalesce(nullif(btrim(pr.full_name), ''), '회원')
  from members m
  join auth.users u on u.id = m.user_id and u.email_confirmed_at is not null
  left join public.profiles pr on pr.user_id = u.id
  where lower(u.email) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' and char_length(u.email) <= 254
    and not exists (select 1 from app_private.email_suppressions s where s.email = lower(u.email));
$$;
revoke all on function app_private.announcement_recipients(text, integer) from public, anon, authenticated;

create function app_private.announcement_payload(a app_private.announcements, p_email text, p_name text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('version', 6, 'kind', 'announcement', 'recipient', p_email,
    'recipientName', left(p_name, 120), 'editionYear', a.edition_year,
    'conferenceTitle', coalesce((select title from public.conference_editions where year = a.edition_year), 'Co-R&BD Conference'),
    'subject', btrim(a.subject), 'body', btrim(a.body), 'note', '');
$$;
revoke all on function app_private.announcement_payload(app_private.announcements, text, text) from public, anon, authenticated;

create function public.chair_announcement_preview(p_segment text)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  return (select count(*) from app_private.announcement_recipients(p_segment, app_private.current_edition_year()));
end; $$;

create function public.chair_announcement_save(p_id uuid, p_segment text, p_subject text, p_body text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare a app_private.announcements;
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  if p_id is null then
    insert into app_private.announcements(edition_year, segment, subject, body, created_by)
      values (app_private.current_edition_year(), p_segment, btrim(p_subject), btrim(p_body), auth.uid())
      returning * into a;
    return a.id;
  end if;
  select * into a from app_private.announcements where id = p_id for update;
  if not found then raise exception 'Announcement not found' using errcode = 'P0002'; end if;
  if a.confirmed_at is not null or a.cancelled_at is not null then
    raise exception 'Confirmed or cancelled announcements cannot be edited' using errcode = '55000';
  end if;
  update app_private.announcements set segment = p_segment, subject = btrim(p_subject), body = btrim(p_body),
    updated_at = now(),
    test_sent_at = case when (segment, subject, body) is not distinct from (p_segment, btrim(p_subject), btrim(p_body))
      then test_sent_at end
  where id = p_id;
  return p_id;
end; $$;

create function public.chair_announcement_test(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare a app_private.announcements; address text; who text;
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  select * into a from app_private.announcements where id = p_id for update;
  if not found then raise exception 'Announcement not found' using errcode = 'P0002'; end if;
  if a.confirmed_at is not null or a.cancelled_at is not null then
    raise exception 'Announcement already confirmed or cancelled' using errcode = '55000';
  end if;
  select lower(u.email), coalesce(nullif(btrim(pr.full_name), ''), '위원장') into address, who
    from auth.users u left join public.profiles pr on pr.user_id = u.id
    where u.id = auth.uid() and u.email_confirmed_at is not null;
  if address is null then raise exception 'Verified chair email required' using errcode = '55000'; end if;
  insert into app_private.review_email_outbox(event_key, announcement_id, recipient_id, recipient_email, kind, payload, is_test)
    values ('announcement-test:' || a.id || ':' || to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
      a.id, auth.uid(), address, 'announcement', app_private.announcement_payload(a, address, who), true);
  update app_private.announcements set test_sent_at = now() where id = a.id;
  return address;
end; $$;

create function public.chair_announcement_confirm(p_id uuid, p_expected_count integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare a app_private.announcements; n integer;
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
  insert into app_private.review_email_outbox(event_key, announcement_id, recipient_id, recipient_email, kind, payload)
    select 'announcement:' || a.id || ':' || r.user_id, a.id, r.user_id, r.email, 'announcement',
      app_private.announcement_payload(a, r.email, r.full_name)
    from app_private.announcement_recipients(a.segment, a.edition_year) r
    on conflict (event_key) do nothing;
  update app_private.announcements set confirmed_at = now(), confirmed_by = auth.uid(), recipient_count = n where id = a.id;
  return n;
end; $$;

create function public.chair_announcement_cancel(p_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  update app_private.announcements set cancelled_at = coalesce(cancelled_at, now()) where id = p_id;
  if not found then raise exception 'Announcement not found' using errcode = 'P0002'; end if;
  -- Pending test mails are cancelled too; the returned count is recipient mail only.
  with stopped as (
    update app_private.review_email_outbox set status = 'cancelled', last_error = 'announcement_cancelled'
      where announcement_id = p_id and status in ('queued','retry')
      returning is_test)
  select count(*) filter (where not is_test) into n from stopped;
  return n;
end; $$;

create function public.chair_announcements(p_limit integer default 20)
returns table(id uuid, segment text, subject text, body text, created_at timestamptz, updated_at timestamptz,
  test_sent_at timestamptz, confirmed_at timestamptz, cancelled_at timestamptz, recipient_count integer,
  pending integer, sent integer, delivered integer, bounced integer, complained integer, failed integer, cancelled integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_chair() then raise exception 'Chair permission required' using errcode = '42501'; end if;
  return query
    select a.id, a.segment, a.subject, a.body, a.created_at, a.updated_at, a.test_sent_at, a.confirmed_at, a.cancelled_at, a.recipient_count,
      count(o.id) filter (where o.status in ('queued','retry','sending'))::integer,
      count(o.id) filter (where o.status = 'sent')::integer,
      count(o.id) filter (where o.delivery_state = 'delivered')::integer,
      count(o.id) filter (where o.delivery_state = 'bounced')::integer,
      count(o.id) filter (where o.delivery_state = 'complained')::integer,
      count(o.id) filter (where o.status in ('failed','uncertain'))::integer,
      count(o.id) filter (where o.status = 'cancelled')::integer
    from app_private.announcements a
    left join app_private.review_email_outbox o on o.announcement_id = a.id and not o.is_test
    where a.edition_year = app_private.current_edition_year()
    group by a.id
    order by a.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100);
end; $$;

revoke all on function public.chair_announcement_preview(text), public.chair_announcement_save(uuid, text, text, text),
  public.chair_announcement_test(uuid), public.chair_announcement_confirm(uuid, integer),
  public.chair_announcement_cancel(uuid), public.chair_announcements(integer) from public, anon;
grant execute on function public.chair_announcement_preview(text), public.chair_announcement_save(uuid, text, text, text),
  public.chair_announcement_test(uuid), public.chair_announcement_confirm(uuid, integer),
  public.chair_announcement_cancel(uuid), public.chair_announcements(integer) to authenticated;
