-- =====================================================================
-- REPCLUB  |  01_schema.sql
-- Tables, rules (constraints), triggers and row-level security.
-- Run ONCE in Supabase > SQL Editor on an empty public schema.
-- Gym: Europe/Dublin, open 06:00-20:00, 10 members per hourly slot.
-- =====================================================================

-- ---------- 1. Fixed lists of values ---------------------------------
create type user_role         as enum ('ADMIN', 'COACH', 'MEMBER');
create type package_status    as enum ('QUEUED', 'ACTIVE', 'EXHAUSTED', 'EXPIRED', 'CANCELLED');
create type booking_status    as enum ('BOOKED', 'ATTENDED', 'NO_SHOW', 'CANCELLED');
create type credit_txn_type   as enum ('PACKAGE_START', 'CHECK_IN', 'NO_SHOW', 'ADMIN_ADJUSTMENT', 'REVERSAL', 'EXPIRY');
create type reason_code       as enum ('ILLNESS', 'INJURY', 'GYM_CLOSURE', 'COACH_UNAVAILABLE', 'GOODWILL', 'OTHER');
create type attendance_method as enum ('QR', 'MANUAL');

-- ---------- 2. Gym settings (always exactly one row) -----------------
create table app_settings (
  id                        boolean primary key default true check (id),
  gym_timezone              text    not null default 'Europe/Dublin',
  open_time                 time    not null default '06:00',
  close_time                time    not null default '20:00',
  slot_capacity             int     not null default 10 check (slot_capacity > 0),
  cancel_lock_hours         int     not null default 12,
  checkin_minutes_before    int     not null default 30,
  open_weekdays             smallint[] not null default '{1,2,3,4,5,6}'   -- usual open days, 1 = Mon ... 7 = Sun
);
insert into app_settings default values;

-- One-off changes to a single date, e.g. closed on a Saturday this week, or open on a Sunday.
create table gym_day_overrides (
  day      date primary key,
  is_open  boolean not null,
  note     text
);

-- ---------- 3. People -------------------------------------------------
-- One row per login (auth.users). A login with no profile has NO access.
create table profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  role        user_role not null,
  full_name   text      not null,
  mobile      text,
  email       text,
  avatar_url  text,
  is_active   boolean   not null default true,
  created_at  timestamptz not null default now(),
  unique (id, role)
);

create table coach_profiles (
  id        uuid primary key,
  role      user_role not null default 'COACH' check (role = 'COACH'),
  qr_token  uuid not null unique default gen_random_uuid(),   -- the secret inside the coach QR code
  foreign key (id, role) references profiles (id, role) on delete cascade
);

create table member_profiles (
  id                 uuid primary key,
  role               user_role not null default 'MEMBER' check (role = 'MEMBER'),
  date_of_birth      date,
  gender             text,
  emergency_contact  text,
  primary_coach_id   uuid references coach_profiles (id),     -- one coach per member
  foreign key (id, role) references profiles (id, role) on delete cascade
);
create index on member_profiles (primary_coach_id);

-- ---------- 4. Packages and credits ----------------------------------
create table package_types (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  credits       int  not null check (credits > 0),
  price_eur     numeric(10,2) not null check (price_eur >= 0),
  validity_days int  not null check (validity_days > 0),
  is_active     boolean not null default true
);

create table member_packages (
  id               uuid primary key default gen_random_uuid(),
  member_id        uuid not null references member_profiles (id),
  package_type_id  uuid not null references package_types (id),
  package_name     text not null,                    -- copy of the name at purchase time
  status           package_status not null default 'QUEUED',
  purchase_date    date not null,
  start_date       date not null,
  expiry_date      date not null,
  starting_credits int  not null check (starting_credits >= 0),
  payment_note     text,
  activated_at     timestamptz,
  activated_by     uuid references profiles (id),
  created_by       uuid references profiles (id),
  created_at       timestamptz not null default now(),
  check (expiry_date >= start_date)
);
create index on member_packages (member_id);
-- RULE: only one ACTIVE package per member
create unique index one_active_package_per_member on member_packages (member_id) where status = 'ACTIVE';

-- The credit ledger. Balance = sum of delta. Rows are never edited or deleted.
create table credit_transactions (
  id                 bigint generated always as identity primary key,
  member_id          uuid not null references member_profiles (id),
  member_package_id  uuid not null references member_packages (id),
  type               credit_txn_type not null,
  delta              int  not null check (delta <> 0),
  reason_code        reason_code,
  note               text,
  booking_id         uuid,                           -- linked below, after bookings exists
  attendance_date    date,
  is_void            boolean not null default false, -- set when a reversal cancels this row out
  created_by         uuid references profiles (id),  -- null = done by the system
  created_at         timestamptz not null default now(),
  check (type <> 'PACKAGE_START' or delta > 0),
  check (type not in ('CHECK_IN', 'NO_SHOW') or (delta = -1 and attendance_date is not null)),
  check (type not in ('ADMIN_ADJUSTMENT', 'REVERSAL') or reason_code is not null),
  check (reason_code is distinct from 'OTHER' or nullif(trim(note), '') is not null)
);
create index on credit_transactions (member_id, created_at desc);
create index on credit_transactions (member_package_id);
-- RULE: one credit-consuming transaction per member per attendance day
create unique index one_credit_per_member_day on credit_transactions (member_id, attendance_date)
  where type in ('CHECK_IN', 'NO_SHOW') and not is_void;

-- ---------- 5. Schedule, bookings, attendance ------------------------
create table coach_weekly_schedule (       -- repeating pattern; slots are generated from it
  id        uuid primary key default gen_random_uuid(),
  coach_id  uuid not null references coach_profiles (id) on delete cascade,
  weekday   smallint not null check (weekday between 1 and 7),   -- 1 = Monday ... 7 = Sunday
  hour      smallint not null check (hour between 0 and 23),
  unique (coach_id, weekday, hour)
);

create table slots (                        -- one real hourly session of one coach
  id            uuid primary key default gen_random_uuid(),
  coach_id      uuid not null references coach_profiles (id),
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  capacity      int not null default 10 check (capacity > 0),
  is_cancelled  boolean not null default false,
  unique (coach_id, starts_at),
  check (ends_at = starts_at + interval '1 hour'),
  check (extract(epoch from starts_at)::bigint % 3600 = 0)       -- on the hour
);
create index on slots (starts_at);

create table bookings (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references member_profiles (id),
  slot_id        uuid not null references slots (id),
  booking_date   date not null,               -- gym-local date, filled in by trigger
  status         booking_status not null default 'BOOKED',
  created_by     uuid references profiles (id),
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancelled_by   uuid references profiles (id)
);
create index on bookings (slot_id);
create index on bookings (member_id, booking_date);
-- RULE: max one booking per member per day
create unique index one_booking_per_member_day on bookings (member_id, booking_date)
  where status in ('BOOKED', 'ATTENDED', 'NO_SHOW');

alter table credit_transactions
  add foreign key (booking_id) references bookings (id);

create table attendance (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null unique references bookings (id),
  member_id        uuid not null references member_profiles (id),
  coach_id         uuid not null references coach_profiles (id),
  attendance_date  date not null,
  checked_in_at    timestamptz not null default now(),
  method           attendance_method not null,
  recorded_by      uuid references profiles (id),
  reason_code      reason_code,
  note             text,
  unique (member_id, attendance_date),
  check (method = 'QR' or reason_code is not null),              -- manual entry needs a reason
  check (reason_code is distinct from 'OTHER' or nullif(trim(note), '') is not null)
);
create index on attendance (coach_id, attendance_date);

-- ---------- 6. Other content -----------------------------------------
create table equipment (
  id             uuid primary key default gen_random_uuid(),
  machine_number int  not null unique,
  name           text not null,
  description    text,
  video_url      text,
  thumbnail_url  text,
  notes          text,
  is_active      boolean not null default true
);

create table weight_logs (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references member_profiles (id) on delete cascade,
  weight_kg  numeric(5,2) not null check (weight_kg > 0),
  logged_on  date not null default current_date,
  created_at timestamptz not null default now()
);
create index on weight_logs (member_id, logged_on desc);

create table notification_settings (
  type       text primary key,
  label      text not null,
  enabled    boolean not null default true,
  threshold  int                                   -- e.g. low-credit level, days before expiry
);
insert into notification_settings (type, label, enabled, threshold) values
  ('BOOKING_24H',    '24-hour booking reminder', true, null),
  ('BOOKING_1H',     '1-hour booking reminder',  true, null),
  ('SESSION_ENDING', 'Session ending reminder',  true, null),
  ('LOW_CREDIT',     'Low-credit alert',         true, 2),
  ('PACKAGE_EXPIRY', 'Package expiry reminder',  true, 7);

create table audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_id     uuid,
  action       text not null,
  entity       text not null,
  entity_id    text,
  old_data     jsonb,
  new_data     jsonb,
  reason_code  reason_code,
  note         text
);
create index on audit_log (at desc);

-- ---------- 7. Helper functions used by the security rules -----------
create function app_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and is_active
$$;

create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app_role() = 'ADMIN', false)
$$;

create function coach_has_member(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app_role() = 'COACH', false)
     and exists (select 1 from member_profiles where id = m and primary_coach_id = auth.uid())
$$;

revoke execute on function app_role(), is_admin(), coach_has_member(uuid) from public;
grant  execute on function app_role(), is_admin(), coach_has_member(uuid) to authenticated;

-- ---------- 8. Triggers that enforce the rules -----------------------
-- 8a. Audit trail for important tables
create function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (actor_id, action, entity, entity_id, old_data, new_data)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id'),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger audit after insert or update or delete on profiles         for each row execute function audit_row();
create trigger audit after insert or update or delete on member_profiles  for each row execute function audit_row();
create trigger audit after insert or update or delete on coach_profiles   for each row execute function audit_row();
create trigger audit after insert or update or delete on package_types    for each row execute function audit_row();
create trigger audit after insert or update or delete on member_packages  for each row execute function audit_row();
create trigger audit after insert or update or delete on bookings         for each row execute function audit_row();
create trigger audit after insert or update or delete on attendance       for each row execute function audit_row();
create trigger audit after insert or update or delete on equipment        for each row execute function audit_row();

-- 8b. The credit ledger can never be edited or deleted (only flagged void)
create function ledger_protect() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Credit transactions cannot be deleted';
  end if;
  if (to_jsonb(new) - 'is_void') is distinct from (to_jsonb(old) - 'is_void')
     or old.is_void then
    raise exception 'Credit transactions cannot be edited';
  end if;
  return new;
end $$;
create trigger ledger_protect before update or delete on credit_transactions
  for each row execute function ledger_protect();

-- 8c. Slots must sit inside opening days and hours (gym time)
create function slots_check() returns trigger
language plpgsql as $$
declare s app_settings; t time; d date; open_day boolean;
begin
  select * into s from app_settings;
  t := (new.starts_at at time zone s.gym_timezone)::time;
  d := (new.starts_at at time zone s.gym_timezone)::date;
  select coalesce((select is_open from gym_day_overrides where day = d),
                  extract(isodow from d)::smallint = any (s.open_weekdays))
    into open_day;
  if not open_day then
    raise exception 'The gym is closed on %', d;
  end if;
  if t < s.open_time or t > s.close_time - interval '1 hour' then
    raise exception 'Slot at % is outside opening hours (% - %)', t, s.open_time, s.close_time;
  end if;
  return new;
end $$;
create trigger slots_check before insert or update of starts_at on slots
  for each row execute function slots_check();

-- 8d. Bookings: local date, correct coach, capacity (max 10 per slot)
create function bookings_check() returns trigger
language plpgsql as $$
declare s slots; tz text; taken int; coach uuid;
begin
  select * into s from slots where id = new.slot_id for update;   -- lock: two people can't take the last place
  select gym_timezone into tz from app_settings;
  new.booking_date := (s.starts_at at time zone tz)::date;

  if new.status <> 'CANCELLED'
     and (tg_op = 'INSERT' or new.slot_id is distinct from old.slot_id or old.status = 'CANCELLED') then
    if s.is_cancelled then
      raise exception 'This session has been cancelled';
    end if;
    select primary_coach_id into coach from member_profiles where id = new.member_id;
    if coach is distinct from s.coach_id then
      raise exception 'Member can only book their own coach''s sessions';
    end if;
    select count(*) into taken from bookings
      where slot_id = new.slot_id and status <> 'CANCELLED' and id <> new.id;
    if taken >= s.capacity then
      raise exception 'This session is full';
    end if;
  end if;
  return new;
end $$;
create trigger bookings_check before insert or update on bookings
  for each row execute function bookings_check();

-- ---------- 9. A view: remaining credits per package -----------------
create view member_package_balances with (security_invoker = true) as
select mp.id as member_package_id, mp.member_id, mp.status, mp.expiry_date,
       coalesce(sum(ct.delta), 0)::int as credits_remaining
from member_packages mp
left join credit_transactions ct on ct.member_package_id = mp.id
group by mp.id;

-- ---------- 10. Row-level security -----------------------------------
alter table app_settings           enable row level security;
alter table profiles               enable row level security;
alter table coach_profiles         enable row level security;
alter table member_profiles        enable row level security;
alter table package_types          enable row level security;
alter table member_packages        enable row level security;
alter table credit_transactions    enable row level security;
alter table coach_weekly_schedule  enable row level security;
alter table slots                  enable row level security;
alter table gym_day_overrides      enable row level security;
alter table bookings               enable row level security;
alter table attendance             enable row level security;
alter table equipment              enable row level security;
alter table weight_logs            enable row level security;
alter table notification_settings  enable row level security;
alter table audit_log              enable row level security;

-- Anyone with a profile can read these (members need coach names, schedules, packages, machines)
create policy read_all on app_settings          for select to authenticated using (app_role() is not null);
create policy read_all on package_types         for select to authenticated using (app_role() is not null);
create policy read_all on coach_weekly_schedule for select to authenticated using (app_role() is not null);
create policy read_all on slots                 for select to authenticated using (app_role() is not null);
create policy read_all on gym_day_overrides     for select to authenticated using (app_role() is not null);
create policy read_all on equipment             for select to authenticated using (app_role() is not null);
create policy read_all on notification_settings for select to authenticated using (app_role() is not null);

-- Admin may change these directly
create policy admin_write on app_settings          for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on package_types         for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on coach_weekly_schedule for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on slots                 for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on gym_day_overrides     for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on equipment             for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_write on notification_settings for all to authenticated using (is_admin()) with check (is_admin());

-- People
create policy read_profiles on profiles for select to authenticated using (
  id = auth.uid() or is_admin() or (role = 'COACH' and app_role() is not null) or coach_has_member(id));
create policy admin_write on profiles for all to authenticated using (is_admin()) with check (is_admin());

create policy read_members on member_profiles for select to authenticated using (
  id = auth.uid() or is_admin() or coach_has_member(id));
create policy admin_write on member_profiles for all to authenticated using (is_admin()) with check (is_admin());

-- Coach QR secret: only admin and that coach (members must never read it)
create policy read_coach on coach_profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy admin_write on coach_profiles for all to authenticated using (is_admin()) with check (is_admin());

-- Packages, credits, bookings, attendance: read-only for the app; changes go through functions (next step)
create policy read_packages on member_packages for select to authenticated using (member_id = auth.uid() or is_admin());
create policy read_credits  on credit_transactions for select to authenticated using (member_id = auth.uid() or is_admin());
create policy read_bookings on bookings for select to authenticated using (
  member_id = auth.uid() or is_admin()
  or exists (select 1 from slots s where s.id = bookings.slot_id and s.coach_id = auth.uid()));
create policy read_attendance on attendance for select to authenticated using (
  member_id = auth.uid() or coach_id = auth.uid() or is_admin());

-- Weight: member logs their own; coach and admin can read
create policy read_weight   on weight_logs for select to authenticated using (
  member_id = auth.uid() or is_admin() or coach_has_member(member_id));
create policy member_insert on weight_logs for insert to authenticated with check (member_id = auth.uid());
create policy admin_write   on weight_logs for all to authenticated using (is_admin()) with check (is_admin());

create policy admin_read on audit_log for select to authenticated using (is_admin());

-- ---------- 11. Lock down direct access ------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke insert, update, delete on member_packages, credit_transactions, bookings, attendance, audit_log from authenticated;
