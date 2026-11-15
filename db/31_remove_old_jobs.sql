-- 31_remove_old_jobs.sql
-- Removes the last two hand-made scheduled jobs found on 2026-11-15:
--   repclub-expire-packages  (00:15 daily, ran expire_packages())
--   repclub-generate-slots   (00:30 daily, ran generate_slots())
-- Neither function is in any RepClub SQL file (left over from an older setup),
-- so they either failed every night or ran out-of-date rules (no coach time
-- off, no 30-minute sessions, no Monthly Pass). Their work is done properly by
--   repclub-nightly-package-expiry  (run_package_expiry(), db/29)
--   repclub-weekly-generate-slots   (admin_generate_slots(), db/06)
-- The old functions themselves are NOT deleted. Re-runnable. Run after 30.

create extension if not exists pg_cron with schema extensions;

select cron.unschedule(jobid) from cron.job
 where jobname in ('repclub-expire-packages', 'repclub-generate-slots');

-- Expect exactly two rows: repclub-nightly-package-expiry, repclub-weekly-generate-slots.
select jobid, jobname, schedule, active, command
  from cron.job
 order by jobname;
