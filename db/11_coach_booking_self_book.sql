-- 11: Coach books/cancels/moves sessions for their own members, and decides per member
-- whether the member may book for themselves. Re-runnable.
--  * member_profiles.can_self_book (default true). Only the member's coach or an admin changes it.
--  * create_booking: MEMBER callers are refused when can_self_book is false; a COACH may book
--    for their own member (the booking rules still apply: package, capacity, own-coach slot, 1/day).
--  * cancel_booking / reschedule_booking: a coach may act for their own member. Inside the 12 h lock
--    a coach is refused like a member (only admin may override, with a reason).

alter table member_profiles add column if not exists can_self_book boolean not null default true;

create or replace function set_can_self_book(p_member uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (is_admin() or coach_has_member(p_member)) then raise exception 'Not allowed'; end if;
  update member_profiles set can_self_book = p_value where id = p_member;
end $$;
revoke execute on function set_can_self_book(uuid, boolean) from public;
grant  execute on function set_can_self_book(uuid, boolean) to authenticated;

create or replace function create_booking(p_slot uuid, p_member uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_member uuid; s slots; pkg member_packages; d date; v_id uuid; committed int; tz text;
begin
  if is_admin() then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
  elsif app_role() = 'COACH' then
    v_member := p_member;
    if v_member is null then raise exception 'Choose a member'; end if;
    if not coach_has_member(v_member) then raise exception 'This is not your member'; end if;
  elsif app_role() = 'MEMBER' then
    v_member := auth.uid();
    if not (select can_self_book from member_profiles where id = v_member) then
      raise exception 'Your coach books your sessions. Please ask your coach.';
    end if;
  else
    raise exception 'Not allowed';
  end if;
  if not exists (select 1 from profiles where id = v_member and role = 'MEMBER' and is_active) then
    raise exception 'This member account is not active';
  end if;

  select * into s from slots where id = p_slot;
  if not found then raise exception 'Session not found'; end if;
  if s.starts_at <= now() then raise exception 'This session has already started'; end if;

  select gym_timezone into tz from app_settings;
  d := (s.starts_at at time zone tz)::date;

  select * into pkg from member_packages where member_id = v_member and status = 'ACTIVE';
  if not found then raise exception 'No active package'; end if;
  if d < pkg.start_date or d > pkg.expiry_date then
    raise exception 'The active package is not valid on %', d;
  end if;
  select count(*) into committed from bookings where member_id = v_member and status = 'BOOKED';
  if _balance(pkg.id) - committed < 1 then
    raise exception 'All remaining credits are already booked';
  end if;

  insert into bookings (member_id, slot_id, booking_date, created_by)
  values (v_member, p_slot, d, auth.uid()) returning id into v_id;   -- capacity, coach and one-per-day rules fire here
  return v_id;
end $$;

create or replace function cancel_booking(p_booking uuid, p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; locked boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid() or coach_has_member(b.member_id)) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be cancelled (this one is %)', b.status; end if;
  select * into s from slots where id = b.slot_id;
  select now() > s.starts_at - make_interval(hours => cancel_lock_hours) into locked from app_settings;

  if locked then
    if not is_admin() then
      raise exception 'This session starts within 12 hours, so it can no longer be cancelled. Please contact the gym.';
    end if;
    perform _check_reason(p_reason, p_note);
    perform _audit('CANCEL_INSIDE_LOCK', 'bookings', b.id::text, null, null, p_reason, p_note);
  end if;

  update bookings set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid() where id = p_booking;
end $$;

create or replace function reschedule_booking(p_booking uuid, p_new_slot uuid,
                                              p_reason reason_code default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; s slots; ns slots; locked boolean; pkg member_packages; tz text; nd date;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if not (is_admin() or b.member_id = auth.uid() or coach_has_member(b.member_id)) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be rescheduled'; end if;

  select * into s from slots where id = b.slot_id;
  select now() > s.starts_at - make_interval(hours => cancel_lock_hours) into locked from app_settings;
  if locked then
    if not is_admin() then
      raise exception 'This session starts within 12 hours, so it can no longer be moved. Please contact the gym.';
    end if;
    perform _check_reason(p_reason, p_note);
    perform _audit('RESCHEDULE_INSIDE_LOCK', 'bookings', b.id::text, null, null, p_reason, p_note);
  end if;

  select * into ns from slots where id = p_new_slot;
  if not found then raise exception 'New session not found'; end if;
  if ns.starts_at <= now() then raise exception 'The new session has already started'; end if;
  select gym_timezone into tz from app_settings;
  nd := (ns.starts_at at time zone tz)::date;
  select * into pkg from member_packages where member_id = b.member_id and status = 'ACTIVE';
  if not found or nd < pkg.start_date or nd > pkg.expiry_date then
    raise exception 'The active package is not valid on %', nd;
  end if;

  update bookings set slot_id = p_new_slot where id = p_booking;     -- capacity / coach / one-per-day rules fire here
end $$;
