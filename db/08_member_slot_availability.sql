-- 08: lets a member see WHICH of their own coach's sessions are free or taken,
-- without being able to read other members' bookings. Re-runnable.
create or replace function member_slots(p_from timestamptz, p_to timestamptz)
returns table (slot_id uuid, starts_at timestamptz, ends_at timestamptz, is_taken boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.starts_at, s.ends_at,
         (select count(*) from bookings b
           where b.slot_id = s.id and b.status <> 'CANCELLED') >= s.capacity
  from slots s
  join member_profiles mp on mp.primary_coach_id = s.coach_id
  where mp.id = auth.uid()
    and not s.is_cancelled
    and s.starts_at >= p_from and s.starts_at < p_to
  order by s.starts_at;
$$;

grant execute on function member_slots(timestamptz, timestamptz) to authenticated;
