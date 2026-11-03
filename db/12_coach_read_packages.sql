-- 12: A coach may read their own members' packages and credit ledger (read-only).
-- Without this, member_package_balances (security_invoker) returns nothing for a coach.
-- Re-runnable.
drop policy if exists coach_read_packages on member_packages;
create policy coach_read_packages on member_packages for select to authenticated
  using (coach_has_member(member_id));

drop policy if exists coach_read_credits on credit_transactions;
create policy coach_read_credits on credit_transactions for select to authenticated
  using (coach_has_member(member_id));
