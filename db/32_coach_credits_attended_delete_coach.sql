-- =====================================================================
-- REPCLUB  |  32_coach_credits_attended_delete_coach.sql
-- Owner requests (2026-11-25). Re-runnable. Run after 01-31.
--
-- 1. Two new reasons: MISSED_SCAN ("Came but did not scan") and
--    NO_SHOW ("Did not show up").
-- 2. Credit adjustments (add or remove credits) may now also be made by the
--    member's own coach, not only the admin. Same rules: reason required,
--    balance can never go below zero, every change is in the credit history.
-- 3. mark_attended(booking): the coach of the session (or the admin) marks a
--    member as attended when the QR was not scanned (forgot the phone, coach
--    forgot to scan). Works on a BOOKED session (past, today or future) and
--    on a NO_SHOW (the no-show credit is given back, then the session is
--    charged once as attended, so the balance ends up the same).
-- 4. admin_delete_coach_preview / admin_delete_coach: the admin deletes a
--    coach for good. Deleted: the coach's login, profile, QR, weekly hours,
--    holidays, all the coach's sessions and the bookings + attendance in
--    them. Members are NOT deleted: they simply have no coach afterwards.
--    Members' credit history stays as it is (credits already used stay
--    used); members' evaluations and workouts stay, "by" becomes blank.
-- 5. The NIGHTLY NO-SHOW JOB IS BACK (owner, 2026-11-25; reverses db/29):
--    every night at 23:30 UTC finished sessions still "Booked" become
--    no-shows (1 credit each), missed gym hours become no-shows (no credit),
--    packages expire and queued ones start. The coach can still change a
--    no-show to "Attended" afterwards (credit stays the same).
-- =====================================================================

-- ---------- 1. New reasons --------------------------------------------
alter type reason_code add value if not exists 'MISSED_SCAN';
alter type reason_code add value if not exists 'NO_SHOW';

-- ---------- 2. Coach may adjust credits of own members ------------------
create or replace function admin_adjust_credits(p_member uuid, p_delta int, p_reason reason_code, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare pkg member_packages; old_bal int; new_bal int;
begin
  if not (is_admin() or coach_has_member(p_member)) then
    raise exception 'Only the admin or the member''s own coach can change credits';
  end if;
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

-- ---------- 3. Mark attended by hand (coach of the session or admin) -----
create or replace function mark_attended(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; v_old bigint; v_txn bigint; v_pkg uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  select * into s from slots where id = b.slot_id;
  if not (is_admin() or (app_role() = 'COACH' and s.coach_id = auth.uid())) then raise exception 'Not allowed'; end if;
  if b.status = 'ATTENDED' then raise exception 'This member is already marked as attended'; end if;
  if b.status not in ('BOOKED', 'NO_SHOW') then raise exception 'Cannot mark a % booking as attended', b.status; end if;

  if b.status = 'NO_SHOW' then  -- give the no-show credit back first
    select id into v_old from credit_transactions
     where booking_id = b.id and type = 'NO_SHOW' and not is_void;
    if found then perform _reverse_credit(v_old, 'MISSED_SCAN', 'No-show changed to attended', auth.uid()); end if;
  end if;

  v_txn := _consume_credit(b.member_id, 'CHECK_IN', b.id, b.booking_date, auth.uid(), true);
  insert into attendance (booking_id, member_id, coach_id, attendance_date, checked_in_at, method, recorded_by, reason_code)
  values (b.id, b.member_id, s.coach_id, b.booking_date, s.starts_at, 'MANUAL', auth.uid(), 'MISSED_SCAN');
  update bookings set status = 'ATTENDED' where id = b.id;
  perform _audit('MANUAL_ATTENDANCE', 'bookings', b.id::text,
                 jsonb_build_object('status', b.status), jsonb_build_object('status', 'ATTENDED'), 'MISSED_SCAN', null);

  select member_package_id into v_pkg from credit_transactions where id = v_txn;
  return jsonb_build_object('credits_left', _balance(v_pkg));
end $$;

-- ---------- 4. Delete a coach -------------------------------------------
-- The ledger normally refuses every change. Deleting a coach must unlink
-- credit rows from the bookings that are removed and blank "by" where the
-- coach made the change; only admin_delete_coach switches that on, only for
-- those two columns and only to blank them.
create or replace function ledger_protect() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Credit transactions cannot be deleted';
  end if;
  if current_setting('repclub.unlink_coach', true) = 'on'
     and (new.booking_id is null or new.booking_id = old.booking_id)
     and (new.created_by is null or new.created_by = old.created_by)
     and (to_jsonb(new) - 'booking_id' - 'created_by') = (to_jsonb(old) - 'booking_id' - 'created_by') then
    return new;
  end if;
  if (to_jsonb(new) - 'is_void') is distinct from (to_jsonb(old) - 'is_void')
     or old.is_void then
    raise exception 'Credit transactions cannot be edited';
  end if;
  return new;
end $$;

-- What would be deleted (nothing changes).
create or replace function admin_delete_coach_preview(p_coach uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  perform _require_admin();
  select full_name into v_name from profiles where id = p_coach and role = 'COACH';
  if not found then raise exception 'Coach not found'; end if;
  return jsonb_build_object(
    'name', v_name,
    'members', (select count(*) from member_profiles where primary_coach_id = p_coach),
    'sessions', (select count(*) from slots where coach_id = p_coach),
    'bookings_past', (select count(*) from bookings b join slots s on s.id = b.slot_id
                       where s.coach_id = p_coach and b.status <> 'CANCELLED' and s.starts_at < now()),
    'bookings_upcoming', (select count(*) from bookings b join slots s on s.id = b.slot_id
                           where s.coach_id = p_coach and b.status = 'BOOKED' and s.starts_at >= now()));
end $$;

create or replace function admin_delete_coach(p_coach uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text; v_bookings uuid[]; n_members int; n_sessions int; n_bookings int;
begin
  perform _require_admin();
  if p_coach = auth.uid() then raise exception 'You cannot delete yourself'; end if;
  select full_name into v_name from profiles where id = p_coach and role = 'COACH';
  if not found then raise exception 'Coach not found'; end if;

  select coalesce(array_agg(b.id), '{}') into v_bookings
    from bookings b join slots s on s.id = b.slot_id where s.coach_id = p_coach;
  n_bookings := coalesce(array_length(v_bookings, 1), 0);

  -- Credit rows stay (members' balances do not change); only the links go.
  perform set_config('repclub.unlink_coach', 'on', true);
  update credit_transactions set booking_id = null where booking_id = any (v_bookings);
  update credit_transactions set created_by = null where created_by = p_coach;
  perform set_config('repclub.unlink_coach', 'off', true);

  -- The coach's sessions, with their bookings and attendance.
  delete from attendance where booking_id = any (v_bookings) or coach_id = p_coach;
  delete from bookings where id = any (v_bookings);
  delete from slots where coach_id = p_coach;
  get diagnostics n_sessions = row_count;

  -- Members lose the coach (they are not deleted).
  update member_profiles set primary_coach_id = null where primary_coach_id = p_coach;
  get diagnostics n_members = row_count;

  -- "Done by" on members' records that stay.
  update member_packages       set activated_by = null where activated_by = p_coach;
  update member_packages       set created_by   = null where created_by   = p_coach;
  update bookings              set created_by   = null where created_by   = p_coach;
  update bookings              set cancelled_by = null where cancelled_by = p_coach;
  update attendance            set recorded_by  = null where recorded_by  = p_coach;
  update gym_bookings          set created_by   = null where created_by   = p_coach;
  update gym_bookings          set cancelled_by = null where cancelled_by = p_coach;
  update equipment_assignments set assigned_by  = null where assigned_by  = p_coach;
  update body_evaluations      set coach_id     = null where coach_id     = p_coach;
  update coach_time_off        set created_by   = null where created_by   = p_coach;
  update workout_plans         set coach_id     = null where coach_id     = p_coach;
  update workout_set_logs      set logged_by    = null where logged_by    = p_coach;

  -- The login. Removing it removes the profile, coach profile (QR), weekly
  -- hours and holidays through their links.
  delete from auth.users where id = p_coach;

  perform _audit('COACH_DELETED', 'profiles', p_coach::text,
                 jsonb_build_object('full_name', v_name, 'members', n_members,
                                    'sessions', n_sessions, 'bookings', n_bookings),
                 null, null, null);
  return jsonb_build_object('members', n_members, 'sessions', n_sessions, 'bookings', n_bookings);
end $$;

-- ---------- 5. Nightly no-shows are automatic again ---------------------
create or replace function run_reconciliation() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n_noshow int := 0; n_gym int := 0; res jsonb;
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

  res := run_package_expiry();
  return res || jsonb_build_object('no_shows', n_noshow, 'gym_no_shows', n_gym);
end $$;

create extension if not exists pg_cron with schema extensions;
select cron.unschedule(jobid) from cron.job
 where jobname in ('repclub-nightly-package-expiry', 'repclub-nightly-reconciliation');
select cron.schedule(
  'repclub-nightly-reconciliation',
  '30 23 * * *',
  $$ select public.run_reconciliation(); $$
);

-- ---------- 6. Who may call what ----------------------------------------
revoke execute on function mark_attended(uuid), admin_delete_coach_preview(uuid), admin_delete_coach(uuid),
  admin_adjust_credits(uuid, int, reason_code, text), run_reconciliation() from public, anon;
grant  execute on function mark_attended(uuid), admin_delete_coach_preview(uuid), admin_delete_coach(uuid),
  admin_adjust_credits(uuid, int, reason_code, text), run_reconciliation() to authenticated;

notify pgrst, 'reload schema';

-- Check: expect repclub-nightly-reconciliation and repclub-weekly-generate-slots.
select jobid, jobname, schedule, active from cron.job
 where jobname like 'repclub-%' order by jobname;
