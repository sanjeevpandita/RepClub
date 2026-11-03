-- =====================================================================
-- REPCLUB  |  23_exercise_media.sql      Re-runnable. Run after 22.
-- "How to do it" for each exercise:
--   * exercises.notes       (already there) = the written steps
--   * exercises.video_url   = a link (YouTube, Vimeo...) members can open
--   * exercises.image_urls  = up to 5 photo links, in display order
-- Photos are stored in a PUBLIC Storage bucket "exercise-media" (anyone with
-- the exact link can view; names are random, cannot be listed).
-- Only an Admin can upload, replace or delete them.
-- =====================================================================

alter table exercises add column if not exists video_url text;
alter table exercises add column if not exists image_urls text[] not null default '{}';

alter table exercises drop constraint if exists exercises_video_url_check;
alter table exercises add constraint exercises_video_url_check
  check (video_url is null or video_url ~* '^https?://');
alter table exercises drop constraint if exists exercises_image_urls_check;
alter table exercises add constraint exercises_image_urls_check
  check (cardinality(image_urls) <= 5);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('exercise-media', 'exercise-media', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "exercise media admin select" on storage.objects;
drop policy if exists "exercise media admin insert" on storage.objects;
drop policy if exists "exercise media admin update" on storage.objects;
drop policy if exists "exercise media admin delete" on storage.objects;

create policy "exercise media admin select" on storage.objects for select to authenticated
  using (bucket_id = 'exercise-media' and public.is_admin());
create policy "exercise media admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'exercise-media' and public.is_admin());
create policy "exercise media admin update" on storage.objects for update to authenticated
  using (bucket_id = 'exercise-media' and public.is_admin())
  with check (bucket_id = 'exercise-media' and public.is_admin());
create policy "exercise media admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'exercise-media' and public.is_admin());

-- Check: one row, public = true; and the two new columns.
select id, public, file_size_limit from storage.buckets where id = 'exercise-media';
select column_name, data_type from information_schema.columns
 where table_name = 'exercises' and column_name in ('video_url', 'image_urls');
