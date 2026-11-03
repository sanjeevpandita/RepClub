-- 09: equipment assigned to a member (by the admin, or by the member's own coach). Re-runnable.
create table if not exists equipment_assignments (
  member_id    uuid not null references member_profiles (id) on delete cascade,
  equipment_id uuid not null references equipment (id) on delete cascade,
  assigned_by  uuid references profiles (id) default auth.uid(),
  assigned_at  timestamptz not null default now(),
  primary key (member_id, equipment_id)
);
create index if not exists equipment_assignments_equipment on equipment_assignments (equipment_id);

alter table equipment_assignments enable row level security;

drop policy if exists read_assignments on equipment_assignments;
create policy read_assignments on equipment_assignments for select to authenticated
  using (member_id = auth.uid() or is_admin() or coach_has_member(member_id));

drop policy if exists admin_write on equipment_assignments;
create policy admin_write on equipment_assignments for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists coach_write on equipment_assignments;
create policy coach_write on equipment_assignments for all to authenticated
  using (coach_has_member(member_id)) with check (coach_has_member(member_id));
