# RepClub database scripts (Supabase / PostgreSQL)

Run in **Supabase > SQL Editor**, in number order. Most files are re-runnable.
These are copies of the scripts kept in the project's OneDrive `Repclub\db` folder;
new scripts are added in both places.

| File | What it does |
|---|---|
| `00_reset.sql` | **Destructive.** Drops every RepClub table, function and type (logins are kept) so `01` can run from scratch. |
| `01_schema.sql` | Tables, constraints, triggers and row-level security. |
| `02_seed_test_data.sql` | Turns the six `@repclub-test.com` logins into admin / coach / member test profiles. |
| `03_functions.sql` | The checked actions the app calls (packages, credits, bookings, check-in). |
| `04_test_functions.sql` | Self-test of `03`. |
| `05_capacity_one_per_session.sql` | One member per coach session. |
| `06_scheduled_jobs.sql` | Nightly reconciliation and weekly session generation (pg_cron). |
| `07_avatars_storage.sql` | Storage bucket for profile pictures. |
| `08_member_slot_availability.sql` | Members can see which of their coach's sessions are free. |
| `09_equipment_assignments.sql` | Equipment assigned to a member. |
| `10_body_evaluations.sql` | Full body evaluations. |
| `11_coach_booking_self_book.sql` | Coach books for members; per-member self-booking switch. |
| `12_coach_read_packages.sql` | Coaches read their members' packages and credits. |
| `13_dummy_carla_evaluations.sql` | Test data only: evaluations for the Carla test member. |
| `14_coach_assign_packages.sql` | Coaches may assign and activate packages for their members. |
| `15_coach_time_off.sql` | Coach holidays. |
| `16_cancel_package.sql` | Cancel / remove a package. |
| `17_gym_pass.sql` | Monthly Pass, gym-hour booking, gym door QR. |
| `18_gym_walk_in.sql` | Walk-ins (superseded by `19`). |
| `19_gym_booking_for_all.sql` | Everyone books a gym hour first. |
| `20_capacity_and_package_checks.sql` | Audit fixes: capacity check on coached bookings, no inactive package types. |
| `21_clean_start_keep_admin.sql` | **Destructive.** Wipes all business data and non-admin logins. |
| `22_workout_plans.sql` | Muscle groups, exercises, workout plans and logged sets. |
| `23_exercise_media.sql` | Exercise how-to: video link, up to 5 photos, storage bucket. |
| `24_preview_delete_luis_and_members.sql` | Read-only preview for `25`. |
| `25_delete_luis_and_members.sql` | **Destructive, one-off.** Deletes coach Luis and all members except Carla and Sanjeev. |
