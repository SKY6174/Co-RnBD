-- Preserve the chair role used by deployed clients and add an explicit
-- super admin marker that only the database operator can assign.
do $$
begin
  if (select count(*) from auth.users
      where lower(email) in ('kysong@uc.ac.kr', 'song.kyoung.young@gmail.com')
        and email_confirmed_at is not null) <> 2 then
    raise exception 'Both verified super admin accounts must exist';
  end if;
end;
$$;

alter table public.staff_roles
  add column is_super_admin boolean not null default false;

insert into public.staff_roles (user_id, role, is_super_admin)
select id, 'chair', true from auth.users
where lower(email) in ('kysong@uc.ac.kr', 'song.kyoung.young@gmail.com')
  and email_confirmed_at is not null
on conflict (user_id) do update
  set role = excluded.role, is_super_admin = excluded.is_super_admin;
