-- 27: A member can hold only ONE credit package and ONE Monthly Pass at a time. Re-runnable. Run AFTER 26.
--
-- Owner decision (2026-11-15): no more queuing a second package of the same kind. Assigning a credit
-- package is refused while the member has a credit package that is ACTIVE or QUEUED (waiting to start);
-- the same for a Monthly Pass. A used-up (EXHAUSTED), EXPIRED or CANCELLED package does not count, so a
-- new one can be assigned once the old one is finished or has been cancelled.
-- Packages already queued before this script stay as they are (nothing is deleted).
-- admin_assign_package is the same as in db/26 plus the check below.

create or replace function admin_assign_package(
  p_member uuid, p_package_type uuid, p_purchase_date date, p_start_date date, p_expiry_date date,
  p_starting_credits int, p_payment_note text default null, p_activate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare pt package_types; v_id uuid; v_credits int; cur member_packages;
begin
  if not (is_admin() or coach_has_member(p_member)) then
    raise exception 'Only the admin or the member''s own coach can assign a package';
  end if;
  select * into pt from package_types where id = p_package_type;
  if not found then raise exception 'Package type not found'; end if;
  if not pt.is_active then raise exception 'This package type is switched off and cannot be assigned'; end if;

  -- One credit package and one Monthly Pass at a time.
  perform pg_advisory_xact_lock(hashtext('assign-package-' || p_member::text));
  select * into cur from member_packages
   where member_id = p_member and kind = pt.kind and status in ('ACTIVE', 'QUEUED')
   order by created_at limit 1;
  if found then
    raise exception 'This member already has a % (%, %). Cancel it before assigning a new one.',
      case when pt.kind = 'PASS' then 'Monthly Pass' else 'credit package' end,
      cur.package_name,
      case when cur.status = 'ACTIVE' then 'active' else 'waiting to start' end;
  end if;

  if pt.kind = 'PASS' then
    v_credits := 0;
  else
    if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
    v_credits := p_starting_credits;
  end if;
  insert into member_packages (member_id, package_type_id, package_name, kind, session_minutes, purchase_date,
                               start_date, expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, pt.kind,
          case when pt.kind = 'PASS' then 60 else pt.session_minutes end,
          p_purchase_date, p_start_date, p_expiry_date, v_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

notify pgrst, 'reload schema';

-- ---------- Quick check (read-only): members who STILL have two of one kind (queued before this script)
-- select p.full_name, mp.kind, count(*) from member_packages mp join profiles p on p.id = mp.member_id
--  where mp.status in ('ACTIVE', 'QUEUED') group by 1, 2 having count(*) > 1;
