-- 30_remove_old_no_show_job.sql
-- Found 2026-11-15: besides the jobs from 06/29, the database had three older
-- scheduled jobs made by hand (not in any file): repclub-reconcile-no-shows
-- (00:05 daily), repclub-expire-packages (00:15 daily), repclub-generate-slots
-- (00:30 daily). The owner wants NO automatic no-shows, so the no-show job is
-- removed here. The result lists every remaining job WITH its command so the
-- other two can be checked. Re-runnable. Run after 29.

create extension if not exists pg_cron with schema extensions;

select cron.unschedule(jobid) from cron.job where jobname = 'repclub-reconcile-no-shows';

select jobid, jobname, schedule, active, command
  from cron.job
 order by jobname;
