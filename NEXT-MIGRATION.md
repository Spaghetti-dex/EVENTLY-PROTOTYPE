# EVENTLY Next.js migration

The active application now uses **Next.js 16 App Router** with React 19, TypeScript, Tailwind CSS v4, and `@supabase/ssr`. Existing application pages and features remain in `src/App.tsx` and are mounted at their existing paths through `app/[[...slug]]/page.tsx`. The catch-all route is an intentional first migration step: the existing React view/router is client-only because it relies on browser APIs throughout; it can be split into individual route segments without changing those components or the booking RPCs.

`proxy.ts` refreshes Supabase auth cookies and checks roles before protected paths render. The OAuth callback at `app/auth/callback/route.ts` exchanges the authorization code through the cookie-aware `@supabase/ssr` server client and routes from `public.profiles.role`. Database RLS and existing RPC authorization remain the security boundary for data and mutations. The browser client is `createBrowserClient` in `src/lib/supabase.ts`.

## Run locally

```sh
corepack pnpm install --frozen-lockfile
Copy-Item .env.example .env.local
# Fill in NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY
corepack pnpm dev
```

The development server listens on port 8443, matching the existing Figma Make preview port. For production:

```sh
corepack pnpm build
corepack pnpm start
```

The Supabase project URL in `utils/supabase/info.tsx` identifies the existing project. The checked-in generated public key currently receives an `Invalid API key` response from that project, so set `NEXT_PUBLIC_SUPABASE_URL` and the current public anon/publishable key in `.env.local` before authentication testing. Do not substitute a key from a different project. Never place a service-role key in these variables or browser code.

## Supabase Auth URL configuration

Add your Next.js origin and callback destinations to Supabase **Authentication → URL Configuration → Redirect URLs**. For local development explicitly allow `http://localhost:8443/auth/callback?next=/staff/dashboard` (or a supported wildcard covering this callback); add the equivalent production callback. Password reset and OAuth construct redirects from the current browser origin rather than a fixed Figma Make domain. If `redirectTo` is absent or rejected by this allowlist, Supabase can fall back to the configured Site URL, so set that Site URL to the production Next.js origin rather than the retired Figma Make site.

For Google sign-in, enable the Google provider in Supabase Auth and configure its OAuth Client ID/secret there. The Google Cloud OAuth client must allow Supabase's provider callback URL (`https://<project-ref>.supabase.co/auth/v1/callback`); Supabase must allow the application's `/auth/callback` URL as a redirect. If deploying the staff invitation Edge Function, set `EVENTLY_APP_ORIGINS` to a comma-separated allowlist containing the local and production app origins. Live provider settings could not be inspected from this workspace.

The legacy browser client stored sessions in local/session storage. The SSR client stores them in cookies, so existing users may need to sign in again once after migration. Booking drafts remain in session storage.

## Scope and validation boundary

Presentation, customer booking components, admin views, the Staff Portal, Supabase RPC signatures, and shared styling are retained. Interactive screens remain client-rendered in this phase to avoid hydration regressions from browser-only code. Server Components currently handle the root layout and protected route entry; moving individual read-only dashboard areas to Server Components is a later refactor. A live Supabase project is not available here, so role redirects are build-verified but still need a deployment-time auth/RLS test.

## Admin dashboard catalog and payment settings

The consolidated Reservations workspace includes the booking calendar and date-filtered reservation records. Packages, variants, add-ons, and catering menu items are edited through Owner/Admin-only RPCs; direct client catalog writes are revoked. Menu-item prices default to zero so existing package prices remain unchanged. A non-zero menu-item price is an additional per-guest charge for new catering bookings only; existing reservation/order totals are not recalculated.

The additive migration `supabase/migrations/20261014110000_evently_admin_catalog_and_payment_settings.sql` adds the menu-price fields and seed rows, guarded/audited catalog update functions, and customer-visible payment destination settings. Apply it manually in Supabase **after the existing booking workflow and staycation pricing migrations** and after checking the project's migration history. It has not been run from this workspace. Do not run it against a different Supabase project. The separate staff-dashboard recovery migration remains pending and is not part of this change.

Payment destination and legacy-instruction writes use `evently_admin_save_payment_accounts` and `evently_admin_save_legacy_payment_instructions`; both require an Owner/Admin profile, a fresh verified TOTP challenge (AAL2), and an optimistic `updated_at` match. Changes are stored in the existing business-settings row and recorded in the restricted `evently_payment_account_audit` table. Payment account entries are customer-facing instructions only; they do not connect to a processor or change bank payout routing. The first-time MFA setup is offered in the Admin UI. Customers read active destinations through `evently_customer_payment_options`; payment submission still uses the existing `submit_evently_payment` signature and checks that the selected method remains configured.

After applying the migration, verify with a test Owner/Admin and a test customer: catalog updates are visible to new bookings; inactive menu items cannot be selected or submitted; old booking totals remain unchanged; a customer sees only active payment destinations; missing/inactive methods are rejected by the payment RPC; non-admins cannot read audit/payment-setting rows or call Admin RPCs; and payment-setting changes fail without a fresh MFA challenge. The workspace checks were TypeScript, production build, and HTTP 200 responses for the admin login, reservations, payments, packages, and catering-menu routes. Live Supabase migration execution, RLS/RPC behavior, account sign-in, and OAuth remain unverified.

## Booking payment proof and Admin approval

`supabase/migrations/20261014120000_evently_booking_payment_verification.sql` is an additive migration that must be applied manually after `20261014110000_evently_admin_catalog_and_payment_settings.sql` and its booking/workflow prerequisites. Check the target project's migration history before applying it. Do not apply it automatically or to a different Supabase project. It keeps the existing `create_evently_reservation`, `submit_evently_payment`, `admin_review_payment`, and `evently_admin_approve_booking` RPC signatures; a new reservation and its first payment row are written in one transaction after the private receipt upload. Rejected proof can be resubmitted on the linked Order page; only one submission per reservation may be pending review at a time.

The payment-proof bucket remains private and accepts JPG, PNG, or WebP receipts up to 10 MiB. Owner/Admin verification checks the private receipt object and records who reviewed it. Booking approval continues through the guarded schedule/resource-conflict RPC and now requires verified receipt proof covering the configured deposit (or full total when no deposit is configured). The generic reservation status RPC cannot directly confirm a booking. Demo mode defaults on: the UI labels demo submissions **“Demo Payment — No Actual Money Transfer”**, verified demo proofs can satisfy the review prerequisite, and demo amounts are excluded from collected-payment totals and revenue reports. Changing demo mode, payment destinations, or legacy instructions remains MFA-gated and audited.

After applying the migration, run the read-only checks in `supabase/verification/202610_evently_booking_payment_checks.sql`, then manually test with separate customer and Owner/Admin accounts:

- Submit a valid GCash, Maya, and Bank Transfer booking with a JPG/PNG/WebP receipt; confirm the booking and pending payment are both created and the receipt is not publicly accessible.
- Reject missing/inactive methods, malformed or duplicate references, missing/oversized/non-image receipts, an amount below the required deposit or above the balance, and a second pending submission.
- Verify a pending proof from both the Payments page and reservation drawer; confirm the customer sees the review result and rejection reason and can resubmit only after rejection.
- Confirm approval is blocked before proof verification, below the required deposit, for a missing receipt, without a saved schedule/resource, and when a confirmed schedule conflict exists. Then verify a valid booking through the Admin approval action and check the audit/activity and customer notification.
- With demo mode enabled, verify a proof and confirm it does not increase customer “amount paid”, reservation payment totals, or Admin revenue, while still allowing the explicitly labeled booking-review workflow. Confirm direct confirmation/status-transition calls and staff/customer approval attempts are denied.
- Confirm demo-mode and destination changes fail without a fresh MFA challenge and appear in the restricted audit trail.

The new migration and these end-to-end database scenarios have **not** been run against the live Supabase project from this workspace. TypeScript and the production build pass locally; do not treat the Admin approval issue as verified fixed until the migration is applied and the checks above pass against the actual project. The separate staff-dashboard recovery migration remains a separate decision and is not a prerequisite for this payment migration.
