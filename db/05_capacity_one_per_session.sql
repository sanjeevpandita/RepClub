-- =====================================================================
-- REPCLUB  |  05_capacity_one_per_session.sql
-- Owner decision (2026-10-26): a coach takes ONE member per session.
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- =====================================================================

-- 1. New sessions (generated or added by the Admin) get capacity 1.
update app_settings set slot_capacity = 1;

-- 2. Existing sessions from now on: capacity 1, except any session that
--    already has more than one active booking (left alone so no member is
--    pushed out; fix those by moving a booking in the Calendar first).
update slots s
   set capacity = 1
 where s.starts_at > now()
   and s.capacity <> 1
   and (select count(*) from bookings b
         where b.slot_id = s.id
           and b.status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) <= 1;

-- 3. Check: sessions still above 1 (should normally be none).
select s.id, s.starts_at, s.capacity
  from slots s
 where s.starts_at > now() and s.capacity <> 1;
