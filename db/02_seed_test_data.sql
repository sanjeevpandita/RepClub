-- =====================================================================
-- REPCLUB  |  02_seed_test_data.sql
-- Run AFTER 01_schema.sql. Turns your 6 Supabase logins into real
-- Admin / Coach / Member profiles, plus sample packages and schedules.
-- Logins are matched by EMAIL. If yours differ, edit the emails below.
-- =====================================================================

-- 1. Roles and names (edit the emails to match what you created)
create temp table seed_people (email text, role user_role, full_name text, coach_email text) on commit drop;
insert into seed_people values
  ('admin@repclub-test.com',           'ADMIN',  'Gym Owner',       null),
  ('coach.thalyta@repclub-test.com',   'COACH',  'Thalyta Coach',   null),
  ('coach.nando@repclub-test.com',     'COACH',  'Nando Coach',     null),
  ('member.sanjeev@repclub-test.com',  'MEMBER', 'Sanjeev Member',  'coach.thalyta@repclub-test.com'),
  ('member.carla@repclub-test.com',    'MEMBER', 'Carla Member',    'coach.nando@repclub-test.com'),
  ('member.sky@repclub-test.com',      'MEMBER', 'Sky Member',      'coach.nando@repclub-test.com');

insert into profiles (id, role, full_name, email)
select u.id, p.role, p.full_name, u.email
from seed_people p join auth.users u on lower(u.email) = lower(p.email);

insert into coach_profiles (id)
select pr.id from profiles pr where pr.role = 'COACH';

insert into member_profiles (id, primary_coach_id)
select m.id, c.id
from seed_people p
join auth.users mu on lower(mu.email) = lower(p.email)
join profiles m on m.id = mu.id
join auth.users cu on lower(cu.email) = lower(p.coach_email)
join coach_profiles c on c.id = cu.id
where p.role = 'MEMBER';

-- 2. Sample package types (validity days are test values; change in the Admin app later)
insert into package_types (name, credits, price_eur, validity_days) values
  ('Starter',  2,  50.00, 30),
  ('Standard', 5, 110.00, 60),
  ('REP10',   10, 200.00, 90);

-- 3. Weekly pattern (Mon-Sat): Thalyta 12:00-20:00, Nando 06:00-18:00
--    (gym open days live in app_settings.open_weekdays; one-off changes in gym_day_overrides)
insert into coach_weekly_schedule (coach_id, weekday, hour)
select pr.id, d, h
from profiles pr
join generate_series(1, 6) d on true
join generate_series(12, 19) h on pr.full_name = 'Thalyta Coach'
union all
select pr.id, d, h
from profiles pr
join generate_series(1, 6) d on true
join generate_series(6, 17) h on pr.full_name = 'Nando Coach';

-- 4. Check: should list 6 people (1 ADMIN, 2 COACH, 3 MEMBER)
select p.role, p.full_name, p.email, c.full_name as coach
from profiles p
left join member_profiles m on m.id = p.id
left join profiles c on c.id = m.primary_coach_id
order by p.role, p.full_name;
