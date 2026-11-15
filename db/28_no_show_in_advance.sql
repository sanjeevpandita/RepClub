-- 28_no_show_in_advance.sql
-- Owner request (2026-11-15): a coach (or admin) may mark a member's booked
-- session as a no-show BEFORE it starts, e.g. a member who has gone away for a
-- week without telling anyone. Same effect as a normal no-show: the booking
-- becomes NO_SHOW (the session stays taken) and 1 credit is taken straight away.
-- The admin can still give the credit back with "Waive no-show".
-- Only change from 03_functions.sql: the "session has not started yet" check is
-- removed. Re-runnable. Run after 01-27.

create or replace function mark_no_show(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; s slots;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  select * into s from slots where id = b.slot_id;
  if not (is_admin() or (app_role() = 'COACH' and s.coach_id = auth.uid())) then raise exception 'Not allowed'; end if;
  if b.status <> 'BOOKED' then raise exception 'Only a booked session can be marked as no-show'; end if;

  update bookings set status = 'NO_SHOW' where id = b.id;
  perform _consume_credit(b.member_id, 'NO_SHOW', b.id, b.booking_date, auth.uid(), false);
end $$;
