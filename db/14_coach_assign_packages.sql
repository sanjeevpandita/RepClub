-- 14: A member's own coach may assign and activate packages for that member, like the admin.
-- Same function names/signatures as before, so the Admin app keeps working unchanged.
-- Requires db/12 so the coach can also READ packages and credits. Re-runnable.

create or replace function admin_assign_package(
  p_member uuid, p_package_type uuid, p_purchase_date date, p_start_date date, p_expiry_date date,
  p_starting_credits int, p_payment_note text default null, p_activate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare pt package_types; v_id uuid;
begin
  if not (is_admin() or coach_has_member(p_member)) then
    raise exception 'Only the admin or the member''s own coach can assign a package';
  end if;
  select * into pt from package_types where id = p_package_type;
  if not found then raise exception 'Package type not found'; end if;
  if p_starting_credits < 1 then raise exception 'Starting credits must be at least 1'; end if;
  insert into member_packages (member_id, package_type_id, package_name, purchase_date, start_date,
                               expiry_date, starting_credits, payment_note, created_by)
  values (p_member, p_package_type, pt.name, p_purchase_date, p_start_date,
          p_expiry_date, p_starting_credits, p_payment_note, auth.uid())
  returning id into v_id;
  if p_activate then perform _activate_package(v_id, auth.uid()); end if;
  return v_id;
end $$;

create or replace function admin_activate_package(p_member_package uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_member uuid;
begin
  select member_id into v_member from member_packages where id = p_member_package;
  if not found then raise exception 'Package not found'; end if;
  if not (is_admin() or coach_has_member(v_member)) then
    raise exception 'Only the admin or the member''s own coach can activate a package';
  end if;
  perform _activate_package(p_member_package, auth.uid());
end $$;
