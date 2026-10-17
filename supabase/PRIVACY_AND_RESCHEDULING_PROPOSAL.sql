-- PROPOSAL ONLY — DO NOT APPLY.
--
-- The current customer booking UI has no Privacy Notice acknowledgment storage
-- and no customer rescheduling RPC/table. The current public availability RPC
-- takes package_id/date only. This proposal preserves existing reservations,
-- package prices, payment approval, and Admin/Staff decisions; it is not a
-- complete or deployable implementation until the reviewed RPC and RLS work is
-- supplied and tested.
--
-- Before producing an executable migration, EVENTLY must provide/approve:
--   * The data controller's legal entity name, DPO/privacy contact, complete
--     recipient/processor list, and retention schedule. No values are invented.
--   * Whether an acknowledgment is required, which notice version it records,
--     and the lawful basis for each processing purpose. Acknowledgment is not
--     automatically treated as consent.
--   * Handling of reservations whose event start is not assigned yet.
--   * Catering availability/capacity rules. No maximum concurrent events or
--     guest capacity exists in the current catalog; a missing capacity row must
--     return unknown/unavailable, never a fabricated “available” result.
--   * Cancellation terms/refund policy. None were found in the current customer
--     flow or schema. Existing admin_transition_reservation() is Admin/Owner
--     authorized and changes reservation status directly; it is not a customer
--     cancellation-request workflow. Do not expose it to customers or infer a
--     deadline, fee, or refund amount.
--   * Combined-booking representation and synchronization. Current reservations
--     have one package/resource and no linked service components.
--
-- Proposed additive schema only (review before uncommenting):
/*
alter table public.reservations
  add column privacy_notice_version text,
  add column privacy_acknowledged_at timestamptz;

create table public.evently_reschedule_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id),
  customer_id uuid not null references auth.users(id),
  original_reservation_date date not null,
  original_start_time time not null,
  original_end_time time,
  requested_reservation_date date not null,
  requested_start_time time not null,
  requested_end_time time not null,
  request_status text not null default 'pending'
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index evently_one_pending_reschedule_per_reservation
  on public.evently_reschedule_requests (reservation_id)
  where request_status = 'pending';

create index evently_reschedule_customer_history_idx
  on public.evently_reschedule_requests (customer_id, requested_at desc);

alter table public.evently_reschedule_requests enable row level security;
revoke all on public.evently_reschedule_requests from public, anon, authenticated;
grant select on public.evently_reschedule_requests to authenticated;
create policy "Customers and admins read reschedule requests"
  on public.evently_reschedule_requests for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin());

create table public.evently_cancellation_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id),
  customer_id uuid not null references auth.users(id),
  request_reason text not null check (length(trim(request_reason)) > 0),
  request_status text not null default 'pending'
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index evently_one_pending_cancellation_per_reservation
  on public.evently_cancellation_requests (reservation_id)
  where request_status = 'pending';

create index evently_cancellation_customer_history_idx
  on public.evently_cancellation_requests (customer_id, requested_at desc);

alter table public.evently_cancellation_requests enable row level security;
revoke all on public.evently_cancellation_requests from public, anon, authenticated;
grant select on public.evently_cancellation_requests to authenticated;
create policy "Customers and admins read cancellation requests"
  on public.evently_cancellation_requests for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin());
*/

-- Required reviewed SECURITY DEFINER operations (not defined here):
-- 1. Customer request RPC: authenticate; lock/read the owned reservation; reject
--    cancelled/rejected/completed reservations and missing original start time;
--    compute original_start_at as
--      ((original_reservation_date + original_start_time) at time zone 'Asia/Manila');
--    accept only when now() <= original_start_at - interval '72 hours' (exactly
--    72 hours is allowed); validate proposed local times and actual resources;
--    lock by resource_key + date, check overlap, and create a pending request.
-- 2. Admin decision RPC: require existing Admin/Owner authorization, re-check
--    availability under the same lock, update the original reservation only on
--    approval, preserve payment/pricing snapshots, and append an audit record.
-- 3. Customer history RPC/select: return only the authenticated customer's
--    requests. Admin/Staff views must enforce current granular permissions.
-- 4. Booking-create integration: store privacy_notice_version and server-side
--    acknowledgment timestamp only after approved notice/lawful-basis wording.
-- 5. Customer cancellation-request RPC: verify ownership and active status,
--    require a non-empty reason, create a pending request only, and never update
--    reservation status or issue a refund from the customer request.
-- 6. Admin cancellation decision: authorize only through is_evently_admin(),
--    record the decision/audit trail, and call the existing status transition
--    only after approval. No cancellation deadline, fee, or refund policy is
--    configured, so do not calculate or promise any refund in UI or RPC.
-- 7. Customer Manage Booking UI should be wired only after the secure request and
--    Admin-decision RPCs are applied and verified. Until then, neither a
--    decorative customer action nor a direct client reservation update is safe.
--
-- Review/test plan required before rollout:
--   * 73h and exactly 72h before the original start pass; 71h, now/past, missing
--     start time, cancelled/rejected/completed status, and wrong-owner requests
--     fail. Use a transaction-controlled test clock/fixture, not device time.
--   * Duplicate pending requests fail through both a row lock and the partial
--     unique index. Two simultaneous requests for one exclusive resource/time
--     cannot both be approved.
--   * Venue overlap tests resolve resource_key from reservation/variant/package
--     and include cross-midnight intervals and reservations with unset times.
--   * Catering request/reschedule returns unavailable/unknown without an
--     approved capacity window; never defaults to “available”.
--   * Cancellation request leaves the original reservation/payment untouched;
--     only an Admin approval invokes the established status-transition path;
--     rejection leaves the booking unchanged and sends a customer notification.
--   * Customers can read only their own request rows; Staff and non-admins
--     cannot approve; no payment records or historical prices are rewritten.
--
-- Rollback: first disable/revoke the new RPC EXECUTE grants and remove the
--   customer UI entry points. Keep submitted request/audit rows for audit/legal
--   review. Do not drop the request tables or privacy acknowledgment fields if
--   they contain data. No migration is to be applied until these tests, policy
--   approvals, and Admin/Staff view changes are reviewed.
--
-- Catering rescheduling must remain unavailable until an Admin-managed
-- capacity/commitment source is approved. For combined reservations, both
-- venue and catering components must be revalidated and updated atomically.
