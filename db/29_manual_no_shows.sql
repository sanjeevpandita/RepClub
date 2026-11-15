-- 29_manual_no_shows.sql
-- Owner decision (2026-11-15): no more AUTOMATIC no-shows. The nightly job no
-- longer marks finished, unattended bookings as no-shows. The admin can do it
-- by hand from the app (More > Missed sessions), after seeing the list first.
-- Package expiry (and starting a queued package) stays automatic every night.
-- Re-runnable. Run after 01-28.

-- 1. Nightly part that stays automatic: expire packages, start queued ones.
create or replace function run_package_expiry() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n_expired int := 0; bal int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;

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

  return jsonb_build_object('packages_expired', n_expired);
end $$;

-- 2. Manual, admin only: finished sessions still 'Booked' (nobody checked in).
--    p_apply = false (default): only LIST them, nothing changes.
--    p_apply = true: mark them all NO_SHOW (coach sessions take 1 credit each,
--    recorded as done by the admin; gym hours take no credit).
create or replace function admin_mark_past_no_shows(p_apply boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_noshow int := 0; n_gym int := 0; items jsonb := '[]'::jsonb;
begin
  perform _require_admin();

  for r in select b.id, b.member_id, b.booking_date, s.starts_at, s.ends_at,
                  p.full_name as member, c.full_name as coach
             from bookings b
             join slots s on s.id = b.slot_id
             left join profiles p on p.id = b.member_id
             left join profiles c on c.id = s.coach_id
            where b.status = 'BOOKED' and s.ends_at < now()
            order by s.starts_at
            for update of b loop
    items := items || jsonb_build_object('kind', 'COACH', 'member', r.member, 'coach', r.coach,
                                         'starts_at', r.starts_at, 'ends_at', r.ends_at);
    if p_apply then
      update bookings set status = 'NO_SHOW' where id = r.id;
      perform _consume_credit(r.member_id, 'NO_SHOW', r.id, r.booking_date, auth.uid(), false);
    end if;
    n_noshow := n_noshow + 1;
  end loop;

  for r in select g.id, g.hour_start, p.full_name as member
             from gym_bookings g
             left join profiles p on p.id = g.member_id
            where g.status = 'BOOKED' and g.hour_start + interval '1 hour' < now()
            order by g.hour_start
            for update of g loop
    items := items || jsonb_build_object('kind', 'GYM', 'member', r.member, 'coach', null,
                                         'starts_at', r.hour_start,
                                         'ends_at', r.hour_start + interval '1 hour');
    if p_apply then
      update gym_bookings set status = 'NO_SHOW' where id = r.id;
    end if;
    n_gym := n_gym + 1;
  end loop;

  return jsonb_build_object('applied', p_apply, 'no_shows', n_noshow,
                            'gym_no_shows', n_gym, 'items', items);
end $$;

grant execute on function admin_mark_past_no_shows(boolean) to authenticated;

-- 3. Old combined function now only does the package part (in case anything
--    still calls it). It no longer creates no-shows.
create or replace function run_reconciliation() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return run_package_expiry();
end $$;

-- 4. Replace the nightly job: remove the old one, schedule package expiry only
--    (23:30 UTC, same time as before).
create extension if not exists pg_cron with schema extensions;
select cron.unschedule(jobid) from cron.job where jobname = 'repclub-nightly-reconciliation';
select cron.schedule(
  'repclub-nightly-package-expiry',
  '30 23 * * *',
  $$ select public.run_package_expiry(); $$
);

-- 5. Check: expect repclub-nightly-package-expiry and repclub-weekly-generate-slots,
--    and NO repclub-nightly-reconciliation.
select jobid, jobname, schedule, active from cron.job
 where jobname like 'repclub-%' order by jobname;
