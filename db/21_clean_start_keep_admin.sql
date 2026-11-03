-- =====================================================================
-- REPCLUB  |  21_clean_start_keep_admin.sql
-- Wipes ALL business data and every non-admin login, so the customer can
-- start fresh. KEEPS: every ADMIN login + profile, the table structure,
-- functions, scheduled jobs, gym settings (app_settings), notification
-- settings and the gym door QR record.
-- DELETES: all members and coaches (logins too), packages, credits,
-- bookings, attendance, gym bookings, sessions, weekly hours, coach
-- holidays, weight logs, body evaluations, equipment (library and
-- assignments), package types, special days, and the audit log.
-- CANNOT BE UNDONE. Take a backup first (Supabase > Database > Backups).
-- Run once in Supabase > SQL Editor (it is a single statement, as needed).
-- =====================================================================

do $$
begin
  if not exists (select 1 from public.profiles where role = 'ADMIN' and is_active) then
    raise exception 'Stopped: no active ADMIN profile found, nothing was deleted';
  end if;

  -- 1. Business data (TRUNCATE does not fire the audit / ledger-protect triggers)
  truncate table
    public.credit_transactions, public.attendance, public.bookings, public.gym_bookings,
    public.member_packages, public.slots, public.coach_weekly_schedule, public.coach_time_off,
    public.equipment_assignments, public.body_evaluations, public.weight_logs,
    public.equipment, public.package_types, public.gym_day_overrides
    restart identity;

  -- 1b. Workout plans and logged sets (db/22). The muscle group / exercise
  --     library is gym setup and is kept.
  if to_regclass('public.workout_plans') is not null then
    truncate table public.workout_set_logs, public.workout_plan_exercises, public.workout_plans
      restart identity;
  end if;

  -- 2. Every login that is not an admin. Deleting the login removes its profile,
  --    coach/member rows and sessions through the cascading foreign keys.
  delete from auth.users
   where id not in (select id from public.profiles where role = 'ADMIN');

  -- 3. Audit log last (step 2 writes audit rows). Starts empty.
  truncate table public.audit_log restart identity;

  -- 4. New door QR so any old printed code stops working
  update public.gym_qr set token = gen_random_uuid();
end $$;

-- Check: should show only your admin account(s), and zero in the others.
select
  (select count(*) from public.profiles where role = 'ADMIN') as admins_kept,
  (select count(*) from public.profiles where role <> 'ADMIN') as other_profiles,
  (select count(*) from auth.users) as logins_total,
  (select count(*) from public.member_packages) as packages,
  (select count(*) from public.bookings) as bookings;

-- Note: profile photos already uploaded stay in Storage > avatars. Delete them
-- by hand in the Supabase dashboard (Storage > avatars) if you want them gone.
