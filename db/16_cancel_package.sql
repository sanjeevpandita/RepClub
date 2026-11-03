-- 16: Cancel / remove a member package created by mistake. Re-runnable.
-- Allowed for the admin and for the member's own coach. A reason is required and audited.
--  * A package that never got credits (still QUEUED, no ledger rows) is deleted outright.
--  * Otherwise the credits still left are taken off with an adjustment row (the ledger is never
--    edited), the package is marked CANCELLED, and if it was the active one the member's next
--    queued package starts. Credits already used stay used.
create or replace function admin_cancel_package(p_package uuid, p_reason reason_code, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare pkg member_packages; bal int; was_active boolean;
begin
  select * into pkg from member_packages where id = p_package for update;
  if not found then raise exception 'Package not found'; end if;
  if not (is_admin() or coach_has_member(pkg.member_id)) then
    raise exception 'Only the admin or the member''s own coach can cancel a package';
  end if;
  perform _check_reason(p_reason, p_note);
  if pkg.status = 'CANCELLED' then raise exception 'This package is already cancelled'; end if;
  if pkg.status = 'EXPIRED' then raise exception 'An expired package is history and cannot be cancelled'; end if;

  if not exists (select 1 from credit_transactions where member_package_id = pkg.id) then
    delete from member_packages where id = pkg.id;
    perform _audit('PACKAGE_DELETED', 'member_packages', pkg.id::text,
                   jsonb_build_object('package', pkg.package_name, 'member', pkg.member_id), null, p_reason, p_note);
    return 'deleted';
  end if;

  was_active := pkg.status = 'ACTIVE';
  bal := _balance(pkg.id);
  if bal > 0 then
    insert into credit_transactions (member_id, member_package_id, type, delta, reason_code, note, created_by)
    values (pkg.member_id, pkg.id, 'ADMIN_ADJUSTMENT', -bal, p_reason,
            coalesce(nullif(trim(p_note), ''), 'Package cancelled'), auth.uid());
  end if;
  update member_packages set status = 'CANCELLED' where id = pkg.id;
  if was_active then perform _activate_next(pkg.member_id); end if;
  perform _audit('PACKAGE_CANCELLED', 'member_packages', pkg.id::text,
                 jsonb_build_object('balance', bal), null, p_reason, p_note);
  return 'cancelled';
end $$;

revoke execute on function admin_cancel_package(uuid, reason_code, text) from public, anon;
grant  execute on function admin_cancel_package(uuid, reason_code, text) to authenticated;

-- Make the API pick up the new function straight away.
notify pgrst, 'reload schema';
