-- =====================================================================
-- REPCLUB  |  22_workout_plans.sql      Re-runnable. Run after 01-21.
-- Workout planning:
--   * Admin keeps a library of muscle groups (Shoulders, Chest, Legs, Core...)
--     and the exercises in each group.
--   * A coach gives one of their members a workout for a muscle group on a
--     date: chosen exercises with target sets / reps / weight. It can repeat
--     every week for a number of weeks (one row per date, linked by series_id).
--   * The member (or their coach) records what was done: reps and weight
--     for each set.
-- Who can do what:
--   muscle_groups, exercises : everyone signed in reads; admin writes.
--   workout_plans + exercises: member reads own; their coach and admin read.
--                              Written only through the RPCs below.
--   workout_set_logs         : member writes own (not for future dates);
--                              their coach and admin write too.
-- =====================================================================

-- ---------- 1. Library ------------------------------------------------
create table if not exists muscle_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  sort_order  int  not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists exercises (
  id               uuid primary key default gen_random_uuid(),
  muscle_group_id  uuid not null references muscle_groups (id) on delete restrict,
  name             text not null check (length(trim(name)) > 0),
  notes            text,
  sort_order       int  not null default 0,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  unique (muscle_group_id, name)
);
create index if not exists exercises_group on exercises (muscle_group_id, sort_order);

-- ---------- 2. Plans --------------------------------------------------
create table if not exists workout_plans (
  id               uuid primary key default gen_random_uuid(),
  member_id        uuid not null references member_profiles (id) on delete cascade,
  muscle_group_id  uuid not null references muscle_groups (id) on delete restrict,
  plan_date        date not null,
  series_id        uuid not null default gen_random_uuid(),  -- same id = repeated weekly
  coach_id         uuid references profiles (id) default auth.uid(),
  notes            text,
  created_at       timestamptz not null default now(),
  unique (member_id, plan_date, muscle_group_id)
);
create index if not exists workout_plans_member on workout_plans (member_id, plan_date);
create index if not exists workout_plans_series on workout_plans (series_id, plan_date);

create table if not exists workout_plan_exercises (
  id                uuid primary key default gen_random_uuid(),
  plan_id           uuid not null references workout_plans (id) on delete cascade,
  exercise_id       uuid not null references exercises (id) on delete restrict,
  sort_order        int  not null default 0,
  target_sets       int  not null default 3 check (target_sets between 1 and 20),
  target_reps       int  check (target_reps between 1 and 200),
  target_weight_kg  numeric(6,2) check (target_weight_kg >= 0),
  notes             text,
  unique (plan_id, exercise_id)
);
create index if not exists workout_plan_exercises_plan on workout_plan_exercises (plan_id, sort_order);

-- ---------- 3. What was done (one row per set) ------------------------
create table if not exists workout_set_logs (
  id                uuid primary key default gen_random_uuid(),
  plan_exercise_id  uuid not null references workout_plan_exercises (id) on delete cascade,
  member_id         uuid not null references member_profiles (id) on delete cascade,
  set_no            int  not null check (set_no between 1 and 20),
  reps              int  check (reps between 0 and 500),
  weight_kg         numeric(6,2) check (weight_kg >= 0),
  logged_by         uuid references profiles (id) default auth.uid(),
  logged_at         timestamptz not null default now(),
  unique (plan_exercise_id, set_no)
);
create index if not exists workout_set_logs_member on workout_set_logs (member_id);

-- ---------- 4. Helpers ------------------------------------------------
create or replace function _can_manage_member(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or coach_has_member(m)
$$;

-- The member a plan exercise belongs to, and whether a member may log it
-- today (not for a future date, gym timezone).
create or replace function _plan_exercise_member(pe uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select p.member_id from workout_plan_exercises x join workout_plans p on p.id = x.plan_id
   where x.id = pe
$$;

create or replace function _plan_exercise_open_for_member(pe uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.plan_date <= (now() at time zone (select gym_timezone from app_settings limit 1))::date
       from workout_plan_exercises x join workout_plans p on p.id = x.plan_id
      where x.id = pe), false)
$$;

revoke execute on function _can_manage_member(uuid), _plan_exercise_member(uuid),
  _plan_exercise_open_for_member(uuid) from public, anon;
grant  execute on function _can_manage_member(uuid), _plan_exercise_member(uuid),
  _plan_exercise_open_for_member(uuid) to authenticated;

-- ---------- 5. Security rules -----------------------------------------
alter table muscle_groups          enable row level security;
alter table exercises              enable row level security;
alter table workout_plans          enable row level security;
alter table workout_plan_exercises enable row level security;
alter table workout_set_logs       enable row level security;

-- Plans are written only through the RPCs; nothing for signed-out users.
revoke insert, update, delete on workout_plans, workout_plan_exercises from authenticated;
revoke all on muscle_groups, exercises, workout_plans, workout_plan_exercises, workout_set_logs from anon;

drop policy if exists read_all on muscle_groups;
create policy read_all on muscle_groups for select to authenticated using (app_role() is not null);
drop policy if exists admin_write on muscle_groups;
create policy admin_write on muscle_groups for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists read_all on exercises;
create policy read_all on exercises for select to authenticated using (app_role() is not null);
drop policy if exists admin_write on exercises;
create policy admin_write on exercises for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists read_plans on workout_plans;
create policy read_plans on workout_plans for select to authenticated
  using (member_id = auth.uid() or _can_manage_member(member_id));

drop policy if exists read_plan_exercises on workout_plan_exercises;
create policy read_plan_exercises on workout_plan_exercises for select to authenticated
  using (exists (select 1 from workout_plans p where p.id = plan_id
                  and (p.member_id = auth.uid() or _can_manage_member(p.member_id))));

drop policy if exists read_set_logs on workout_set_logs;
create policy read_set_logs on workout_set_logs for select to authenticated
  using (member_id = auth.uid() or _can_manage_member(member_id));

drop policy if exists member_write on workout_set_logs;
create policy member_write on workout_set_logs for all to authenticated
  using (member_id = auth.uid())
  with check (member_id = auth.uid()
              and _plan_exercise_member(plan_exercise_id) = member_id
              and _plan_exercise_open_for_member(plan_exercise_id));

drop policy if exists staff_write on workout_set_logs;
create policy staff_write on workout_set_logs for all to authenticated
  using (_can_manage_member(member_id))
  with check (_can_manage_member(member_id)
              and _plan_exercise_member(plan_exercise_id) = member_id);

-- ---------- 6. Audit trail --------------------------------------------
drop trigger if exists audit on muscle_groups;
create trigger audit after insert or update or delete on muscle_groups
  for each row execute function audit_row();
drop trigger if exists audit on exercises;
create trigger audit after insert or update or delete on exercises
  for each row execute function audit_row();
drop trigger if exists audit on workout_plans;
create trigger audit after insert or update or delete on workout_plans
  for each row execute function audit_row();

-- ---------- 7. Actions (RPCs) -----------------------------------------
-- p_exercises: json list, in order, e.g.
--   [{"exercise_id":"...","sets":3,"reps":10,"weight_kg":20,"notes":"slow"}]

-- Internal: replace the exercises of one plan with the given list.
-- Exercises kept in the list keep their logged sets; removed ones lose them.
create or replace function _set_plan_exercises(p_plan uuid, p_group uuid, p_exercises jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare e record; v_ex uuid; v_ids uuid[] := '{}';
begin
  if p_exercises is null or jsonb_typeof(p_exercises) <> 'array'
     or jsonb_array_length(p_exercises) = 0 then
    raise exception 'Choose at least one exercise';
  end if;
  for e in select val, idx from jsonb_array_elements(p_exercises) with ordinality as t(val, idx) loop
    v_ex := (e.val ->> 'exercise_id')::uuid;
    if not exists (select 1 from exercises where id = v_ex and muscle_group_id = p_group) then
      raise exception 'An exercise does not belong to this muscle group';
    end if;
    v_ids := v_ids || v_ex;
    insert into workout_plan_exercises
      (plan_id, exercise_id, sort_order, target_sets, target_reps, target_weight_kg, notes)
    values (p_plan, v_ex, e.idx,
            coalesce((e.val ->> 'sets')::int, 3),
            (e.val ->> 'reps')::int,
            (e.val ->> 'weight_kg')::numeric,
            nullif(trim(e.val ->> 'notes'), ''))
    on conflict (plan_id, exercise_id) do update
      set sort_order = excluded.sort_order, target_sets = excluded.target_sets,
          target_reps = excluded.target_reps, target_weight_kg = excluded.target_weight_kg,
          notes = excluded.notes;
  end loop;
  delete from workout_plan_exercises where plan_id = p_plan and not (exercise_id = any (v_ids));
end $$;
revoke execute on function _set_plan_exercises(uuid, uuid, jsonb) from public, anon, authenticated;

-- Give a member a workout on p_date, repeated every 7 days for p_weeks weeks.
-- Returns the series id shared by all the dates.
create or replace function assign_workout_plan(
  p_member uuid, p_muscle_group uuid, p_date date, p_weeks int, p_exercises jsonb,
  p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_series uuid := gen_random_uuid(); v_plan uuid; v_day date; v_group text; i int;
begin
  if not _can_manage_member(p_member) then
    raise exception 'Only the admin or the member''s own coach can assign a workout';
  end if;
  if p_date is null then raise exception 'Choose a date'; end if;
  if coalesce(p_weeks, 0) < 1 or p_weeks > 26 then
    raise exception 'Repeat for 1 to 26 weeks';
  end if;
  select name into v_group from muscle_groups where id = p_muscle_group and is_active;
  if not found then raise exception 'Choose a muscle group'; end if;

  for i in 0 .. p_weeks - 1 loop
    v_day := p_date + 7 * i;
    if exists (select 1 from workout_plans where member_id = p_member
                 and plan_date = v_day and muscle_group_id = p_muscle_group) then
      raise exception 'This member already has a % workout on %', v_group, to_char(v_day, 'DD/MM/YYYY');
    end if;
    insert into workout_plans (member_id, muscle_group_id, plan_date, series_id, coach_id, notes)
    values (p_member, p_muscle_group, v_day, v_series, auth.uid(), nullif(trim(p_notes), ''))
    returning id into v_plan;
    perform _set_plan_exercises(v_plan, p_muscle_group, p_exercises);
  end loop;
  return v_series;
end $$;

-- Change a workout. p_following = true also changes the later weeks of the
-- same repeat. p_new_date moves this one day only (ignored with p_following).
create or replace function update_workout_plan(
  p_plan uuid, p_exercises jsonb, p_notes text default null,
  p_following boolean default false, p_new_date date default null)
returns void language plpgsql security definer set search_path = public as $$
declare p workout_plans; t record;
begin
  select * into p from workout_plans where id = p_plan;
  if not found then raise exception 'Workout not found'; end if;
  if not _can_manage_member(p.member_id) then
    raise exception 'Only the admin or the member''s own coach can change a workout';
  end if;

  for t in select id from workout_plans
            where id = p_plan
               or (p_following and series_id = p.series_id and plan_date > p.plan_date) loop
    update workout_plans set notes = nullif(trim(p_notes), '') where id = t.id;
    perform _set_plan_exercises(t.id, p.muscle_group_id, p_exercises);
  end loop;

  if not p_following and p_new_date is not null and p_new_date <> p.plan_date then
    if exists (select 1 from workout_plans where member_id = p.member_id and plan_date = p_new_date
                 and muscle_group_id = p.muscle_group_id) then
      raise exception 'This member already has this workout on %', to_char(p_new_date, 'DD/MM/YYYY');
    end if;
    update workout_plans set plan_date = p_new_date where id = p_plan;
  end if;
end $$;

-- Remove a workout (p_following = true: also the later weeks of the repeat).
create or replace function delete_workout_plan(p_plan uuid, p_following boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare p workout_plans; n int;
begin
  select * into p from workout_plans where id = p_plan;
  if not found then raise exception 'Workout not found'; end if;
  if not _can_manage_member(p.member_id) then
    raise exception 'Only the admin or the member''s own coach can remove a workout';
  end if;
  delete from workout_plans
   where id = p_plan
      or (p_following and series_id = p.series_id and plan_date > p.plan_date);
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function assign_workout_plan(uuid, uuid, date, int, jsonb, text),
  update_workout_plan(uuid, jsonb, text, boolean, date),
  delete_workout_plan(uuid, boolean) from public, anon;
grant execute on function assign_workout_plan(uuid, uuid, date, int, jsonb, text),
  update_workout_plan(uuid, jsonb, text, boolean, date),
  delete_workout_plan(uuid, boolean) to authenticated;

-- ---------- 8. Starter library (admin can rename / add / switch off) --
insert into muscle_groups (name, sort_order) values
  ('Shoulders', 1), ('Chest', 2), ('Legs', 3), ('Core', 4)
on conflict (name) do nothing;

insert into exercises (muscle_group_id, name, sort_order)
select g.id, x.name, x.ord
  from (values
    ('Legs', 'Leg extension', 1), ('Legs', 'Leg raises', 2), ('Legs', 'Goblet squat', 3),
    ('Legs', 'Squat', 4), ('Legs', 'Deadlift', 5),
    ('Shoulders', 'Shoulder press', 1), ('Shoulders', 'Lateral raise', 2),
    ('Shoulders', 'Front raise', 3), ('Shoulders', 'Rear delt fly', 4),
    ('Chest', 'Bench press', 1), ('Chest', 'Incline dumbbell press', 2),
    ('Chest', 'Chest fly', 3), ('Chest', 'Push-up', 4),
    ('Core', 'Plank', 1), ('Core', 'Crunch', 2), ('Core', 'Russian twist', 3),
    ('Core', 'Dead bug', 4)
  ) as x(grp, name, ord)
  join muscle_groups g on g.name = x.grp
on conflict (muscle_group_id, name) do nothing;

-- Check: should list 4 groups with their exercise counts.
select g.name, count(e.id) as exercises
  from muscle_groups g left join exercises e on e.muscle_group_id = g.id
 group by g.name, g.sort_order order by g.sort_order;
