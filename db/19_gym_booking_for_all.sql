-- 19: EVERYONE books a gym hour first (no walk-ins). Re-runnable. Run AFTER 17 and 18. Supersedes db/18.
--  * A member may book gym time if they have a valid Monthly Pass OR a coach.
--  * gym_check_in: needs a gym booking for today, inside the booked hour. No walk-in any more.
--  * Capacity (gym_capacity members per hour, gym + coached bookings) is checked when booking.
--  * gym_presence: visible to admin and to members who may use the gym (pass or coach).

create or replace function _can_use_gym(p_member uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select _has_valid_pass(p_member, p_day)
      or exists (select 1 from member_profiles where id = p_member and primary_coach_id is not null)
$$;
revoke execute on function _can_use_gym(uuid, date) from public, anon, authenticated;

create or replace function book_gym_hour(p_hour timestamptz, p_member uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_member uuid; s app_settings; d date; t time; open_day boolean; n int; v_id uuid;
begin
  if is_admin() then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
  elsif app_role() = 'COACH' then
    v_member := p_member;
    if v_member is null or not coach_has_member(v_member) then raise exception 'This is not your member'; end if;
  elsif app_role() = 'MEMBER' then
    v_member := auth.uid();
  else
    raise exception 'Not allowed';
  end if;
  if not exists (select 1 from profiles where id = v_member and role = 'MEMBER' and is_active) then
    raise exception 'This member account is not active';
  end if;

  select * into s from app_settings;
  if extract(epoch from p_hour)::bigint % 3600 <> 0 then raise exception 'Choose a full hour'; end if;
  if p_hour + interval '1 hour' <= now() then raise exception 'This hour is already over'; end if;
  d := (p_hour at time zone s.gym_timezone)::date;
  t := (p_hour at time zone s.gym_timezone)::time;
  select coalesce((select is_open from gym_day_overrides where day = d),
                  extract(isodow from d)::smallint = any (s.open_weekdays)) into open_day;
  if not open_day then raise exception 'The gym is closed on %', d; end if;
  if t < s.open_time or t > s.close_time - interval '1 hour' then raise exception 'That hour is outside opening hours'; end if;

  if not _can_use_gym(v_member, d) then
    raise exception 'A valid Monthly Pass (or a coach) is needed to book gym time on %', d;
  end if;
  if exists (select 1 from gym_bookings where member_id = v_member and booking_date = d
               and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
    raise exception 'You already have a gym booking on that day';
  end if;
  if exists (select 1 from bookings where member_id = v_member and booking_date = d
               and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
    raise exception 'You already have a coached session on that day';
  end if;

  perform pg_advisory_xact_lock(hashtext('gym-hour-' || p_hour::text));
  n := _members_in_hour(p_hour);
  if n >= s.gym_capacity then
    raise exception 'The gym is full at this time (% of % places taken)', n, s.gym_capacity;
  end if;

  insert into gym_bookings (member_id, hour_start, booking_date, created_by)
  values (v_member, p_hour, d, auth.uid()) returning id into v_id;
  return v_id;
end $$;

create or replace function gym_check_in(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid := auth.uid(); today date; tz text; b gym_bookings; opens timestamptz;
begin
  if app_role() is distinct from 'MEMBER' then raise exception 'Only members can check in'; end if;
  if not exists (select 1 from gym_qr where token = p_token) then raise exception 'This QR code is not valid'; end if;
  select gym_timezone into tz from app_settings;
  today := _gym_today();

  select * into b from gym_bookings
   where member_id = v_member and booking_date = today and status in ('BOOKED', 'ATTENDED')
   order by created_at desc limit 1 for update;
  if not found then
    raise exception 'You have no gym booking for today. Please book a gym hour first.';
  end if;
  if b.status = 'ATTENDED' then raise exception 'You are already checked in today'; end if;
  if not _can_use_gym(v_member, today) then raise exception 'You need a valid Monthly Pass or a coach to use the gym'; end if;

  opens := b.hour_start - make_interval(mins => (select checkin_minutes_before from app_settings));
  if now() < opens then raise exception 'Check-in opens at %', to_char(opens at time zone tz, 'HH24:MI'); end if;
  if now() > b.hour_start + interval '1 hour' then
    raise exception 'Check-in closed at %', to_char((b.hour_start + interval '1 hour') at time zone tz, 'HH24:MI');
  end if;

  update gym_bookings set status = 'ATTENDED', checked_in_at = now() where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'checked_in_at', now(), 'hour_start', b.hour_start, 'walk_in', false);
end $$;

create or replace function gym_presence(p_hour timestamptz)
returns table (who text, state text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_admin() or (app_role() = 'MEMBER' and _can_use_gym(auth.uid(), _gym_today()))) then
    raise exception 'Only gym members can see who is in the gym';
  end if;
  return query
  select _short_name(p.full_name), case x.status when 'ATTENDED' then 'CHECKED_IN' else 'BOOKED' end
  from (
    select member_id, status from gym_bookings
     where hour_start = p_hour and status in ('BOOKED', 'ATTENDED')
    union all
    select b.member_id, b.status from bookings b join slots sl on sl.id = b.slot_id
     where sl.starts_at = p_hour and not sl.is_cancelled and b.status in ('BOOKED', 'ATTENDED')
  ) x
  join profiles p on p.id = x.member_id
  order by 2 desc, 1;
end $$;

notify pgrst, 'reload schema';
