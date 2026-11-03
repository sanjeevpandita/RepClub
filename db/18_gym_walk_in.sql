-- 18: Coached members may walk in for a personal gym visit by scanning the gym door QR. Re-runnable.
-- Run AFTER 17. Replaces gym_check_in.
--  * Member with a booked gym hour today: unchanged (must be inside the booked hour, valid Monthly Pass).
--  * Member WITH a coach and no gym booking today: a walk-in visit is recorded for the current hour
--    (status ATTENDED). No credit is used. Refused when the gym is outside opening hours, the current
--    hour already has gym_capacity members (gym + coached bookings), or the member has a coached
--    session booked today (they scan their coach's QR for that).
--  * Member WITHOUT a coach must have a valid Monthly Pass and a booking, as before.
create or replace function gym_check_in(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid := auth.uid(); today date; tz text; b gym_bookings; opens timestamptz;
        s app_settings; v_hour timestamptz; t time; open_day boolean; n int; v_coach uuid; v_id uuid;
begin
  if app_role() is distinct from 'MEMBER' then raise exception 'Only members can check in'; end if;
  if not exists (select 1 from gym_qr where token = p_token) then raise exception 'This QR code is not valid'; end if;
  select * into s from app_settings;
  tz := s.gym_timezone;
  today := _gym_today();

  select * into b from gym_bookings
   where member_id = v_member and booking_date = today and status in ('BOOKED', 'ATTENDED')
   order by created_at desc limit 1 for update;

  if found then
    if b.status = 'ATTENDED' then raise exception 'You are already checked in today'; end if;
    if not _has_valid_pass(v_member, today) then raise exception 'You need a valid Monthly Pass to use the gym'; end if;
    opens := b.hour_start - make_interval(mins => s.checkin_minutes_before);
    if now() < opens then raise exception 'Check-in opens at %', to_char(opens at time zone tz, 'HH24:MI'); end if;
    if now() > b.hour_start + interval '1 hour' then
      raise exception 'Check-in closed at %', to_char((b.hour_start + interval '1 hour') at time zone tz, 'HH24:MI');
    end if;
    update gym_bookings set status = 'ATTENDED', checked_in_at = now() where id = b.id;
    return jsonb_build_object('booking_id', b.id, 'checked_in_at', now(), 'hour_start', b.hour_start, 'walk_in', false);
  end if;

  -- no gym booking today: only a member with a coach may walk in
  select primary_coach_id into v_coach from member_profiles where id = v_member;
  if v_coach is null then raise exception 'You have no gym booking for today'; end if;
  if exists (select 1 from bookings where member_id = v_member and booking_date = today
               and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
    raise exception 'You have a coached session today. Scan your coach''s QR code for it.';
  end if;

  v_hour := date_trunc('hour', now());
  t := (v_hour at time zone tz)::time;
  select coalesce((select is_open from gym_day_overrides where day = today),
                  extract(isodow from today)::smallint = any (s.open_weekdays)) into open_day;
  if not open_day or t < s.open_time or t > s.close_time - interval '1 hour' then
    raise exception 'The gym is closed right now';
  end if;

  perform pg_advisory_xact_lock(hashtext('gym-hour-' || v_hour::text));
  n := _members_in_hour(v_hour);
  if n >= s.gym_capacity then
    raise exception 'The gym is full right now (% of % places taken)', n, s.gym_capacity;
  end if;

  insert into gym_bookings (member_id, hour_start, booking_date, status, checked_in_at, created_by)
  values (v_member, v_hour, today, 'ATTENDED', now(), v_member) returning id into v_id;
  return jsonb_build_object('booking_id', v_id, 'checked_in_at', now(), 'hour_start', v_hour, 'walk_in', true);
end $$;

notify pgrst, 'reload schema';
