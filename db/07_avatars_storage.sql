-- =====================================================================
-- REPCLUB  |  07_avatars_storage.sql
-- Storage for profile pictures of members and coaches.
-- Run in Supabase > SQL Editor. Safe to run more than once.
--
-- The bucket is PUBLIC for viewing: a picture can be shown in the app with
-- its link, no login needed. Anyone who has the exact link can see it; the
-- file names are random user ids, so they cannot be guessed or listed.
-- Only an Admin can upload, replace or delete pictures.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars admin select" on storage.objects;
drop policy if exists "avatars admin insert" on storage.objects;
drop policy if exists "avatars admin update" on storage.objects;
drop policy if exists "avatars admin delete" on storage.objects;

-- (select is needed by the app so a picture can be replaced)
create policy "avatars admin select" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and public.is_admin());
create policy "avatars admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and public.is_admin());
create policy "avatars admin update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and public.is_admin())
  with check (bucket_id = 'avatars' and public.is_admin());
create policy "avatars admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and public.is_admin());

-- Check: should show one row, public = true
select id, public, file_size_limit from storage.buckets where id = 'avatars';
