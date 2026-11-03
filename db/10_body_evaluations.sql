-- 10: Full Body Evaluations (taken by a member's coach on a given date). Re-runnable.
-- One row = one evaluation: composition + caliper skinfolds + tape measurements.
-- Coach (of that member) and Admin may add/edit/delete; the member can only read their own.
create table if not exists body_evaluations (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references member_profiles (id) on delete cascade,
  coach_id        uuid references profiles (id) default auth.uid(),
  evaluated_on    date not null default current_date,
  method          text,                                  -- e.g. Durnin/Womersley
  weight_kg       numeric(5,2) check (weight_kg > 0),
  body_fat_pct    numeric(5,2) check (body_fat_pct >= 0 and body_fat_pct < 100),
  lean_weight_kg  numeric(5,2),
  fat_weight_kg   numeric(5,2),
  -- caliper (mm)
  suprailiac_mm   numeric(5,1),
  bicep_mm        numeric(5,1),
  tricep_mm       numeric(5,1),
  subscapular_mm  numeric(5,1),
  -- tape (cm)
  bicep_right_cm        numeric(5,1),
  bicep_left_cm         numeric(5,1),
  forearm_right_cm      numeric(5,1),
  forearm_left_cm       numeric(5,1),
  thigh_upper_right_cm  numeric(5,1),
  thigh_upper_left_cm   numeric(5,1),
  thigh_mid_right_cm    numeric(5,1),
  thigh_mid_left_cm     numeric(5,1),
  calf_right_cm         numeric(5,1),
  calf_left_cm          numeric(5,1),
  neck_cm               numeric(5,1),
  chest_cm              numeric(5,1),
  shoulders_cm          numeric(5,1),
  waist_cm              numeric(5,1),
  hips_cm               numeric(5,1),
  notes           text,
  created_at      timestamptz not null default now()
);
create index if not exists body_evaluations_member on body_evaluations (member_id, evaluated_on desc);

alter table body_evaluations enable row level security;

drop policy if exists read_evaluations on body_evaluations;
create policy read_evaluations on body_evaluations for select to authenticated
  using (member_id = auth.uid() or is_admin() or coach_has_member(member_id));

drop policy if exists admin_write on body_evaluations;
create policy admin_write on body_evaluations for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists coach_write on body_evaluations;
create policy coach_write on body_evaluations for all to authenticated
  using (coach_has_member(member_id)) with check (coach_has_member(member_id));

drop trigger if exists audit on body_evaluations;
create trigger audit after insert or update or delete on body_evaluations
  for each row execute function audit_row();
