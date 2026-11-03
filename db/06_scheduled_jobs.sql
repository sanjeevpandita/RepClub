-- =====================================================================
-- REPCLUB  |  06_scheduled_jobs.sql
-- Two automatic jobs, using Supabase's built-in scheduler (pg_cron).
-- Run in Supabase > SQL Editor. Safe to run more than once (a job with the
-- same name is replaced, not duplicated).
-- Times below are UTC. Dublin is UTC+0 in winter and UTC+1 in summer.
-- =====================================================================

create extension if not exists pg_cron with schema extensions;

-- 1. Nightly: mark finished-but-unattended bookings as no-shows (taking the
--    credit), expire old packages, and start queued ones. Runs 23:30 UTC.
select cron.schedule(
  'repclub-nightly-reconciliation',
  '30 23 * * *',
  $$ select public.run_reconciliation(); $$
);

-- 2. Weekly (Sunday 01:00 UTC): create sessions for the next 6 weeks from each
--    coach's weekly hours. Existing sessions are left alone.
select cron.schedule(
  'repclub-weekly-generate-slots',
  '0 1 * * 0',
  $$ select public.admin_generate_slots(current_date, current_date + 42); $$
);

-- 3. Check: both jobs should be listed and active.
select jobid, jobname, schedule, active from cron.job
 where jobname like 'repclub-%' order by jobname;

-- To look at past runs later:
--   select jobname, status, return_message, start_time
--     from cron.job_run_details d join cron.job j using (jobid)
--    where jobname like 'repclub-%' order by start_time desc limit 20;
-- To stop a job:   select cron.unschedule('repclub-nightly-reconciliation');
