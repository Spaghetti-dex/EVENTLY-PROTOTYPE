# EVENTLY staff, booking review, and customer review setup

## Supabase migration

Review/staff changes use these ordered migrations:

1. `20261013085000_evently_user_role_staff.sql` (adds `staff` only if `profiles.role` uses `public.user_role`; otherwise a no-op)
2. `20261013090000_evently_staff_and_reviews.sql` (staff profile role/check, permissions, recommendations, review fields)
3. `20261013120000_evently_review_edit_and_readiness.sql` (review editing, secure reanalysis, schema readiness)
4. `20261013130000_evently_staff_role_readiness.sql` (role/permission capability checks)
5. `20261013140000_evently_staff_dashboard.sql` (staff orders permission, accurate dashboard statistics, event-driven staff notifications)
6. `20261013150000_evently_staff_role_readiness_profile_aware.sql` (checks the live `user_role` enum and the actual `profiles.role` representation)
6. `20261013150000_evently_staff_role_readiness_profile_aware.sql` (recognizes an existing `profiles.role = 'staff'` row as well as enum/check support)

They preserve the existing `public.reviews` identity, ownership, reservation, rating, text,
publication, and timestamp fields and add only the workflow/analysis data required. The first
migration backfills common legacy `user_id` / `comment` / `content` fields when found; the second
backfills the package through the linked reservation. The migrations have **not** been applied by
this code change. Customer/admin/staff review screens and the Edge Function call
`evently_review_features_ready()` before using the new fields, so they show a setup notice until
the database confirms the complete schema.

Apply using the project's configured Supabase CLI/link, for example:

```sh
supabase link --project-ref xwldoyqasafgjpodgdqd
supabase db push
```

Alternatively, inspect and run both migrations in order in the Supabase SQL Editor. Verify profile role
type/checks, the existing `public.reviews` column types, and `admin_activity_logs` constraints first. The
checked-in `profiles.role` migration uses `text` and a check constraint (not the `user_role`
enum); the live database catalog was not available for this implementation.

After applying the migrations, verify the feature gate in the SQL Editor:

```sql
select public.evently_review_features_ready();
select public.evently_staff_role_ready(), public.evently_staff_permissions_ready();
select enum.enumlabel
from pg_catalog.pg_type type
join pg_catalog.pg_namespace namespace on namespace.oid = type.typnamespace
join pg_catalog.pg_enum enum on enum.enumtypid = type.oid
where namespace.nspname = 'public' and type.typname = 'user_role'
order by enum.enumsortorder;
```

To diagnose a specific Staff account (replace the UUID as needed), run this as an authorized
database operator:

```sql
select id, role::text, staff_active,
       public.evently_staff_role_ready() as staff_role_ready,
       public.evently_staff_permissions_ready() as staff_permissions_ready
from public.profiles
where id = '02fbdc50-5703-4b8b-b044-8cb40fe7d688';
```

The app also checks this RPC before selecting the added review fields; if it returns false or the
function is missing, the customer review form and admin moderation workspace remain gated.

## Edge Function secrets and deploy

The existing `server` Edge Function now has secure staff invitation and review analysis routes.
Set the Hugging Face token in Supabase secrets (never in Vite variables). Hosted Supabase Edge
Functions supply the project URL and public/service-role keys as server-side environment variables;
set them in a local Edge Function `.env` only when running the function locally.

```sh
supabase secrets set HF_INFERENCE_TOKEN=<Hugging-Face-token>
supabase functions deploy server
```

The model is `cardiffnlp/twitter-xlm-roberta-base-sentiment`, called through Hugging Face's
inference router. It analyzes review text (not stars), stores positive/neutral/negative plus
confidence, timestamp, and model id, and leaves analysis pending when inference fails. It is
primarily trained for social-media sentiment and has limited coverage for Filipino/Tagalog and
mixed-language hospitality reviews; treat classifications as assistive analytics, not moderation
 decisions. Analysis requests are limited server-side to eight per authenticated user per minute.

The profanity gate runs in the submission and edit RPCs and does not silently rewrite a review.
Clear English and Filipino/Tagalog terms prompt an edit; targeted threatening/abusive phrasing is
flagged for moderation. The vocabulary is intentionally modest and should be expanded only with
locally reviewed vocabulary to avoid blocking harmless words. Sentiment never determines publication.

## Owner and administrator setup

1. Apply the migration and deploy the Edge Function.
2. Sign in as an existing Owner and open `/admin/staff`.
3. Enable only the staff capabilities administrators may grant in **Owner-defined staff
   permission policy**. All capabilities default to disabled.
4. Invite each staff member through the invitation form; the function verifies the caller's
   Supabase profile role and sets the staff profile on the server.
5. Grant that staff member the minimum operational permissions required.

Staff can sign in at `/staff/login`. Final booking decisions remain admin/owner-only. Staff schedule
proposals apply to the existing booking date; the current schedule RPC has no supported date-change
parameter, and acceptance uses its existing conflict/resource checks.

## Verification status

`corepack pnpm exec tsc --noEmit` and `corepack pnpm build` are the local frontend checks. Database
RPC/RLS behavior, invitations, and model calls still require deployment against a Supabase project
with the migration applied and the secrets configured; this repository environment did not expose
that live backend for integration testing.
