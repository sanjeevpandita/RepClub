-- 15: Coach holidays / time off. Re-runnable.
--  * A coach (or the admin, for a coach) records a date range off.
--  * Their sessions in that range are cancelled, so members cannot book them (members only see
--    non-cancelled sessions and bookings_check refuses cancelled ones).
--  * Members already booked in the range: the app shows how many first; if the coach agrees, those
--    bookings are cancelled. Cancelling a BOOKED session never costs a credit.
--  * admin_generate_slots (also run weekly by the scheduled job) skips days a coach is off.
--  * Removing a holiday re-opens that coach's future sessions in the range (cancelled bookings
--    are NOT restored; members book again). Note: it also re-opens any session the admin had
--    cancelled by hand inside that range.

create table if not exists coach_time_off (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references coach_profiles (id) on delete cascade,
  start_date  date not null,
  end_date    date not null,
  note        text,
  created_by  uuid references profiles (id) default auth.uid(),
  created_at  timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists coach_time_off_coach on coach_time_off (coach_id, start_date);

alter table coach_time_off enable row level security;
drop policy if exists read_time_off on coach_time_off;
create policy read_time_off on coach_time_off for select to authenticated
  using (coach_id = auth.uid() or is_admin());
-- no write policies: changes go through the functions below

-- Which coach is acting: a coach acts for themself; the admin names the coach.
create or replace function _time_off_coach(p_coach uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if is_admin() then v := p_coach;
  elsif app_role() = 'COACH' then v := auth.uid();
  else raise exception 'Not allowed';
  end if;
  if v is null then raise exception 'Choose a coach'; end if;
  return v;
end $$;

-- How many members are booked with this coach in the range (for the "are you sure" step)
create or replace function coach_time_off_preview(p_start date, p_end date, p_coach uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid := _time_off_coach(p_coach); tz text; n int;
begin
  select gym_timezone into tz from app_settings;
  select count(*) into n
    from bookings b join slots s on s.id = b.slot_id
   where s.coach_id = v and b.status = 'BOOKED' and not s.is_cancelled
     and (s.starts_at at time zone tz)::date between p_start and p_end;
  return n;
end $$;

create or replace function coach_add_time_off(p_start date, p_end date, p_note text default null,
                                              p_cancel_bookings boolean default false,
                                              p_coach uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := _time_off_coach(p_coach); tz text; n int; v_id uuid;
begin
  if p_end < p_start then raise exception 'The end date is before the start date'; end if;
  if p_start < _gym_today() then raise exception 'Time off cannot start in the past'; end if;
  select gym_timezone into tz from app_settings;

  select count(*) into n
    from bookings b join slots s on s.id = b.slot_id
   where s.coach_id = v and b.status = 'BOOKED' and not s.is_cancelled
     and (s.starts_at at time zone tz)::date between p_start and p_end;
  if n > 0 and not p_cancel_bookings then
    raise exception '% member session(s) are booked in that period. Confirm to cancel them.', n;
  end if;

  -- cancel the bookings first (no credit is involved), then the sessions themselves
  update bookings b set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid()
    from slots s
   where s.id = b.slot_id and s.coach_id = v and b.status = 'BOOKED'
     and (s.starts_at at time zone tz)::date between p_start and p_end;
  update slots set is_cancelled = true
   where coach_id = v and not is_cancelled
     and (starts_at at time zone tz)::date between p_start and p_end;

  insert into coach_time_off (coach_id, start_date, end_date, note)
  values (v, p_start, p_end, nullif(trim(p_note), '')) returning id into v_id;
  perform _audit('COACH_TIME_OFF', 'coach_time_off', v_id::text, null,
                 jsonb_build_object('coach', v, 'from', p_start, 'to', p_end, 'bookings_cancelled', n),
                 null, p_note);
  return v_id;
end $$;

create or replace function coach_remove_time_off(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t coach_time_off; tz text;
begin
  select * into t from coach_time_off where id = p_id;
  if not found then raise exception 'Time off not found'; end if;
  if not (is_admin() or t.coach_id = auth.uid()) then raise exception 'Not allowed'; end if;
  select gym_timezone into tz from app_settings;
  delete from coach_time_off where id = p_id;
  -- re-open future sessions in the range that no other time off still covers
  update slots s set is_cancelled = false
   where s.coach_id = t.coach_id and s.is_cancelled and s.starts_at > now()
     and (s.starts_at at time zone tz)::date between t.start_date and t.end_date
     and not exists (select 1 from coach_time_off o
                      where o.coach_id = s.coach_id
                        and (s.starts_at at time zone tz)::date between o.start_date and o.end_date);
  perform _audit('COACH_TIME_OFF_REMOVED', 'coach_time_off', p_id::text,
                 jsonb_build_object('from', t.start_date, 'to', t.end_date), null, null, null);
end $$;

-- Slot generation (also used by the weekly job) now skips days a coach is off.
create or replace function admin_generate_slots(p_from date, p_to date) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admin only'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Choose a range of at most 62 days'; end if;

  with days as (select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d)
  insert into slots (coach_id, starts_at, ends_at, capacity)
  select w.coach_id,
         (days.day + make_time(w.hour, 0, 0)) at time zone s.gym_timezone,
         (days.day + make_time(w.hour, 0, 0)) at time zone s.gym_timezone + interval '1 hour',
         s.slot_capacity
  from days
  cross join app_settings s
  join coach_weekly_schedule w on w.weekday = extract(isodow from days.day)
  join profiles p on p.id = w.coach_id and p.is_active
  where coalesce((select o.is_open from gym_day_overrides o where o.day = days.day),
                 extract(isodow from days.day)::smallint = any (s.open_weekdays))
    and make_time(w.hour, 0, 0) >= s.open_time
    and make_time(w.hour, 0, 0) <= s.close_time - interval '1 hour'
    and not exists (select 1 from coach_time_off t
                     where t.coach_id = w.coach_id and days.day between t.start_date and t.end_date)
  on conflict (coach_id, starts_at) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- Only signed-in users may call these (each checks the role itself); helper is internal.
revoke execute on function _time_off_coach(uuid) from public, anon, authenticated;
revoke execute on function coach_time_off_preview(date, date, uuid) from public, anon;
revoke execute on function coach_add_time_off(date, date, text, boolean, uuid) from public, anon;
revoke execute on function coach_remove_time_off(uuid) from public, anon;
grant  execute on function coach_time_off_preview(date, date, uuid) to authenticated;
grant  execute on function coach_add_time_off(date, date, text, boolean, uuid) to authenticated;
grant  execute on function coach_remove_time_off(uuid) to authenticated;

-- A single session added by hand (admin Calendar > add one-off session) is refused on a day the
-- coach is off. Same rules as before, plus the time-off check.
create or replace function slots_check() returns trigger
language plpgsql as $$
declare s app_settings; t time; d date; open_day boolean;
begin
  select * into s from app_settings;
  t := (new.starts_at at time zone s.gym_timezone)::time;
  d := (new.starts_at at time zone s.gym_timezone)::date;
  select coalesce((select is_open from gym_day_overrides where day = d),
                  extract(isodow from d)::smallint = any (s.open_weekdays))
    into open_day;
  if not open_day then
    raise exception 'The gym is closed on %', d;
  end if;
  if t < s.open_time or t > s.close_time - interval '1 hour' then
    raise exception 'Slot at % is outside opening hours (% - %)', t, s.open_time, s.close_time;
  end if;
  if exists (select 1 from coach_time_off o
              where o.coach_id = new.coach_id and d between o.start_date and o.end_date) then
    raise exception 'This coach is on time off on %', d;
  end if;
  return new;
end $$;

-- Make the API pick up the new functions straight away.
notify pgrst, 'reload schema';
