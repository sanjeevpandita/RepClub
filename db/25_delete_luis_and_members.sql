-- =====================================================================
-- REPCLUB  |  25_delete_luis_and_members.sql
-- DELETES coach LUIS and EVERY MEMBER EXCEPT Carla and Sanjeev, with all
-- their data and their logins. CANNOT BE UNDONE.
-- Run 24_preview_delete_luis_and_members.sql first and check the list.
-- Run once in Supabase > SQL Editor. It is one statement: either everything
-- is deleted or (on any problem) nothing is.
--
-- Who:  coach  = the one COACH whose name starts with "Luis"
--       kept   = the MEMBER whose name starts with "Carla" and the one with "Sanjeev"
--       gone   = every other MEMBER (active or not)
-- It stops, deleting nothing, unless it finds exactly one Luis, one Carla
-- and one Sanjeev. Admins, other coaches and gym settings are not touched.
--
-- Deleted for Luis + the gone members:
--   logins, profiles, packages, credit history, bookings, gym bookings,
--   attendance, weight logs, body evaluations, workouts and logged sets,
--   equipment ticks, Luis's sessions, weekly hours and holidays, and their
--   entries in the audit log.
-- Carla and Sanjeev:
--   * any booking they had in one of Luis's sessions is removed (with its
--     attendance); their credit rows stay, so their balance does not change
--   * if Luis was their coach, they now have no coach (assign one in Members)
--   * where Luis or a gone member did something to their data (e.g. created
--     a booking, wrote an evaluation), the record stays and "by" becomes blank
-- Not done here: profile photos in Storage > avatars (delete them by hand,
-- files are named <user id>.jpg; the preview does not list ids).
-- =====================================================================

do $$
declare
  v_luis uuid[]; v_keep uuid[]; v_gone uuid[]; v_all uuid[]; v_bookings uuid[];
  v_all_txt text[]; v_keep_txt text[];
  n_carla int; n_sanjeev int;
  c_logins int; c_bookings int; c_credits int; c_slots int; c_audit int;
begin
  -- 1. Who ------------------------------------------------------------------
  select array_agg(id) into v_luis
    from public.profiles where role = 'COACH' and full_name ilike 'luis%';
  if coalesce(array_length(v_luis, 1), 0) <> 1 then
    raise exception 'Stopped: expected exactly 1 coach named Luis, found %. Nothing was deleted.',
      coalesce(array_length(v_luis, 1), 0);
  end if;

  select count(*) into n_carla   from public.profiles where role = 'MEMBER' and full_name ilike 'carla%';
  select count(*) into n_sanjeev from public.profiles where role = 'MEMBER' and full_name ilike 'sanjeev%';
  if n_carla <> 1 or n_sanjeev <> 1 then
    raise exception 'Stopped: expected one member Carla and one Sanjeev, found % and %. Nothing was deleted.',
      n_carla, n_sanjeev;
  end if;

  select array_agg(id) into v_keep
    from public.profiles
   where role = 'MEMBER' and (full_name ilike 'carla%' or full_name ilike 'sanjeev%');
  select coalesce(array_agg(id), '{}') into v_gone
    from public.profiles where role = 'MEMBER' and not (id = any (v_keep));

  v_all      := v_gone || v_luis;
  v_all_txt  := v_all::text[];
  v_keep_txt := v_keep::text[];

  -- 2. Switch off the ledger lock and the audit trail while we clean up --------
  alter table public.credit_transactions disable trigger ledger_protect;
  alter table public.profiles          disable trigger audit;
  alter table public.member_profiles   disable trigger audit;
  alter table public.coach_profiles    disable trigger audit;
  alter table public.member_packages   disable trigger audit;
  alter table public.bookings          disable trigger audit;
  alter table public.attendance        disable trigger audit;
  alter table public.body_evaluations  disable trigger audit;
  alter table public.workout_plans     disable trigger audit;

  -- 3. Bookings to remove: all of the gone members', and any in Luis's sessions
  select coalesce(array_agg(b.id), '{}') into v_bookings
    from public.bookings b join public.slots s on s.id = b.slot_id
   where b.member_id = any (v_gone) or s.coach_id = any (v_luis);

  -- 4. Credit history: gone members' rows deleted; kept members' rows only
  --    lose the link to a removed booking (balance unchanged)
  delete from public.credit_transactions where member_id = any (v_gone);
  get diagnostics c_credits = row_count;
  update public.credit_transactions set booking_id = null where booking_id = any (v_bookings);

  -- 5. Attendance, bookings, sessions, gym bookings, packages
  delete from public.attendance
   where booking_id = any (v_bookings) or member_id = any (v_gone) or coach_id = any (v_luis);
  delete from public.bookings where id = any (v_bookings) or member_id = any (v_gone);
  get diagnostics c_bookings = row_count;
  delete from public.slots where coach_id = any (v_luis);
  get diagnostics c_slots = row_count;
  delete from public.gym_bookings where member_id = any (v_gone);
  delete from public.member_packages where member_id = any (v_gone);

  -- 6. Kept members lose Luis as their coach
  update public.member_profiles set primary_coach_id = null where primary_coach_id = any (v_luis);

  -- 7. "Done by" fields on rows that stay
  update public.member_packages     set activated_by = null where activated_by = any (v_all);
  update public.member_packages     set created_by   = null where created_by   = any (v_all);
  update public.credit_transactions set created_by   = null where created_by   = any (v_all);
  update public.bookings            set created_by   = null where created_by   = any (v_all);
  update public.bookings            set cancelled_by = null where cancelled_by = any (v_all);
  update public.attendance          set recorded_by  = null where recorded_by  = any (v_all);
  update public.gym_bookings        set created_by   = null where created_by   = any (v_all);
  update public.gym_bookings        set cancelled_by = null where cancelled_by = any (v_all);
  update public.equipment_assignments set assigned_by = null where assigned_by = any (v_all);
  update public.body_evaluations    set coach_id     = null where coach_id     = any (v_all);
  update public.coach_time_off      set created_by   = null where created_by   = any (v_all);
  update public.workout_plans       set coach_id     = null where coach_id     = any (v_all);
  update public.workout_set_logs    set logged_by    = null where logged_by    = any (v_all);

  -- 8. Logins. Removing a login removes its profile and, through the links,
  --    weight logs, evaluations, workouts, logged sets, equipment ticks,
  --    Luis's weekly hours and holidays.
  delete from auth.users where id = any (v_all);
  get diagnostics c_logins = row_count;

  -- 9. Audit entries about the deleted people (kept members' history stays)
  delete from public.audit_log a
   where a.entity_id = any (v_all_txt)
      or coalesce(a.new_data, a.old_data) ->> 'member_id' = any (v_all_txt)
      or (coalesce(a.new_data, a.old_data) ->> 'coach_id' = any (v_all_txt)
          and coalesce(coalesce(a.new_data, a.old_data) ->> 'member_id', '') <> all (v_keep_txt));
  get diagnostics c_audit = row_count;

  -- 10. Switch the protections back on
  alter table public.credit_transactions enable trigger ledger_protect;
  alter table public.profiles          enable trigger audit;
  alter table public.member_profiles   enable trigger audit;
  alter table public.coach_profiles    enable trigger audit;
  alter table public.member_packages   enable trigger audit;
  alter table public.bookings          enable trigger audit;
  alter table public.attendance        enable trigger audit;
  alter table public.body_evaluations  enable trigger audit;
  alter table public.workout_plans     enable trigger audit;

  insert into public.audit_log (actor_id, action, entity, note)
  values (null, 'BULK_DELETE', 'profiles',
          format('Script 25: removed coach Luis and %s members (kept Carla and Sanjeev).',
                 coalesce(array_length(v_gone, 1), 0)));

  raise notice 'Done: % logins removed (% members + Luis), % bookings, % credit rows, % Luis sessions, % audit entries.',
    c_logins, coalesce(array_length(v_gone, 1), 0), c_bookings, c_credits, c_slots, c_audit;
end $$;

-- Check: should list Carla, Sanjeev, your admin(s) and the other coaches only.
select p.role, p.full_name, p.is_active
  from public.profiles p
 order by p.role, p.full_name;
