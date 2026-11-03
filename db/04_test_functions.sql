-- =====================================================================
-- REPCLUB  |  04_test_functions.sql
-- Self-test of 03_functions.sql. Acts as Admin / Sky / Nando, tries the
-- main actions, and prints PASS/FAIL per step. Everything is ROLLED BACK
-- at the end, so no test data is left behind.
-- Uses the emails from 02_seed_test_data.sql (edit if you changed them).
-- =====================================================================
-- The whole test is ONE statement. It finishes with a deliberate error that
-- carries the report; that error is what rolls everything back. So an
-- "error" titled TEST REPORT is the normal, expected outcome.
do $$
declare
  v_admin uuid := (select id from auth.users where email = 'admin@repclub-test.com');
  v_sky   uuid := (select id from auth.users where email = 'member.sky@repclub-test.com');
  v_nando uuid := (select id from auth.users where email = 'coach.nando@repclub-test.com');
  v_thal  uuid := (select id from auth.users where email = 'coach.thalyta@repclub-test.com');
  v_type  uuid := (select id from package_types where name = 'REP10');
  v_pkg uuid; v_slot uuid; v_slot2 uuid; v_bad uuid; v_book uuid; bal int; n int;
begin
  create temp table t_log (n serial, step text, result text) on commit drop;

  -- act as Admin first (set_config fakes the signed-in user)
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. generate slots for the next 14 days
  begin
    n := admin_generate_slots(current_date + 1, current_date + 14);
    insert into t_log (step, result) values ('Generate slots (14 days)', case when n > 0 then 'PASS: ' || n || ' slots' else 'FAIL: 0 slots' end);
  exception when others then insert into t_log (step, result) values ('Generate slots', 'FAIL: ' || sqlerrm); end;

  -- 2. assign + activate a REP10 package to Sky
  begin
    v_pkg := admin_assign_package(v_sky, v_type, current_date, current_date, current_date + 90, 10, 'test', true);
    bal := _balance(v_pkg);
    insert into t_log (step, result) values ('Assign + activate package (10 credits)', case when bal = 10 then 'PASS' else 'FAIL: balance ' || bal end);
  exception when others then insert into t_log (step, result) values ('Assign + activate package', 'FAIL: ' || sqlerrm); end;

  -- 3. a second package must stay queued (cannot activate while one is active)
  begin
    perform admin_activate_package(admin_assign_package(v_sky, v_type, current_date, current_date, current_date + 90, 5));
    insert into t_log (step, result) values ('Second package refused while one active', 'FAIL: it activated');
  exception when others then insert into t_log (step, result) values ('Second package refused while one active', 'PASS: ' || sqlerrm); end;

  -- 4. adjust credits +1 (reason) and refuse without reason
  begin
    bal := admin_adjust_credits(v_sky, 1, 'GOODWILL', 'test');
    insert into t_log (step, result) values ('Adjust +1 with reason', case when bal = 11 then 'PASS' else 'FAIL: ' || bal end);
  exception when others then insert into t_log (step, result) values ('Adjust +1 with reason', 'FAIL: ' || sqlerrm); end;
  begin
    perform admin_adjust_credits(v_sky, 1, null, null);
    insert into t_log (step, result) values ('Adjust without reason refused', 'FAIL: it worked');
  exception when others then insert into t_log (step, result) values ('Adjust without reason refused', 'PASS: ' || sqlerrm); end;

  -- pick a Nando slot more than 13h ahead (outside the 12h lock) and a Thalyta slot
  select id into v_slot  from slots where coach_id = v_nando and starts_at > now() + interval '13 hours' order by starts_at limit 1;
  select id into v_slot2 from slots where coach_id = v_nando and starts_at > now() + interval '13 hours'
                          and id <> v_slot and (starts_at at time zone 'Europe/Dublin')::date > (select (starts_at at time zone 'Europe/Dublin')::date from slots where id = v_slot)
                          order by starts_at limit 1;
  select id into v_bad   from slots where coach_id = v_thal  and starts_at > now() + interval '13 hours' order by starts_at limit 1;

  -- 5. Sky books Nando's slot (acting as Sky)
  perform set_config('request.jwt.claims', json_build_object('sub', v_sky, 'role', 'authenticated')::text, true);
  begin
    v_book := create_booking(v_slot);
    insert into t_log (step, result) values ('Sky books own coach slot', 'PASS');
  exception when others then insert into t_log (step, result) values ('Sky books own coach slot', 'FAIL: ' || sqlerrm); end;

  -- 6. same day twice refused
  begin
    perform create_booking(v_slot);
    insert into t_log (step, result) values ('Second booking same day refused', 'FAIL: it worked');
  exception when others then insert into t_log (step, result) values ('Second booking same day refused', 'PASS: ' || sqlerrm); end;

  -- 7. other coach's slot refused
  begin
    perform create_booking(v_bad);
    insert into t_log (step, result) values ('Other coach slot refused', 'FAIL: it worked');
  exception when others then insert into t_log (step, result) values ('Other coach slot refused', 'PASS: ' || sqlerrm); end;

  -- 8. reschedule to the next day, then cancel (outside 12h = free)
  begin
    perform reschedule_booking(v_book, v_slot2);
    insert into t_log (step, result) values ('Reschedule outside 12h', 'PASS');
  exception when others then insert into t_log (step, result) values ('Reschedule outside 12h', 'FAIL: ' || sqlerrm); end;
  begin
    perform cancel_booking(v_book);
    insert into t_log (step, result) values ('Cancel outside 12h', 'PASS');
  exception when others then insert into t_log (step, result) values ('Cancel outside 12h', 'FAIL: ' || sqlerrm); end;

  -- 9. Admin books for Sky, then records manual attendance -> 1 credit used
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  begin
    v_book := create_booking(v_slot, v_sky);
    perform admin_manual_attendance(v_book, 'OTHER', 'test: phone dead');
    bal := _balance(v_pkg);
    insert into t_log (step, result) values ('Admin booking + manual attendance deducts 1 credit', case when bal = 10 then 'PASS (balance 10)' else 'FAIL: balance ' || bal end);
  exception when others then insert into t_log (step, result) values ('Admin booking + manual attendance', 'FAIL: ' || sqlerrm); end;

  -- 10. member cannot call admin functions
  perform set_config('request.jwt.claims', json_build_object('sub', v_sky, 'role', 'authenticated')::text, true);
  begin
    perform admin_adjust_credits(v_sky, 5, 'GOODWILL');
    insert into t_log (step, result) values ('Member cannot adjust own credits', 'FAIL: it worked');
  exception when others then insert into t_log (step, result) values ('Member cannot adjust own credits', 'PASS: ' || sqlerrm); end;

  raise exception E'TEST REPORT (rolled back on purpose, nothing was saved)\n%',
    (select string_agg(t.n || '. ' || t.step || ' -> ' || t.result, E'\n' order by t.n) from t_log t);
end $$;
