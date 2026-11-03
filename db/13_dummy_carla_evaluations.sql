-- 13: TEST DATA ONLY. Three body evaluations for member.carla@repclub-test.com.
-- Set 1 is the sample from the owner; sets 2 and 3 show gradual progress (weight and waist down,
-- arms/shoulders up) so the Body Map arrows have something to show.
-- Re-runnable: it first removes earlier rows it created (notes start with 'DUMMY').
-- Run in the Supabase SQL Editor (needs table body_evaluations from db/10).

delete from body_evaluations
 where notes like 'DUMMY%'
   and member_id = (select id from auth.users where email = 'member.carla@repclub-test.com');

insert into body_evaluations (
  member_id, coach_id, evaluated_on, method,
  weight_kg, body_fat_pct, lean_weight_kg, fat_weight_kg,
  suprailiac_mm, bicep_mm, tricep_mm, subscapular_mm,
  bicep_right_cm, bicep_left_cm, forearm_right_cm, forearm_left_cm,
  thigh_upper_right_cm, thigh_upper_left_cm, thigh_mid_right_cm, thigh_mid_left_cm,
  calf_right_cm, calf_left_cm, neck_cm, chest_cm, shoulders_cm, waist_cm, hips_cm, notes)
select u.id, mp.primary_coach_id, v.evaluated_on::date, 'Durnin/Womersley',
       v.weight_kg, v.body_fat_pct, v.lean_weight_kg, v.fat_weight_kg,
       v.suprailiac_mm, v.bicep_mm, v.tricep_mm, v.subscapular_mm,
       v.bicep_right_cm, v.bicep_left_cm, v.forearm_right_cm, v.forearm_left_cm,
       v.thigh_upper_right_cm, v.thigh_upper_left_cm, v.thigh_mid_right_cm, v.thigh_mid_left_cm,
       v.calf_right_cm, v.calf_left_cm, v.neck_cm, v.chest_cm, v.shoulders_cm, v.waist_cm, v.hips_cm,
       v.notes
from auth.users u
join member_profiles mp on mp.id = u.id
cross join (values
  -- evaluated_on, weight, body fat %, lean, fat weight, suprailiac, bicep, tricep, subscapular,
  -- bicep R, bicep L, forearm R, forearm L, thigh upper R, thigh upper L, thigh mid R, thigh mid L,
  -- calf R, calf L, neck, chest, shoulders, waist, hips, notes
  ('2021-08-20', 86.80, 28.13, 62.38, 24.42, 29.4, 8.0, 11.2, 16.0,
   30.5, 29.5, 27.5, 27.5, 62.5, 63.0, 56.5, 56.5,
   40.0, 40.0, 38.5, 101.0, 116.5, 95.0, 103.0, 'DUMMY test data - first evaluation'),
  ('2021-11-19', 84.20, 26.40, 61.97, 22.23, 27.0, 7.6, 10.4, 14.8,
   31.0, 30.0, 27.8, 27.6, 61.5, 62.0, 55.5, 55.5,
   39.5, 39.5, 38.0, 100.0, 117.0, 91.0, 101.0, 'DUMMY test data - 3 months on'),
  ('2022-02-18', 81.50, 24.10, 61.86, 19.64, 24.6, 7.2, 9.6, 13.4,
   31.5, 30.8, 28.0, 28.0, 60.0, 60.5, 54.5, 54.5,
   39.0, 39.0, 37.5, 98.5, 118.0, 87.0, 99.0, 'DUMMY test data - 6 months on')
) as v (evaluated_on, weight_kg, body_fat_pct, lean_weight_kg, fat_weight_kg,
        suprailiac_mm, bicep_mm, tricep_mm, subscapular_mm,
        bicep_right_cm, bicep_left_cm, forearm_right_cm, forearm_left_cm,
        thigh_upper_right_cm, thigh_upper_left_cm, thigh_mid_right_cm, thigh_mid_left_cm,
        calf_right_cm, calf_left_cm, neck_cm, chest_cm, shoulders_cm, waist_cm, hips_cm, notes)
where u.email = 'member.carla@repclub-test.com';

-- Check: should list 3 rows.
select evaluated_on, weight_kg, body_fat_pct, waist_cm
  from body_evaluations
 where member_id = (select id from auth.users where email = 'member.carla@repclub-test.com')
 order by evaluated_on;
