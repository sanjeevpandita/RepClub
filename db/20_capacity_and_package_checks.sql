-- 20: Audit fixes S-08 and S-02 (partial). Re-runnable. Run AFTER 17 and 19.
--  * S-08: a coached booking now respects gym_capacity (members per hour, gym + coached) and takes
--          the same advisory lock as book_gym_hour, so two people cannot take the last place at once.
--  * S-02: admin_assign_package refuses an inactive package type.
--          (Owner decision: coaches may still choose credits and dates freely.)

-- ---------- S-08: capacity check on coached bookings ----------------------
create or replace function bookings_check() returns trigger
language plpgsql as $$
declare s slots; tz text; taken int; coach uuid; cap int; in_hour int;
begin
  select * into s from slots where id = new.slot_id for update;
  select gym_timezone, gym_capacity into tz, cap from app_settings;
  new.booking_date := (s.starts_at at time zone tz)::date;

  if new.status <> 'CANCELLED'
     and (tg_op = 'INSERT' or new.slot_id is distinct from old.slot_id or old.status = 'CANCELLED') then
    if s.is_cancelled then
      raise exception 'This session has been cancelled';
    end if;
    select primary_coach_id into coach from member_profiles where id = new.member_id;
    if coach is distinct from s.coach_id then
      raise exception 'Member can only book their own coach''s sessions';
    end if;
    if exists (select 1 from gym_bookings where member_id = new.member_id and booking_date = new.booking_date
                  and status in ('BOOKED', 'ATTENDED', 'NO_SHOW')) then
      raise exception 'This member already has a gym booking on that day';
    end if;
    select count(*) into taken from bookings
      where slot_id = new.slot_id and status <> 'CANCELLED' and id <> new.id;
    if taken >= s.capacity then
      raise exception 'This session is full';
    end if;

    -- Same lock key as book_gym_hour, so gym and coached bookings serialise per hour.
    perform pg_advisory_xact_lock(hashtext('gym-hour-' || s.starts_at::text));
    in_hour := _members_in_hour(s.starts_at);
    if in_hour >= cap then
      raise exception 'The gym is full at this time (% of % places taken)', in_hour, cap;
    end if;
  end if;
  return new;
end $$;

-- ---------- S-02: no assigning an inactive package type -------------------
create or replace function admin_assign_package(
  p_member uuid, p_package_type uuid, p_purchase_date date, p_start_date date, p_expiry_date date,
  p_starting_credits int, p_payment_note text default null, p_activate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare pt package_types; v_id uuid; v_credits int;
begin
  if not (is_admin() or coach_has_member(p_member)) then
    raise exception 'Only the admin or the member''s own coach can assign a package';
  end if;
  select * into pt from package_types where id = p_package_type;
  if not found then raise exception 'Package type not found'; end if;
  if not pt.is_active then raise exception 'This package type is switched off and cannot be assigned'; end if;
  if pt.kind = 'PASS' then
    v_credits := 0;
  else
    if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
    v_credits := p_starting_credits;
  end if;
  insert into member_packages (member_id, package_type_id, package_name, kind, purchase_date, start_date,
                               expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, pt.kind, p_purchase_date, p_start_date,
          p_expiry_date, v_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

-- ---------- Quick check (read-only) --------------------------------------
-- select proname from pg_proc where proname in ('bookings_check','admin_assign_package');
