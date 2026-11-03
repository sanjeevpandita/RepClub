-- 17: Gym members (Monthly Pass) with or without a coach. Re-runnable.
-- Run AFTER 01-16 in the Supabase SQL Editor.
--  * package_types.kind / member_packages.kind: CREDITS (coach sessions, credit per visit) or PASS
--    (unlimited gym visits, no credits). A member may have ONE active package PER KIND.
--  * app_settings.gym_capacity (default 7): max MEMBERS in the gym in one hour. Counts gym bookings
--    AND coached-session bookings. Coaches do not count.
--  * gym_bookings: a member with a valid PASS must book a gym hour. Refused when the hour is full.
--    One booking (gym OR coached) per member per day.
--  * gym_qr: the secret in the QR code at the door (admin-only to read). gym_check_in() works only
--    inside the booked hour (checkin_minutes_before until the end of the hour).
--  * gym_hours / gym_presence: hours with places taken, and who is booked / checked in (first name + initial).

-- ---------- 1. Package kinds ----------------------------------------------
alter table package_types  add column if not exists kind text not null default 'CREDITS';
alter table member_packages add column if not exists kind text not null default 'CREDITS';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'package_types_kind_check') then
    alter table package_types add constraint package_types_kind_check check (kind in ('CREDITS', 'PASS'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'member_packages_kind_check') then
    alter table member_packages add constraint member_packages_kind_check check (kind in ('CREDITS', 'PASS'));
  end if;
end $$;

-- the old "credits > 0" rule is replaced: CREDITS need credits, a PASS has none
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'package_types'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%credits > 0%' loop
    execute format('alter table package_types drop constraint %I', c.conname);
  end loop;
end $$;
alter table package_types drop constraint if exists package_types_credits_kind;
alter table package_types add constraint package_types_credits_kind
  check ((kind = 'PASS' and credits = 0) or (kind = 'CREDITS' and credits > 0));

-- one ACTIVE package per member PER KIND
drop index if exists one_active_package_per_member;
create unique index if not exists one_active_package_per_member_kind
  on member_packages (member_id, kind) where status = 'ACTIVE';

-- view with the kind (new column goes last)
create or replace view member_package_balances with (security_invoker = true) as
select mp.id as member_package_id, mp.member_id, mp.status, mp.expiry_date,
       coalesce(sum(ct.delta), 0)::int as credits_remaining, mp.kind
from member_packages mp
left join credit_transactions ct on ct.member_package_id = mp.id
group by mp.id;

-- ---------- 2. Settings and the door QR -----------------------------------
alter table app_settings add column if not exists gym_capacity int not null default 7;
alter table app_settings drop constraint if exists app_settings_gym_capacity_check;
alter table app_settings add constraint app_settings_gym_capacity_check check (gym_capacity > 0);

create table if not exists gym_qr (
  id     boolean primary key default true check (id),
  token  uuid not null default gen_random_uuid()
);
insert into gym_qr default values on conflict do nothing;
alter table gym_qr enable row level security;
drop policy if exists admin_read on gym_qr;
create policy admin_read on gym_qr for select to authenticated using (is_admin());

create or replace function admin_regenerate_gym_qr() returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform _require_admin();
  update gym_qr set token = gen_random_uuid() returning token into v;
  perform _audit('GYM_QR_REGENERATED', 'gym_qr', 'true', null, null, null, null);
  return v;
end $$;

-- ---------- 3. Gym bookings -----------------------------------------------
create table if not exists gym_bookings (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references member_profiles (id),
  hour_start     timestamptz not null,
  booking_date   date not null,
  status         booking_status not null default 'BOOKED',
  checked_in_at  timestamptz,
  created_by     uuid references profiles (id),
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancelled_by   uuid references profiles (id),
  check (extract(epoch from hour_start)::bigint % 3600 = 0)
);
create index if not exists gym_bookings_hour on gym_bookings (hour_start);
create index if not exists gym_bookings_member on gym_bookings (member_id, booking_date);
create unique index if not exists one_gym_booking_per_member_day on gym_bookings (member_id, booking_date)
  where status in ('BOOKED', 'ATTENDED', 'NO_SHOW');

alter table gym_bookings enable row level security;
drop policy if exists read_gym_bookings on gym_bookings;
create policy read_gym_bookings on gym_bookings for select to authenticated using (
  member_id = auth.uid() or is_admin() or coach_has_member(member_id));
revoke insert, update, delete on gym_bookings from authenticated;
revoke all on gym_bookings, gym_qr from anon;
drop trigger if exists audit on gym_bookings;
create trigger audit after insert or update or delete on gym_bookings for each row execute function audit_row();

-- ---------- 4. Helpers ----------------------------------------------------
create or replace function _has_valid_pass(p_member uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from member_packages
                  where member_id = p_member and kind = 'PASS' and status = 'ACTIVE'
                    and p_day between start_date and expiry_date)
$$;

-- members (not coaches) in the gym in this hour: gym bookings + coached-session bookings
create or replace function _members_in_hour(p_hour timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select (select count(*) from gym_bookings where hour_start = p_hour and status <> 'CANCELLED')::int
       + (select count(*) from bookings b join slots s on s.id = b.slot_id
           where s.starts_at = p_hour and not s.is_cancelled and b.status <> 'CANCELLED')::int
$$;

create or replace function _short_name(p_name text) returns text
language sql immutable as $$
  select case
    when array_length(regexp_split_to_array(trim(p_name), '\s+'), 1) > 1
    then (regexp_split_to_array(trim(p_name), '\s+'))[1] || ' ' ||
         upper(left((regexp_split_to_array(trim(p_name), '\s+'))[array_length(regexp_split_to_array(trim(p_name), '\s+'), 1)], 1))
    else trim(p_name) end
$$;

-- ---------- 5. Packages: one active per kind ------------------------------
create or replace function _activate_package(p_pkg uuid, p_actor uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pkg member_packages;
begin
  select * into pkg from member_packages where id = p_pkg for update;
  if not found then raise exception 'Package not found'; end if;
  if pkg.status <> 'QUEUED' then raise exception 'Only a queued package can be activated (this one is %)', pkg.status; end if;
  if exists (select 1 from member_packages where member_id = pkg.member_id and status = 'ACTIVE' and kind = pkg.kind) then
    raise exception 'The member already has an active % package. This one stays queued until it is finished.',
      case pkg.kind when 'PASS' then 'Monthly Pass' else 'credit' end;
  end if;
  if pkg.expiry_date < _gym_today() then raise exception 'This package has already expired'; end if;

  update member_packages set status = 'ACTIVE', activated_at = now(), activated_by = p_actor where id = p_pkg;
  if pkg.kind = 'CREDITS' then
    insert into credit_transactions (member_id, member_package_id, type, delta, created_by)
    values (pkg.member_id, pkg.id, 'PACKAGE_START', pkg.starting_credits, p_actor);
  end if;
end $$;

create or replace function _activate_next(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid; k text;
begin
  foreach k in array array['CREDITS', 'PASS'] loop
    if exists (select 1 from member_packages where member_id = p_member and status = 'ACTIVE' and kind = k) then continue; end if;
    select id into v from member_packages
     where member_id = p_member and status = 'QUEUED' and kind = k
       and start_date <= _gym_today() and expiry_date >= _gym_today()
     order by start_date, created_at limit 1;
    if found then perform _activate_package(v, null); end if;
  end loop;
end $$;

create or replace function _consume_credit(p_member uuid, p_type credit_txn_type, p_booking uuid,
                                           p_date date, p_actor uuid, p_strict boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare pkg member_packages; v_id bigint;
begin
  select * into pkg from member_packages where member_id = p_member and status = 'ACTIVE' and kind = 'CREDITS' for update;
  if not found or _balance(pkg.id) < 1 then
    if p_strict then raise exception 'Member has no active package with credits left'; end if;
    return null;
  end if;
  insert into credit_transactions (member_id, member_package_id, type, delta, booking_id, attendance_date, created_by)
  values (p_member, pkg.id, p_type, -1, p_booking, p_date, p_actor) returning id into v_id;
  if _balance(pkg.id) = 0 then
    update member_packages set status = 'EXHAUSTED' where id = pkg.id;
    perform _activate_next(p_member);
  end if;
  return v_id;
end $$;

create or replace function _reverse_credit(p_txn bigint, p_reason reason_code, p_note text, p_actor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t credit_transactions;
begin
  select * into t from credit_transactions where id = p_txn for update;
  insert into credit_transactions (member_id, member_package_id, type, delta, reason_code, note, booking_id, attendance_date, created_by)
  values (t.member_id, t.member_package_id, 'REVERSAL', -t.delta, p_reason, p_note, t.booking_id, t.attendance_date, p_actor);
  update credit_transactions set is_void = true where id = p_txn;
  if exists (select 1 from member_packages where id = t.member_package_id and status = 'EXHAUSTED' and expiry_date >= _gym_today())
     and not exists (select 1 from member_packages where member_id = t.member_id and status = 'ACTIVE' and kind = 'CREDITS') then
    update member_packages set status = 'ACTIVE' where id = t.member_package_id;
  end if;
end $$;

create or replace function admin_assign_package(
  p_member uuid, p_package_type uuid, p_purchase_date date, p_start_date date, p_expiry_date date,
  p_starting_credits int, p_payment_note text default null, p_activate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare pt package_types; v_id uuid; v_credits int;
begin
  if not (is_admin() or coach_has_member(p_member)) then
    raise exception 'Only the admin or the member''s own coach can assign a package';
  end if;
  select * into pt from package_types where id = p_package_type;
  if not found then raise exception 'Package type not found'; end if;
  if pt.kind = 'PASS' then
    v_credits := 0;
  else
    if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
    v_credits := p_starting_credits;
  end if;
  insert into member_packages (member_id, package_type_id, package_name, kind, purchase_date, start_date,
                               expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, pt.kind, p_purchase_date, p_start_date,
          p_expiry_date, v_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

create or replace function admin_adjust_credits(p_member uuid, p_delta int, p_reason reason_code, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare pkg member_packages; old_bal int; new_bal int;
begin
  perform _require_admin();
  if p_delta = 0 then raise exception 'Adjustment cannot be zero'; end if;
  perform _check_reason(p_reason, p_note);

  select * into pkg from member_packages where member_id = p_member and status = 'ACTIVE' and kind = 'CREDITS' for update;
  if not found then
    select * into pkg from member_packages
     where member_id = p_member and kind = 'CREDITS' and status = 'EXHAUSTED' and expiry_date >= _gym_today()
     order by activated_at desc nulls last limit 1 for update;
  end if;
  if not found then raise exception 'Member has no active credit package to adjust'; end if;

  old_bal := _balance(pkg.id);
  new_bal := old_bal + p_delta;
  if new_bal < 0 then raise exception 'Balance cannot go below zero (current balance %)', old_bal; end if;

  insert into credit_transactions (member_id, member_package_id, type, delta, reason_code, note, created_by)
  values (p_member, pkg.id, 'ADMIN_ADJUSTMENT', p_delta, p_reason, p_note, auth.uid());

  if new_bal = 0 and pkg.status = 'ACTIVE' then
    update member_packages set status = 'EXHAUSTED' where id = pkg.id;
    perform _activate_next(p_member);
  elsif new_bal > 0 and pkg.status = 'EXHAUSTED' then
    update member_packages set status = 'ACTIVE' where id = pkg.id;
  end if;

  perform _audit('CREDIT_ADJUSTMENT', 'member_packages', pkg.id::text,
                 jsonb_build_object('balance', old_bal), jsonb_build_object('balance', new_bal), p_reason, p_note);
  return new_bal;
end $$;

-- A never-activated package (queued, no ledger rows) is deleted; any other is marked CANCELLED.
create or replace function admin_cancel_package(p_package uuid, p_reason reason_code, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare pkg member_packages; bal int; was_active boolean;
begin
  select * into pkg from member_packages where id = p_package for update;
  if not found then raise exception 'Package not found'; end if;
  if not (is_admin() or coach_has_member(pkg.member_id)) then
    raise exception 'Only the admin or the member''s own coach can cancel a package';
  end if;
  perform _check_reason(p_reason, p_note);
  if pkg.status = 'CANCELLED' then raise exception 'This package is already cancelled'; end if;
  if pkg.status = 'EXPIRED' then raise exception 'An expired package is history and cannot be cancelled'; end if;

  if pkg.status = 'QUEUED' and not exists (select 1 from credit_transactions where member_package_id = pkg.id) then
    delete from member_packages where id = pkg.id;
    perform _audit('PACKAGE_DELETED', 'member_packages', pkg.id::text,
                   jsonb_build_object('package', pkg.package_name, 'member', pkg.member_id), null, p_reason, p_note);
    return 'deleted';
  end if;

  was_active := pkg.status = 'ACTIVE';
  bal := _balance(pkg.id);
  if bal > 0 then
    insert into credit_transactions (member_id, member_package_id, type, delta, reason_code, note, created_by)
    values (pkg.member_id, pkg.id, 'ADMIN_ADJUSTMENT', -bal, p_reason,
            coalesce(nullif(trim(p_note), ''), 'Package cancelled'), auth.uid());
  end if;
  update member_packages set status = 'CANCELLED' where id = pkg.id;
  if was_active then perform _activate_next(pkg.member_id); end if;
  perform _audit('PACKAGE_CANCELLED', 'member_packages', pkg.id::text,
                 jsonb_build_object('balance', bal), null, p_reason, p_note);
  return 'cancelled';
end $$;

-- ---------- 6. Coach-session bookings use the CREDITS package only --------
create or replace function bookings_check() returns trigger
language plpgsql as $$
declare s slots; tz text; taken int; coach uuid;
begin
  select * into s from slots where id = new.slot_id for update;
  select gym_timezone into tz from app_settings;
  new.booking_date := (s.starts_at at time zone tz)::date;

  if new.status <> 'CANCELLED'
     and (tg_op = 'INSERT' or new.slot_id is distinct from old.slot_id or old.status = 'CANCELLED') then
    if s.is_cancelled then
      raise exception 'This session has been cancelled';
    end if;
    select primary_coach_id into coach from member_profiles where id = new.member_id;
    if coach is distinct from s.coach_id then
      raise exception 'Member can only book their own coach''s sessions';
    end if;
    if exists (select 1 from gym_bookings where member_id = new.member_id and booking_date = new.booking_date
                  and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
      raise exception 'This member already has a gym booking on that day';
    end if;
    select count(*) into taken from bookings
      where slot_id = new.slot_id and status <> 'CANCELLED' and id <> new.id;
    if taken >= s.capacity then
      raise exception 'This session is full';
    end if;
  end if;
  return new;
end $$;

create or replace function create_booking(p_slot uuid, p_member uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_member uuid; s slots; pkg member_packages; d date; v_id uuid; committed int; tz text;
begin
  if is_admin() then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
  elsif app_role() = 'COACH' then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
    if not coach_has_member(v_member) then raise exception 'This is not your member'; end if;
  elsif app_role() = 'MEMBER' then
    v_member := auth.uid();
    if not (select can_self_book from member_profiles where id = v_member) then
      raise exception 'Your coach books your sessions. Please ask your coach.';
    end if;
  else
    raise exception 'Not allowed';
  end if;
  if not exists (select 1 from profiles where id = v_member and role = 'MEMBER' and is_active) then
    raise exception 'This member account is not active';
  end if;

  select * into s from slots where id = p_slot;
  if not found then raise exception 'Session not found'; end if;
  if s.starts_at <= now() then raise exception 'This session has already started'; end if;

  select gym_timezone into tz from app_settings;
  d := (s.starts_at at time zone tz)::date;

  select * into pkg from member_packages where member_id = v_member and status = 'ACTIVE' and kind = 'CREDITS';
  if not found then raise exception 'No active credit package'; end if;
  if d < pkg.start_date or d > pkg.expiry_date then
    raise exception 'The active package is not valid on %', d;
  end if;
  select count(*) into committed from bookings where member_id = v_member and status = 'BOOKED';
  if _balance(pkg.id) - committed < 1 then
    raise exception 'All remaining credits are already booked';
  end if;

  insert into bookings (member_id, slot_id, booking_date, created_by)
  values (v_member, p_slot, d, auth.uid()) returning id into v_id;
  return v_id;
end $$;

create or replace function reschedule_booking(p_booking uuid, p_new_slot uuid,
                                              p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; ns slots; locked boolean; pkg member_packages; tz text; nd date;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid() or coach_has_member(b.member_id)) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be rescheduled'; end if;

  select * into s from slots where id = b.slot_id;
  select now() > s.starts_at - make_interval(hours => cancel_lock_hours) into locked from app_settings;
  if locked then
    if not is_admin() then
      raise exception 'This session starts within 12 hours, so it can no longer be moved. Please contact the gym.';
    end if;
    perform _check_reason(p_reason, p_note);
    perform _audit('RESCHEDULE_INSIDE_LOCK', 'bookings', b.id::text, null, null, p_reason, p_note);
  end if;

  select * into ns from slots where id = p_new_slot;
  if not found then raise exception 'New session not found'; end if;
  if ns.starts_at <= now() then raise exception 'The new session has already started'; end if;
  select gym_timezone into tz from app_settings;
  nd := (ns.starts_at at time zone tz)::date;
  select * into pkg from member_packages where member_id = b.member_id and status = 'ACTIVE' and kind = 'CREDITS';
  if not found or nd < pkg.start_date or nd > pkg.expiry_date then
    raise exception 'The active package is not valid on %', nd;
  end if;

  update bookings set slot_id = p_new_slot where id = p_booking;
end $$;

-- ---------- 7. Gym hours: book, cancel, check in --------------------------
create or replace function book_gym_hour(p_hour timestamptz, p_member uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_member uuid; s app_settings; d date; t time; open_day boolean; n int; v_id uuid;
begin
  if is_admin() then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
  elsif app_role() = 'COACH' then
    v_member := p_member;
    if v_member is null or not coach_has_member(v_member) then raise exception 'This is not your member'; end if;
  elsif app_role() = 'MEMBER' then
    v_member := auth.uid();
  else
    raise exception 'Not allowed';
  end if;
  if not exists (select 1 from profiles where id = v_member and role = 'MEMBER' and is_active) then
    raise exception 'This member account is not active';
  end if;

  select * into s from app_settings;
  if extract(epoch from p_hour)::bigint % 3600 <> 0 then raise exception 'Choose a full hour'; end if;
  if p_hour + interval '1 hour' <= now() then raise exception 'This hour is already over'; end if;
  d := (p_hour at time zone s.gym_timezone)::date;
  t := (p_hour at time zone s.gym_timezone)::time;
  select coalesce((select is_open from gym_day_overrides where day = d),
                  extract(isodow from d)::smallint = any (s.open_weekdays)) into open_day;
  if not open_day then raise exception 'The gym is closed on %', d; end if;
  if t < s.open_time or t > s.close_time - interval '1 hour' then raise exception 'That hour is outside opening hours'; end if;

  if not _has_valid_pass(v_member, d) then raise exception 'A valid Monthly Pass is needed to book gym time on %', d; end if;
  if exists (select 1 from gym_bookings where member_id = v_member and booking_date = d
               and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
    raise exception 'You already have a gym booking on that day';
  end if;
  if exists (select 1 from bookings where member_id = v_member and booking_date = d
               and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
    raise exception 'You already have a coached session on that day';
  end if;

  perform pg_advisory_xact_lock(hashtext('gym-hour-' || p_hour::text));
  n := _members_in_hour(p_hour);
  if n >= s.gym_capacity then
    raise exception 'The gym is full at this time (% of % places taken)', n, s.gym_capacity;
  end if;

  insert into gym_bookings (member_id, hour_start, booking_date, created_by)
  values (v_member, p_hour, d, auth.uid()) returning id into v_id;
  return v_id;
end $$;

create or replace function cancel_gym_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b gym_bookings;
begin
  select * into b from gym_bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid() or coach_has_member(b.member_id)) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked hour can be cancelled (this one is %)', b.status; end if;
  if b.hour_start <= now() then raise exception 'This hour has already started'; end if;
  update gym_bookings set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid() where id = p_booking;
end $$;

-- Member scans the QR at the door. p_token is the secret inside it.
create or replace function gym_check_in(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid := auth.uid(); today date; tz text; b gym_bookings; opens timestamptz;
begin
  if app_role() is distinct from 'MEMBER' then raise exception 'Only members can check in'; end if;
  if not exists (select 1 from gym_qr where token = p_token) then raise exception 'This QR code is not valid'; end if;
  select gym_timezone into tz from app_settings;
  today := _gym_today();
  if not _has_valid_pass(v_member, today) then raise exception 'You need a valid Monthly Pass to use the gym'; end if;

  select * into b from gym_bookings
   where member_id = v_member and booking_date = today and status in ('BOOKED', 'ATTENDED')
   order by created_at desc limit 1 for update;
  if not found then raise exception 'You have no gym booking for today'; end if;
  if b.status = 'ATTENDED' then raise exception 'You are already checked in today'; end if;

  opens := b.hour_start - make_interval(mins => (select checkin_minutes_before from app_settings));
  if now() < opens then raise exception 'Check-in opens at %', to_char(opens at time zone tz, 'HH24:MI'); end if;
  if now() > b.hour_start + interval '1 hour' then
    raise exception 'Check-in closed at %', to_char((b.hour_start + interval '1 hour') at time zone tz, 'HH24:MI');
  end if;

  update gym_bookings set status = 'ATTENDED', checked_in_at = now() where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'checked_in_at', now(), 'hour_start', b.hour_start);
end $$;

-- Hours that can still be booked in a range, with places taken and the caller's own booking
create or replace function gym_hours(p_from timestamptz, p_to timestamptz)
returns table (hour_start timestamptz, taken int, capacity int, my_booking uuid, my_status text)
language plpgsql stable security definer set search_path = public as $$
declare s app_settings;
begin
  if app_role() is null then raise exception 'Not allowed'; end if;
  select * into s from app_settings;
  return query
  select h.hs, _members_in_hour(h.hs), s.gym_capacity, gb.id, gb.status::text
  from (
    select ((g.dts + make_time(hr, 0, 0)) at time zone s.gym_timezone) as hs
    from generate_series((p_from at time zone s.gym_timezone)::date::timestamp,
                         (p_to at time zone s.gym_timezone)::date::timestamp, interval '1 day') as g(dts)
    cross join generate_series(extract(hour from s.open_time)::int, extract(hour from s.close_time)::int - 1) as hr
    where coalesce((select o.is_open from gym_day_overrides o where o.day = g.dts::date),
                   extract(isodow from g.dts)::smallint = any (s.open_weekdays))
  ) h
  left join gym_bookings gb on gb.hour_start = h.hs and gb.member_id = auth.uid() and gb.status in ('BOOKED', 'ATTENDED')
  where h.hs >= p_from and h.hs < p_to and h.hs + interval '1 hour' > now()
  order by h.hs;
end $$;

-- Who is in the gym in one hour (gym members and coached members), first name + initial
create or replace function gym_presence(p_hour timestamptz)
returns table (who text, state text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_admin() or (app_role() = 'MEMBER' and _has_valid_pass(auth.uid(), _gym_today()))) then
    raise exception 'Only gym members with a Monthly Pass can see who is in the gym';
  end if;
  return query
  select _short_name(p.full_name), case x.status when 'ATTENDED' then 'CHECKED_IN' else 'BOOKED' end
  from (
    select member_id, status from gym_bookings
     where hour_start = p_hour and status in ('BOOKED', 'ATTENDED')
    union all
    select b.member_id, b.status from bookings b join slots sl on sl.id = b.slot_id
     where sl.starts_at = p_hour and not sl.is_cancelled and b.status in ('BOOKED', 'ATTENDED')
  ) x
  join profiles p on p.id = x.member_id
  order by 2 desc, 1;
end $$;

-- ---------- 8. Nightly job: also mark missed gym hours ---------------------
create or replace function run_reconciliation() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n_noshow int := 0; n_expired int := 0; n_gym int := 0; bal int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;

  for r in select b.id, b.member_id, b.booking_date from bookings b join slots s on s.id = b.slot_id
            where b.status = 'BOOKED' and s.ends_at < now() for update of b loop
    update bookings set status = 'NO_SHOW' where id = r.id;
    perform _consume_credit(r.member_id, 'NO_SHOW', r.id, r.booking_date, null, false);
    n_noshow := n_noshow + 1;
  end loop;

  update gym_bookings set status = 'NO_SHOW' where status = 'BOOKED' and hour_start + interval '1 hour' < now();
  get diagnostics n_gym = row_count;

  for r in select id, member_id, status from member_packages
            where status in ('ACTIVE', 'EXHAUSTED', 'QUEUED') and expiry_date < _gym_today() for update loop
    bal := _balance(r.id);
    if bal > 0 then
      insert into credit_transactions (member_id, member_package_id, type, delta, note)
      values (r.member_id, r.id, 'EXPIRY', -bal, 'Package expired');
    end if;
    update member_packages set status = 'EXPIRED' where id = r.id;
    n_expired := n_expired + 1;
  end loop;

  for r in select distinct member_id from member_packages where status = 'QUEUED' loop
    perform _activate_next(r.member_id);
  end loop;

  return jsonb_build_object('no_shows', n_noshow, 'gym_no_shows', n_gym, 'packages_expired', n_expired);
end $$;

-- ---------- 9. Who may call what ------------------------------------------
revoke execute on function _has_valid_pass(uuid, date), _members_in_hour(timestamptz), _short_name(text) from public, anon, authenticated;
revoke execute on function admin_regenerate_gym_qr(), book_gym_hour(timestamptz, uuid), cancel_gym_booking(uuid),
  gym_check_in(uuid), gym_hours(timestamptz, timestamptz), gym_presence(timestamptz) from public, anon;
grant  execute on function admin_regenerate_gym_qr(), book_gym_hour(timestamptz, uuid), cancel_gym_booking(uuid),
  gym_check_in(uuid), gym_hours(timestamptz, timestamptz), gym_presence(timestamptz) to authenticated;

notify pgrst, 'reload schema';
