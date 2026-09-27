-- Keep the profiles foreign key efficient after registration uniqueness became per edition.
create index attendee_registrations_user_id_idx
  on public.attendee_registrations (user_id);
