-- =====================================================================
-- REPCLUB  |  24_preview_delete_luis_and_members.sql
-- READ ONLY. Changes nothing. Run this BEFORE 25_delete_luis_and_members.sql.
-- Shows coach Luis and every member, with KEEP or DELETE and how much data
-- each has. Kept = the member whose name starts with "Carla" and the one
-- whose name starts with "Sanjeev". Admins and other coaches are not touched.
--
-- Check:
--   * exactly ONE row with role COACH (Luis)
--   * exactly TWO rows with KEEP (Carla and Sanjeev)
--   * "sessions_with_luis" on a KEEP row = bookings of Carla/Sanjeev in Luis's
--     sessions. Script 25 removes those bookings (their credit balance stays
--     the same).
--   * "luis_is_coach" = yes on a KEEP row: that member will have no coach
--     afterwards (assign a new coach in Members).
-- =====================================================================

with luis as (
  select id from public.profiles where role = 'COACH' and full_name ilike 'luis%'
), keep as (
  select id from public.profiles
   where role = 'MEMBER' and (full_name ilike 'carla%' or full_name ilike 'sanjeev%')
)
select
  case when p.id in (select id from keep) then 'KEEP' else 'DELETE' end as action,
  p.role,
  p.full_name,
  u.email,
  p.is_active,
  (select count(*) from public.member_packages x where x.member_id = p.id)      as packages,
  (select count(*) from public.credit_transactions x where x.member_id = p.id)  as credit_rows,
  (select count(*) from public.bookings x where x.member_id = p.id)             as bookings,
  (select count(*) from public.gym_bookings x where x.member_id = p.id)         as gym_bookings,
  (select count(*) from public.attendance x where x.member_id = p.id or x.coach_id = p.id) as attendance,
  (select count(*) from public.workout_plans x where x.member_id = p.id)        as workouts,
  (select count(*) from public.body_evaluations x where x.member_id = p.id)     as evaluations,
  (select count(*) from public.weight_logs x where x.member_id = p.id)          as weights,
  (select count(*) from public.slots x where x.coach_id = p.id)                 as coach_sessions,
  (select count(*) from public.member_profiles x where x.primary_coach_id = p.id) as coach_of_members,
  (select count(*) from public.bookings b join public.slots s on s.id = b.slot_id
    where b.member_id = p.id and s.coach_id in (select id from luis))           as sessions_with_luis,
  case when exists (select 1 from public.member_profiles m
                     where m.id = p.id and m.primary_coach_id in (select id from luis))
       then 'yes' else '' end                                                   as luis_is_coach
from public.profiles p
join auth.users u on u.id = p.id
where p.id in (select id from luis) or p.role = 'MEMBER'
order by action, p.role, p.full_name;
