-- =====================================================================
-- REPCLUB  |  00_reset.sql
-- Deletes every RepClub table, function and type so 01_schema.sql can
-- run from scratch. ALL RepClub data in these tables is lost.
-- Your Supabase LOGINS (Authentication > Users) are NOT touched.
-- =====================================================================

drop view if exists member_package_balances;

drop table if exists
  audit_log, notification_settings, weight_logs, equipment, attendance,
  bookings, slots, gym_day_overrides, coach_weekly_schedule,
  credit_transactions, member_packages, package_types,
  member_profiles, coach_profiles, profiles, app_settings
  cascade;

drop function if exists audit_row()             cascade;
drop function if exists ledger_protect()        cascade;
drop function if exists slots_check()           cascade;
drop function if exists bookings_check()        cascade;
drop function if exists coach_has_member(uuid)  cascade;
drop function if exists is_admin()              cascade;
drop function if exists app_role()              cascade;

drop type if exists attendance_method, reason_code, credit_txn_type,
  booking_status, package_status, user_role cascade;
