# EVENTLY — Venice Catering System

Next.js App Router application using React 19, TypeScript, Tailwind CSS v4, and the existing Supabase project.

## Development Server

A Next.js development server is running on port 8443 in the workspace preview. Use the existing server for visual checks; don't start a duplicate listener on that port.

## Project Structure

- `app/layout.tsx` — App Router root layout, metadata, global styles
- `app/[[...slug]]/page.tsx` — existing route-path bridge and server-side auth/role checks
- `app/evently-application.tsx` — client-only bridge to the browser-dependent existing app
- `proxy.ts` — Supabase cookie refresh and request-level role checks
- `src/App.tsx` — existing EVENTLY UI, customer pages, custom client navigation, auth flows
- `src/admin/AdminDashboard.tsx` — admin pages, staff management, recommendations, review analytics
- `src/staff/StaffPortal.tsx` — restricted staff workspace
- `src/index.css`, `src/admin/admin.css` — original global and admin design system, imported by `app/layout.tsx`
- `src/lib/supabase.ts` — Supabase SSR browser client and existing auth helpers
- `src/lib/supabase-server.ts` — cookie-aware server Supabase client
- `supabase/migrations/` — additive database migrations
- `supabase/functions/server/` — Supabase Edge Function code (Deno; not part of Next's TypeScript build)
- `NEXT-MIGRATION.md` — migration notes, local configuration, auth redirect setup, and validation scope

The route bridge intentionally keeps the legacy interactive UI client-rendered while App Router handles entry, cookie refresh, and protected route checks. Preserve the existing booking, payment, role, and review RPC signatures unless a verified database migration requires a change.

## Dependencies and commands

- Next.js 16, React 19, TypeScript
- Tailwind CSS v4 using `@tailwindcss/postcss`
- Supabase browser/server integration using `@supabase/ssr`
- `corepack pnpm dev`, `corepack pnpm build`, `corepack pnpm start`, `corepack pnpm exec tsc --noEmit`

Keep `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` public-only. Never put service-role credentials in app code or public environment variables.

## Styling

`app/layout.tsx` imports `src/index.css` and `src/admin/admin.css`. `src/index.css` retains the Tailwind v4 import and the existing Venice/Evently design system. Preserve current colors, typography, layouts, animations, responsive rules, and admin/staff treatments.

## Code quality

- Use double quotes for strings containing apostrophes (`"We're here to help"`), or escape them in single-quoted strings.
- Ensure JSX tags are closed and braces are balanced.
- Export components as default exports.
- Keep customer/admin/staff routes and the database as the authorization boundary; frontend guards are additional UX, not a substitute for RLS/RPC checks.
