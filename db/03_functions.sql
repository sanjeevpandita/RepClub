-- =====================================================================
-- REPCLUB  |  03_functions.sql
-- The "checked" actions the apps call: assign/activate packages, adjust
-- credits, book, cancel, reschedule, QR check-in, manual attendance,
-- no-shows, waivers, nightly reconciliation, slot generation.
-- Every function checks WHO is calling and enforces the Decision Log
-- rules. Run after 01 and 02. Safe to re-run (create or replace).
-- Functions starting with "_" are internal helpers, not callable by apps.
-- =====================================================================

-- ---------- Internal helpers -----------------------------------------
create or replace function _gym_today() returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone gym_timezone)::date from app_settings
$$;

create or replace function _balance(p_pkg uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from credit_transactions where member_package_id = p_pkg
$$;

create or replace function _audit(p_action text, p_entity text, p_entity_id text,
                                  p_old jsonb, p_new jsonb, p_reason reason_code, p_note text)
returns void language sql security definer set search_path = public as $$
  insert into audit_log (actor_id, action, entity, entity_id, old_data, new_data, reason_code, note)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_old, p_new, p_reason, p_note)
$$;

create or replace function _require_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admin only'; end if;
end $$;

create or replace function _check_reason(p_reason reason_code, p_note text) returns void
language plpgsql as $$
begin
  if p_reason is null then raise exception 'A reason is required'; end if;
  if p_reason = 'OTHER' and nullif(trim(p_note), '') is null then
    raise exception 'A note is required when the reason is OTHER';
  end if;
end $$;

-- Make a QUEUED package the member's ACTIVE one and give it its starting credits
create or replace function _activate_package(p_pkg uuid, p_actor uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pkg member_packages;
begin
  select * into pkg from member_packages where id = p_pkg for update;
  if not found then raise exception 'Package not found'; end if;
  if pkg.status <> 'QUEUED' then raise exception 'Only a queued package can be activated (this one is %)', pkg.status; end if;
  if exists (select 1 from member_packages where member_id = pkg.member_id and status = 'ACTIVE') then
    raise exception 'The member already has an active package. This one stays queued until it is finished.';
  end if;
  if pkg.expiry_date < _gym_today() then raise exception 'This package has already expired'; end if;

  update member_packages set status = 'ACTIVE', activated_at = now(), activated_by = p_actor where id = p_pkg;
  insert into credit_transactions (member_id, member_package_id, type, delta, created_by)
  values (pkg.member_id, pkg.id, 'PACKAGE_START', pkg.starting_credits, p_actor);
end $$;

-- When a package ends, start the member's next queued one (if its dates allow)
create or replace function _activate_next(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if exists (select 1 from member_packages where member_id = p_member and status = 'ACTIVE') then return; end if;
  select id into v from member_packages
   where member_id = p_member and status = 'QUEUED'
     and start_date <= _gym_today() and expiry_date >= _gym_today()
   order by start_date, created_at limit 1;
  if found then perform _activate_package(v, null); end if;
end $$;

-- Take one credit from the member's active package. Strict = raise an error if impossible.
create or replace function _consume_credit(p_member uuid, p_type credit_txn_type, p_booking uuid,
                                           p_date date, p_actor uuid, p_strict boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare pkg member_packages; v_id bigint;
begin
  select * into pkg from member_packages where member_id = p_member and status = 'ACTIVE' for update;
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

-- Cancel out a consuming transaction (waiver / correction): +1 credit, original flagged void
create or replace function _reverse_credit(p_txn bigint, p_reason reason_code, p_note text, p_actor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t credit_transactions;
begin
  select * into t from credit_transactions where id = p_txn for update;
  insert into credit_transactions (member_id, member_package_id, type, delta, reason_code, note, booking_id, attendance_date, created_by)
  values (t.member_id, t.member_package_id, 'REVERSAL', -t.delta, p_reason, p_note, t.booking_id, t.attendance_date, p_actor);
  update credit_transactions set is_void = true where id = p_txn;
  -- if the credit came back to an exhausted package and nothing else is active, re-open it
  if exists (select 1 from member_packages where id = t.member_package_id and status = 'EXHAUSTED' and expiry_date >= _gym_today())
     and not exists (select 1 from member_packages where member_id = t.member_id and status = 'ACTIVE') then
    update member_packages set status = 'ACTIVE' where id = t.member_package_id;
  end if;
end $$;

-- ---------- Packages and credits (Admin) -----------------------------
create or replace function admin_assign_package(
  p_member uuid, p_package_type uuid, p_purchase_date date, p_start_date date, p_expiry_date date,
  p_starting_credits int, p_payment_note text default null, p_activate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare pt package_types; v_id uuid;
begin
  perform _require_admin();
  select * into pt from package_types where id = p_package_type;
  if not found then raise exception 'Package type not found'; end if;
  if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
  insert into member_packages (member_id, package_type_id, package_name, purchase_date, start_date,
                               expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, p_purchase_date, p_start_date,
          p_expiry_date, p_starting_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

create or replace function admin_activate_package(p_member_package uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _activate_package(p_member_package, auth.uid());
end $$;

-- Add or remove credits by hand. Always a ledger row + audit entry, reason required.
create or replace function admin_adjust_credits(p_member uuid, p_delta int, p_reason reason_code, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare pkg member_packages; old_bal int; new_bal int;
begin
  perform _require_admin();
  if p_delta = 0 then raise exception 'Adjustment cannot be zero'; end if;
  perform _check_reason(p_reason, p_note);

  select * into pkg from member_packages where member_id = p_member and status = 'ACTIVE' for update;
  if not found then
    select * into pkg from member_packages
     where member_id = p_member and status = 'EXHAUSTED' and expiry_date >= _gym_today()
     order by activated_at desc nulls last limit 1 for update;
  end if;
  if not found then raise exception 'Member has no active package to adjust'; end if;

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

-- ---------- Bookings --------------------------------------------------
-- Member books for themselves; Admin passes p_member to book on someone's behalf.
create or replace function create_booking(p_slot uuid, p_member uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_member uuid; s slots; pkg member_packages; d date; v_id uuid; committed int; tz text;
begin
  if is_admin() then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
  elsif app_role() = 'MEMBER' then
    v_member := auth.uid();
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

  select * into pkg from member_packages where member_id = v_member and status = 'ACTIVE';
  if not found then raise exception 'No active package'; end if;
  if d < pkg.start_date or d > pkg.expiry_date then
    raise exception 'The active package is not valid on %', d;
  end if;
  select count(*) into committed from bookings where member_id = v_member and status = 'BOOKED';
  if _balance(pkg.id) - committed < 1 then
    raise exception 'All remaining credits are already booked';
  end if;

  insert into bookings (member_id, slot_id, booking_date, created_by)
  values (v_member, p_slot, d, auth.uid()) returning id into v_id;   -- capacity, coach and one-per-day rules fire here
  return v_id;
end $$;

create or replace function cancel_booking(p_booking uuid, p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; locked boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid()) then raise exception 'Not allowed'; end if;
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
end $$;

create or replace function reschedule_booking(p_booking uuid, p_new_slot uuid,
                                              p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; ns slots; locked boolean; pkg member_packages; tz text; nd date;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid()) then raise exception 'Not allowed'; end if;
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
  select * into pkg from member_packages where member_id = b.member_id and status = 'ACTIVE';
  if not found or nd < pkg.start_date or nd > pkg.expiry_date then
    raise exception 'The active package is not valid on %', nd;
  end if;

  update bookings set slot_id = p_new_slot where id = p_booking;     -- capacity / coach / one-per-day rules fire here
end $$;

-- ---------- Attendance ------------------------------------------------
-- Member scans the coach QR. p_qr_token is the secret inside the QR code.
create or replace function qr_check_in(p_qr_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid := auth.uid(); v_coach uuid; v_primary uuid; today date; tz text;
        b bookings; s slots; v_txn bigint; pkg_id uuid;
begin
  if app_role() is distinct from 'MEMBER' then raise exception 'Only members can check in'; end if;
  select gym_timezone into tz from app_settings;
  today := _gym_today();

  select cp.id into v_coach from coach_profiles cp join profiles p on p.id = cp.id
   where cp.qr_token = p_qr_token and p.is_active;
  if not found then raise exception 'This QR code is not valid'; end if;
  select primary_coach_id into v_primary from member_profiles where id = v_member;
  if v_primary is distinct from v_coach then raise exception 'This QR code belongs to a different coach'; end if;

  select * into b from bookings
   where member_id = v_member and booking_date = today and status in ('BOOKED', 'ATTENDED')
   order by created_at desc limit 1;
  if not found then raise exception 'You have no booking for today'; end if;
  if b.status = 'ATTENDED' then raise exception 'You are already checked in today'; end if;

  select * into s from slots where id = b.slot_id;
  if s.coach_id <> v_coach then raise exception 'Your booking today is with a different coach'; end if;
  if now() < s.starts_at - make_interval(mins => (select checkin_minutes_before from app_settings)) then
    raise exception 'Check-in opens at %', to_char((s.starts_at - make_interval(mins => (select checkin_minutes_before from app_settings))) at time zone tz, 'HH24:MI');
  end if;
  if now() > s.ends_at then raise exception 'Check-in closed at %', to_char(s.ends_at at time zone tz, 'HH24:MI'); end if;

  v_txn := _consume_credit(v_member, 'CHECK_IN', b.id, today, null, true);
  insert into attendance (booking_id, member_id, coach_id, attendance_date, method)
  values (b.id, v_member, v_coach, today, 'QR');
  update bookings set status = 'ATTENDED' where id = b.id;

  select id into pkg_id from member_packages where id = (select member_package_id from credit_transactions where id = v_txn);
  return jsonb_build_object('booking_id', b.id, 'checked_in_at', now(), 'credits_left', _balance(pkg_id));
end $$;

-- Admin records attendance by hand (dead phone etc.). Reason mandatory.
create or replace function admin_manual_attendance(p_booking uuid, p_reason reason_code, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; v_old bigint;
begin
  perform _require_admin();
  perform _check_reason(p_reason, p_note);
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('BOOKED', 'NO_SHOW') then raise exception 'Cannot record attendance for a % booking', b.status; end if;
  select * into s from slots where id = b.slot_id;

  if b.status = 'NO_SHOW' then       -- undo the no-show deduction first, then charge the day once as attended
    select id into v_old from credit_transactions
     where booking_id = b.id and type = 'NO_SHOW' and not is_void;
    if found then perform _reverse_credit(v_old, p_reason, p_note, auth.uid()); end if;
  end if;

  perform _consume_credit(b.member_id, 'CHECK_IN', b.id, b.booking_date, auth.uid(), true);
  insert into attendance (booking_id, member_id, coach_id, attendance_date, method, recorded_by, reason_code, note)
  values (b.id, b.member_id, s.coach_id, b.booking_date, 'MANUAL', auth.uid(), p_reason, p_note);
  update bookings set status = 'ATTENDED' where id = b.id;
  perform _audit('MANUAL_ATTENDANCE', 'bookings', b.id::text, null, null, p_reason, p_note);
end $$;

-- Coach (their own sessions) or Admin marks a started session's booking as no-show
create or replace function mark_no_show(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; s slots;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  select * into s from slots where id = b.slot_id;
  if not (is_admin() or (app_role() = 'COACH' and s.coach_id = auth.uid())) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be marked as no-show'; end if;
  if now() < s.starts_at then raise exception 'The session has not started yet'; end if;

  update bookings set status = 'NO_SHOW' where id = b.id;
  perform _consume_credit(b.member_id, 'NO_SHOW', b.id, b.booking_date, auth.uid(), false);
end $$;

-- Admin waives a no-show deduction (reason code), credit goes back
create or replace function admin_waive_no_show(p_booking uuid, p_reason reason_code, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_old bigint;
begin
  perform _require_admin();
  perform _check_reason(p_reason, p_note);
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status <> 'NO_SHOW' then raise exception 'Only a no-show can be waived'; end if;

  select id into v_old from credit_transactions where booking_id = b.id and type = 'NO_SHOW' and not is_void;
  if found then perform _reverse_credit(v_old, p_reason, p_note, auth.uid()); end if;
  update bookings set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid() where id = b.id;
  perform _audit('NO_SHOW_WAIVED', 'bookings', b.id::text, null, null, p_reason, p_note);
end $$;

-- ---------- Scheduled jobs --------------------------------------------
-- Nightly: finished sessions with no check-in become no-shows; ended packages expire
-- (unused credits are lost); the next queued package starts.
create or replace function run_reconciliation() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n_noshow int := 0; n_expired int := 0; bal int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;

  for r in select b.id, b.member_id, b.booking_date from bookings b join slots s on s.id = b.slot_id
            where b.status = 'BOOKED' and s.ends_at < now() for update of b loop
    update bookings set status = 'NO_SHOW' where id = r.id;
    perform _consume_credit(r.member_id, 'NO_SHOW', r.id, r.booking_date, null, false);
    n_noshow := n_noshow + 1;
  end loop;

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

  return jsonb_build_object('no_shows', n_noshow, 'packages_expired', n_expired);
end $$;

-- Create real hourly sessions from each coach's weekly pattern for a date range
-- (skips closed days and hours outside opening times). Returns how many were created.
create or replace function admin_generate_slots(p_from date, p_to date) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Choose a range of at most 62 days'; end if;

  with days as (select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d)
  insert into slots (coach_id, starts_at, ends_at, capacity)
  select w.coach_id,
         (days.day + make_time(w.hour, 0, 0)) at time zone s.gym_timezone,
         (days.day + make_time(w.hour, 0, 0)) at time zone s.gym_timezone + interval '1 hour',
         s.slot_capacity
  from days
  cross join app_settings s
  join coach_weekly_schedule w on w.weekday = extract(isodow from days.day)
  join profiles p on p.id = w.coach_id and p.is_active
  where coalesce((select o.is_open from gym_day_overrides o where o.day = days.day),
                 extract(isodow from days.day)::smallint = any (s.open_weekdays))
    and make_time(w.hour, 0, 0) >= s.open_time
    and make_time(w.hour, 0, 0) <= s.close_time - interval '1 hour'
  on conflict (coach_id, starts_at) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Who may call what ----------------------------------------
-- Helpers (names starting "_") and trigger functions: not callable from the apps.
-- Everything else: signed-in users only (each function checks the role itself).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname like '\_%' or f.proname in ('audit_row', 'ledger_protect', 'slots_check', 'bookings_check') then
      execute format('revoke execute on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
