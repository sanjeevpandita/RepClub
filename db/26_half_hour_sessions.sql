-- 26: 30-minute coach sessions (HIIT). Re-runnable. Run AFTER 01-25 (needs 15, 17, 19, 20).
--
-- Owner decisions (2026-11-15):
--  * A package type has a session length: 60 minutes (normal) or 30 minutes (HIIT package).
--    1 credit = 1 session of the package's length. The length is copied onto the member's package.
--  * A member with an active 30-minute package can only book 30-minute coach sessions; a member with
--    a normal package only 1-hour sessions. Same rule for coach and admin when they book for a member.
--  * Gym time (Monthly Pass) stays in whole hours. One booking per member per day still applies.
--
-- How it works: coaches keep their normal 1-hour sessions. When a 30-minute booking is made in a
-- free hour, that hour is split into two 30-minute sessions (hh:00 and hh:30); the booked half is
-- used, the other half stays open. When both halves are free again (cancel or move), they are joined
-- back into one hour. A booking keeps the length it was made with (moving keeps the same length).
-- A member in a 30-minute session counts towards the gym limit for that hour.

-- ---------- 1. Session length on packages ---------------------------------
alter table package_types   add column if not exists session_minutes int not null default 60;
alter table member_packages add column if not exists session_minutes int not null default 60;
alter table package_types   drop constraint if exists package_types_session_minutes_ok;
alter table package_types   add  constraint package_types_session_minutes_ok   check (session_minutes in (30, 60));
alter table member_packages drop constraint if exists member_packages_session_minutes_ok;
alter table member_packages add  constraint member_packages_session_minutes_ok check (session_minutes in (30, 60));

-- ---------- 2. Slots may be 1 hour (on the hour) or 30 minutes (on :00 or :30) ----
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'slots'::regclass and contype = 'c' and conname <> 'slots_length_ok'
              and (pg_get_constraintdef(oid) like '%01:00:00%' or pg_get_constraintdef(oid) like '%3600%') loop
    execute format('alter table slots drop constraint %I', c.conname);
  end loop;
end $$;
alter table slots drop constraint if exists slots_length_ok;
alter table slots add constraint slots_length_ok check (
     (ends_at = starts_at + interval '1 hour'     and extract(epoch from starts_at)::bigint % 3600 = 0)
  or (ends_at = starts_at + interval '30 minutes' and extract(epoch from starts_at)::bigint % 1800 = 0));

-- Opening hours now use the session's end time, and a coach cannot have two sessions that overlap.
create or replace function slots_check() returns trigger
language plpgsql as $$
declare s app_settings; t time; d date; open_day boolean;
begin
  select * into s from app_settings;
  t := (new.starts_at at time zone s.gym_timezone)::time;
  d := (new.starts_at at time zone s.gym_timezone)::date;
  select coalesce((select is_open from gym_day_overrides where day = d),
                  extract(isodow from d)::smallint = any (s.open_weekdays))
    into open_day;
  if not open_day then
    raise exception 'The gym is closed on %', d;
  end if;
  if t < s.open_time or t + (new.ends_at - new.starts_at) > s.close_time then
    raise exception 'Slot at % is outside opening hours (% - %)', t, s.open_time, s.close_time;
  end if;
  if exists (select 1 from coach_time_off o
              where o.coach_id = new.coach_id and d between o.start_date and o.end_date) then
    raise exception 'This coach is on time off on %', d;
  end if;
  if not new.is_cancelled and exists (
       select 1 from slots x
        where x.coach_id = new.coach_id and x.id <> new.id and not x.is_cancelled
          and x.starts_at < new.ends_at and x.ends_at > new.starts_at) then
    raise exception 'This coach already has a session at that time';
  end if;
  return new;
end $$;
drop trigger if exists slots_check on slots;
create trigger slots_check before insert or update of starts_at, ends_at on slots
  for each row execute function slots_check();

-- Weekly generation (also used by the Sunday job): skip an hour that already holds a session or a
-- split half of one.
create or replace function admin_generate_slots(p_from date, p_to date) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Choose a range of at most 62 days'; end if;

  with days as (select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d),
  wanted as (
    select w.coach_id,
           (days.day + make_time(w.hour, 0, 0)) at time zone s.gym_timezone as st,
           s.slot_capacity as cap
    from days
    cross join app_settings s
    join coach_weekly_schedule w on w.weekday = extract(isodow from days.day)
    join profiles p on p.id = w.coach_id and p.is_active
    where coalesce((select o.is_open from gym_day_overrides o where o.day = days.day),
                   extract(isodow from days.day)::smallint = any (s.open_weekdays))
      and make_time(w.hour, 0, 0) >= s.open_time
      and make_time(w.hour, 0, 0) <= s.close_time - interval '1 hour'
      and not exists (select 1 from coach_time_off t
                       where t.coach_id = w.coach_id and days.day between t.start_date and t.end_date))
  insert into slots (coach_id, starts_at, ends_at, capacity)
  select wanted.coach_id, wanted.st, wanted.st + interval '1 hour', wanted.cap
  from wanted
  where not exists (select 1 from slots x where x.coach_id = wanted.coach_id
                      and x.starts_at < wanted.st + interval '1 hour' and x.ends_at > wanted.st)
  on conflict (coach_id, starts_at) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- 3. Gym limit: count every coached session that overlaps the hour ----
create or replace function _members_in_hour(p_hour timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select (select count(*) from gym_bookings where hour_start = p_hour and status <> 'CANCELLED')::int
       + (select count(*) from bookings b join slots s on s.id = b.slot_id
           where s.starts_at < p_hour + interval '1 hour' and s.ends_at > p_hour
             and not s.is_cancelled and b.status <> 'CANCELLED')::int
$$;

create or replace function bookings_check() returns trigger
language plpgsql as $$
declare s slots; tz text; taken int; coach uuid; cap int; in_hour int; v_hour timestamptz;
begin
  select * into s from slots where id = new.slot_id for update;
  select gym_timezone, gym_capacity into tz, cap from app_settings;
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

    -- Same lock key as book_gym_hour (the hour the session is in), so bookings serialise per hour.
    v_hour := date_trunc('hour', s.starts_at);
    perform pg_advisory_xact_lock(hashtext('gym-hour-' || v_hour::text));
    in_hour := _members_in_hour(v_hour);
    if in_hour >= cap then
      raise exception 'The gym is full at this time (% of % places taken)', in_hour, cap;
    end if;
  end if;
  return new;
end $$;

create or replace function gym_presence(p_hour timestamptz)
returns table (who text, state text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_admin() or (app_role() = 'MEMBER' and _can_use_gym(auth.uid(), _gym_today()))) then
    raise exception 'Only gym members can see who is in the gym';
  end if;
  return query
  select _short_name(p.full_name), case x.status when 'ATTENDED' then 'CHECKED_IN' else 'BOOKED' end
  from (
    select member_id, status from gym_bookings
     where hour_start = p_hour and status in ('BOOKED', 'ATTENDED')
    union all
    select b.member_id, b.status from bookings b join slots sl on sl.id = b.slot_id
     where sl.starts_at < p_hour + interval '1 hour' and sl.ends_at > p_hour
       and not sl.is_cancelled and b.status in ('BOOKED', 'ATTENDED')
  ) x
  join profiles p on p.id = x.member_id
  order by 2 desc, 1;
end $$;

-- ---------- 4. Assigning a package copies its session length --------------
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
  if not pt.is_active then raise exception 'This package type is switched off and cannot be assigned'; end if;
  if pt.kind = 'PASS' then
    v_credits := 0;
  else
    if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
    v_credits := p_starting_credits;
  end if;
  insert into member_packages (member_id, package_type_id, package_name, kind, session_minutes, purchase_date,
                               start_date, expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, pt.kind,
          case when pt.kind = 'PASS' then 60 else pt.session_minutes end,
          p_purchase_date, p_start_date, p_expiry_date, v_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

-- ---------- 5. Split an hour / join two halves (internal helpers) ----------
-- Returns the 30-minute session starting at p_start inside p_slot, splitting a free hour if needed.
create or replace function _take_half(p_slot uuid, p_start timestamptz) returns uuid
language plpgsql security definer set search_path = public as $$
declare s slots; v_start timestamptz; v_tail uuid;
begin
  select * into s from slots where id = p_slot for update;
  if not found then raise exception 'Session not found'; end if;
  v_start := coalesce(p_start, s.starts_at);
  if s.ends_at - s.starts_at = interval '30 minutes' then
    if v_start <> s.starts_at then raise exception 'Choose a start time inside this session'; end if;
    return s.id;
  end if;
  if v_start not in (s.starts_at, s.starts_at + interval '30 minutes') then
    raise exception 'A 30-minute session starts on the hour or at half past';
  end if;
  if exists (select 1 from bookings where slot_id = s.id and status <> 'CANCELLED') then
    raise exception 'This session is full';
  end if;
  update slots set ends_at = s.starts_at + interval '30 minutes' where id = s.id;
  insert into slots (coach_id, starts_at, ends_at, capacity, is_cancelled)
  values (s.coach_id, s.starts_at + interval '30 minutes', s.ends_at, s.capacity, false)
  returning id into v_tail;
  if v_start = s.starts_at then return s.id; end if;
  return v_tail;
end $$;

-- If p_slot is one half of a split hour and both halves are free and in the future, join them again.
-- Cancelled bookings on the second half move to the joined session (they keep their history rows).
create or replace function _merge_halves(p_slot uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s slots; head slots; tail slots; h timestamptz;
begin
  select * into s from slots where id = p_slot;
  if not found or s.ends_at - s.starts_at <> interval '30 minutes' then return; end if;
  h := date_trunc('hour', s.starts_at);
  select * into head from slots where coach_id = s.coach_id and starts_at = h
     and ends_at = h + interval '30 minutes' for update;
  select * into tail from slots where coach_id = s.coach_id and starts_at = h + interval '30 minutes'
     and ends_at = h + interval '1 hour' for update;
  if head.id is null or tail.id is null then return; end if;
  if head.is_cancelled or tail.is_cancelled or head.starts_at <= now() then return; end if;
  if exists (select 1 from bookings where slot_id in (head.id, tail.id) and status <> 'CANCELLED') then
    return;
  end if;
  update bookings set slot_id = head.id where slot_id = tail.id;
  delete from slots where id = tail.id;
  update slots set ends_at = h + interval '1 hour' where id = head.id;
end $$;

-- ---------- 6. Book, move, cancel (length comes from the package) ----------
drop function if exists create_booking(uuid, uuid);
create or replace function create_booking(p_slot uuid, p_member uuid default null, p_start timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_member uuid; s slots; pkg member_packages; d date; v_id uuid; committed int; tz text;
        v_start timestamptz; v_slot uuid;
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
  if s.is_cancelled then raise exception 'This session has been cancelled'; end if;

  select * into pkg from member_packages where member_id = v_member and status = 'ACTIVE' and kind = 'CREDITS';
  if not found then raise exception 'No active credit package'; end if;

  if pkg.session_minutes = 30 then
    v_start := coalesce(p_start, s.starts_at);
  else
    if s.ends_at - s.starts_at <> interval '1 hour' then
      raise exception 'This is a 30-minute session. Your package is for 1-hour sessions.';
    end if;
    v_start := s.starts_at;
  end if;
  if v_start <= now() then raise exception 'This session has already started'; end if;

  select gym_timezone into tz from app_settings;
  d := (s.starts_at at time zone tz)::date;
  if d < pkg.start_date or d > pkg.expiry_date then
    raise exception 'The active package is not valid on %', d;
  end if;
  select count(*) into committed from bookings where member_id = v_member and status = 'BOOKED';
  if _balance(pkg.id) - committed < 1 then
    raise exception 'All remaining credits are already booked';
  end if;

  if pkg.session_minutes = 30 then v_slot := _take_half(s.id, v_start); else v_slot := s.id; end if;

  insert into bookings (member_id, slot_id, booking_date, created_by)
  values (v_member, v_slot, d, auth.uid()) returning id into v_id;   -- capacity, coach and one-per-day rules fire here
  return v_id;
end $$;

drop function if exists reschedule_booking(uuid, uuid, reason_code, text);
create or replace function reschedule_booking(p_booking uuid, p_new_slot uuid,
                                              p_reason reason_code default null, p_note text default null,
                                              p_new_start timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; ns slots; locked boolean; pkg member_packages; tz text; nd date;
        is_half boolean; v_start timestamptz; v_target uuid;
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
  if ns.is_cancelled then raise exception 'The new session has been cancelled'; end if;
  is_half := s.ends_at - s.starts_at = interval '30 minutes';
  if is_half then
    v_start := coalesce(p_new_start, ns.starts_at);
  else
    if ns.ends_at - ns.starts_at <> interval '1 hour' then
      raise exception 'That is a 30-minute session. This booking is for 1 hour.';
    end if;
    v_start := ns.starts_at;
  end if;
  if v_start <= now() then raise exception 'The new session has already started'; end if;

  select gym_timezone into tz from app_settings;
  nd := (ns.starts_at at time zone tz)::date;
  select * into pkg from member_packages where member_id = b.member_id and status = 'ACTIVE' and kind = 'CREDITS';
  if not found or nd < pkg.start_date or nd > pkg.expiry_date then
    raise exception 'The active package is not valid on %', nd;
  end if;

  if is_half then v_target := _take_half(ns.id, v_start); else v_target := ns.id; end if;
  if v_target = b.slot_id then raise exception 'This is already the booked session'; end if;

  update bookings set slot_id = v_target where id = p_booking;     -- capacity / coach / one-per-day rules fire here
  perform _merge_halves(s.id);
end $$;

create or replace function cancel_booking(p_booking uuid, p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; locked boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid() or coach_has_member(b.member_id)) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be cancelled (this one is %)', b.status; end if;
  select * into s from slots where id = b.slot_id;
  select now() > s.starts_at - make_interval(hours => cancel_lock_hours) into locked from app_settings;

  if locked then
    if not is_admin() then
      raise exception 'This session starts within 12 hours, so it can no longer be cancelled. Please contact the gym.';
    end if;
    perform _check_reason(p_reason, p_note);
    perform _audit('CANCEL_INSIDE_LOCK', 'bookings', b.id::text, null, null, p_reason, p_note);
  end if;

  update bookings set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid() where id = p_booking;
  perform _merge_halves(b.slot_id);
end $$;

-- ---------- 7. Who may call what ------------------------------------------
revoke execute on function _take_half(uuid, timestamptz), _merge_halves(uuid) from public, anon, authenticated;
revoke execute on function create_booking(uuid, uuid, timestamptz),
  reschedule_booking(uuid, uuid, reason_code, text, timestamptz) from public, anon;
grant  execute on function create_booking(uuid, uuid, timestamptz),
  reschedule_booking(uuid, uuid, reason_code, text, timestamptz) to authenticated;

notify pgrst, 'reload schema';

-- ---------- Quick check (read-only) --------------------------------------
-- select name, kind, session_minutes from package_types order by name;
-- select conname, pg_get_constraintdef(oid) from pg_constraint where conrelid = 'slots'::regclass and contype = 'c';
