-- Read-only checks for the prerequisites and resulting objects of:
--   20261013090000_evently_staff_and_reviews.sql
--   20261013120000_evently_review_edit_and_readiness.sql
--   20261013130000_evently_staff_role_readiness.sql
--   20261013140000_evently_staff_dashboard.sql
--   20261013150000_evently_staff_role_readiness_profile_aware.sql
--   20261014100000_evently_staff_dashboard_recovery.sql (optional live repair)
-- Run in Supabase SQL Editor for inspection only. No DDL or DML is performed.

-- 1. Inspect required table columns and the actual type of profiles.role.
with required_columns(table_name, column_name) as (
  values
    ('profiles','id'), ('profiles','role'), ('profiles','staff_active'), ('profiles','updated_at'),
    ('reservations','id'), ('reservations','customer_id'), ('reservations','reservation_code'),
    ('reservations','customer_name'), ('reservations','customer_email'), ('reservations','customer_phone'),
    ('reservations','service_type'), ('reservations','package_id'), ('reservations','package_name'),
    ('reservations','package_variant'), ('reservations','reservation_date'), ('reservations','start_time'),
    ('reservations','end_time'), ('reservations','resource_key'), ('reservations','resource_name'),
    ('reservations','status'), ('reservations','guest_count'), ('reservations','special_requests'),
    ('reservations','cancellation_reason'), ('reservations','schedule_mode'), ('reservations','package_variant_id'),
    ('reservations','resource_mode'), ('reservations','total_amount'), ('reservations','amount_paid'),
    ('reservations','remaining_balance'), ('reservations','payment_status'),
    ('reservations','created_at'), ('reservations','updated_at'),
    ('orders','id'), ('orders','customer_id'), ('orders','reservation_id'), ('orders','order_code'),
    ('orders','event_date'), ('orders','guest_count'), ('orders','package_name'), ('orders','created_at'),
    ('orders','updated_at'), ('orders','cancellation_reason'), ('orders','total_amount'),
    ('orders','amount_paid'), ('orders','remaining_balance'), ('orders','payment_status'),
    ('payments','id'), ('payments','customer_id'), ('payments','reservation_id'), ('payments','order_id'),
    ('payments','amount'), ('payments','status'), ('payments','method'), ('payments','reference_number'),
    ('payments','proof_url'), ('payments','rejection_reason'), ('payments','verified_at'),
    ('payments','verified_by'), ('payments','updated_at'),
    ('packages','id'), ('packages','name'), ('packages','service_type'), ('packages','schedule_mode'),
    ('packages','fixed_start_time'), ('packages','fixed_end_time'), ('packages','duration_minutes'),
    ('packages','operating_start_time'), ('packages','operating_end_time'), ('packages','resource_key'),
    ('package_variants','id'), ('package_variants','package_id'), ('package_variants','fixed_start_time'),
    ('package_variants','fixed_end_time'), ('package_variants','duration_minutes'),
    ('package_variants','operating_start_time'), ('package_variants','operating_end_time'), ('package_variants','resource_key'),
    ('evently_resources','resource_key'), ('evently_resources','is_active'),
    ('evently_staff_permissions','staff_id'), ('evently_staff_permissions','permission'),
    ('evently_staff_permissions','granted'), ('evently_staff_permissions','granted_by'), ('evently_staff_permissions','updated_at'),
    ('evently_staff_permission_policy','permission'), ('evently_staff_permission_policy','allowed_for_admins'),
    ('evently_staff_permission_policy','updated_by'), ('evently_staff_permission_policy','updated_at'),
    ('evently_booking_recommendations','id'), ('evently_booking_recommendations','reservation_id'),
    ('evently_booking_recommendations','staff_id'), ('evently_booking_recommendations','recommendation'),
    ('evently_booking_recommendations','reason'), ('evently_booking_recommendations','notes'),
    ('evently_booking_recommendations','review_state'), ('evently_booking_recommendations','decision_by'),
    ('evently_booking_recommendations','decision_at'), ('evently_booking_recommendations','decision_note'),
    ('evently_booking_recommendations','created_at'), ('evently_booking_recommendations','updated_at'),
    ('evently_reservation_staff_notes','id'), ('evently_reservation_staff_notes','reservation_id'), ('evently_reservation_staff_notes','staff_id'),
    ('evently_reservation_staff_notes','note'), ('evently_reservation_staff_notes','created_at'),
    ('evently_schedule_proposals','id'), ('evently_schedule_proposals','reservation_id'),
    ('evently_schedule_proposals','staff_id'), ('evently_schedule_proposals','proposed_date'),
    ('evently_schedule_proposals','proposed_start_time'), ('evently_schedule_proposals','proposed_end_time'),
    ('evently_schedule_proposals','proposed_resource_key'), ('evently_schedule_proposals','note'),
    ('evently_schedule_proposals','proposal_state'), ('evently_schedule_proposals','decided_by'),
    ('evently_schedule_proposals','decided_at'), ('evently_schedule_proposals','decision_note'),
    ('evently_schedule_proposals','created_at'),
    ('admin_activity_logs','admin_id'), ('admin_activity_logs','action'), ('admin_activity_logs','entity_type'),
    ('admin_activity_logs','entity_id'), ('admin_activity_logs','description'),
    ('notifications','user_id'), ('notifications','title'), ('notifications','message'), ('notifications','type'),
    ('notifications','entity_type'), ('notifications','entity_id'), ('notifications','dedupe_key'), ('notifications','is_read'),
    ('evently_review_analysis_rate_limits','user_id'), ('evently_review_analysis_rate_limits','window_started_at'),
    ('evently_review_analysis_rate_limits','request_count'),
    ('reviews','id'), ('reviews','customer_id'), ('reviews','reservation_id'), ('reviews','package_id'),
    ('reviews','rating'), ('reviews','review_text'), ('reviews','is_published'), ('reviews','moderation_status'),
    ('reviews','moderation_reason'), ('reviews','sentiment_label'), ('reviews','sentiment_confidence'),
    ('reviews','sentiment_analyzed_at'), ('reviews','sentiment_model_version'), ('reviews','created_at'), ('reviews','updated_at')
)
select required.table_name,
       required.column_name,
       (column_info.column_name is not null) as exists,
       column_info.data_type,
       column_info.udt_name
from required_columns required
left join information_schema.columns column_info
  on column_info.table_schema = 'public'
 and column_info.table_name = required.table_name
 and column_info.column_name = required.column_name
order by required.table_name, required.column_name;

-- Full read-only inventory of all columns used by the staff/review workflows
-- and their existing booking/payment dependencies, including optional legacy
-- status aliases not knowable from the checked-in migrations alone.
select table_name, column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = any(array[
    'profiles','reservations','orders','payments','notifications','admin_activity_logs',
    'packages','package_variants','evently_resources','reviews',
    'evently_staff_permissions','evently_staff_permission_policy',
    'evently_booking_recommendations','evently_reservation_staff_notes',
    'evently_schedule_proposals','evently_review_analysis_rate_limits'
  ])
order by table_name, ordinal_position;

-- orders may use either status or order_status; at least one must exist.
select exists (
  select 1 from information_schema.columns
  where table_schema = 'public'
    and table_name = 'orders'
    and column_name in ('status', 'order_status')
) as has_order_status_column;

-- 2. Confirm profiles.role enum type and labels without modifying the enum.
select namespace.nspname as enum_schema,
       enum_type.typname as enum_name,
       enum_value.enumsortorder,
       enum_value.enumlabel
from pg_catalog.pg_type enum_type
join pg_catalog.pg_namespace namespace on namespace.oid = enum_type.typnamespace
join pg_catalog.pg_enum enum_value on enum_value.enumtypid = enum_type.oid
where namespace.nspname = 'public'
  and enum_type.typname = 'user_role'
order by enum_value.enumsortorder;

select attribute.attname as column_name,
       format_type(attribute.atttypid, attribute.atttypmod) as column_type
from pg_catalog.pg_attribute attribute
where attribute.attrelid = 'public.profiles'::regclass
  and attribute.attname = 'role'
  and not attribute.attisdropped;

select role::text as role_value, count(*) as profile_count
from public.profiles
group by role::text
order by role_value;

-- 3. Verify exact RPC identities, return types, SECURITY DEFINER/search_path,
-- definitions and EXECUTE grants. Missing signatures appear with exists=false.
with expected_functions(signature) as (
  values
    ('public.is_evently_admin()'),
    ('public.create_evently_reservation(jsonb)'),
    ('public.submit_evently_payment(uuid,numeric,text,text,text)'),
    ('public.mark_evently_notifications_read(uuid[])'),
    ('public.admin_transition_order(uuid,text)'),
    ('public.admin_review_payment(uuid,text,text)'),
    ('public.evently_check_availability(uuid,date)'),
    ('public.evently_existing_column(regclass,text[])'),
    ('public.evently_status_value(regclass,text,text)'),
    ('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'),
    ('public.evently_admin_approve_booking(uuid,boolean)'),
    ('public.evently_admin_approve_booking_before_shared_pool(uuid,boolean)'),
    ('public.admin_transition_reservation(uuid,text,text)'),
    ('public.evently_staff_role_ready()'),
    ('public.evently_staff_permissions_ready()'),
    ('public.evently_current_profile_role()'),
    ('public.protect_evently_profile_role()'),
    ('public.evently_guard_customer_reservation_insert()'),
    ('public.evently_staff_has_permission(text)'),
    ('public.evently_staff_list_reservations()'),
    ('public.evently_staff_can_access_reservation(uuid)'),
    ('public.evently_staff_add_reservation_note(uuid,text)'),
    ('public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text)'),
    ('public.evently_admin_decide_schedule_proposal(uuid,boolean,text)'),
    ('public.evently_manage_staff_permission(uuid,text,boolean)'),
    ('public.evently_owner_set_staff_permission_policy(text,boolean)'),
    ('public.evently_admin_set_staff_active(uuid,boolean)'),
    ('public.evently_staff_submit_booking_recommendation(uuid,text,text,text)'),
    ('public.evently_admin_review_booking_recommendation(uuid,text,text,boolean)'),
    ('public.evently_staff_dashboard_stats()'),
    ('public.evently_staff_list_orders()'),
    ('public.evently_touch_recommendation_updated_at()'),
    ('public.evently_notify_staff_reservation_created()'),
    ('public.evently_notify_staff_schedule_change()'),
    ('public.evently_notify_staff_booking_confirmation()'),
    ('public.evently_notify_booking_recommendation()'),
    ('public.evently_notify_schedule_proposal()'),
    ('public.evently_review_text_has_profanity(text)'),
    ('public.evently_review_text_needs_moderation(text)'),
    ('public.evently_submit_customer_review(uuid,integer,text)'),
    ('public.evently_update_customer_review(uuid,integer,text)'),
    ('public.evently_admin_moderate_review(uuid,text,text)'),
    ('public.evently_record_review_sentiment(uuid,text,numeric,text,text)'),
    ('public.evently_review_features_ready()'),
    ('public.evently_consume_review_analysis_quota(uuid)')
)
select expected.signature,
       (function_info.oid is not null) as exists,
       case when function_info.oid is not null then pg_catalog.pg_get_function_identity_arguments(function_info.oid) end as identity_arguments,
       case when function_info.oid is not null then pg_catalog.pg_get_function_result(function_info.oid) end as result_type,
       function_info.prosecdef as security_definer,
       function_info.proconfig as function_settings,
       case when function_info.oid is not null then has_function_privilege('anon', function_info.oid, 'EXECUTE') end as anon_execute,
       case when function_info.oid is not null then has_function_privilege('authenticated', function_info.oid, 'EXECUTE') end as authenticated_execute,
       case when function_info.oid is not null then has_function_privilege('service_role', function_info.oid, 'EXECUTE') end as service_role_execute,
       case when function_info.oid is not null then pg_catalog.pg_get_functiondef(function_info.oid) end as function_definition
from expected_functions expected
left join pg_catalog.pg_proc function_info
  on function_info.oid = to_regprocedure(expected.signature)
order by expected.signature;

-- 4. Verify RLS enablement and policies on the tables changed by the staff
-- migrations. This also shows whether customer/Owner/Admin policies remain.
select relation.relname as table_name,
       relation.relrowsecurity as rowsecurity,
       relation.relforcerowsecurity as forcerowsecurity
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
where namespace.nspname = 'public'
  and relation.relname = any(array[
    'profiles','reservations','orders','payments','notifications','reviews',
    'evently_staff_permissions','evently_staff_permission_policy',
    'evently_booking_recommendations','evently_reservation_staff_notes',
    'evently_schedule_proposals','evently_review_analysis_rate_limits'
  ])
order by table_name;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where schemaname = 'public'
  and tablename = any(array[
    'profiles','reservations','orders','payments','notifications','reviews',
    'evently_staff_permissions','evently_staff_permission_policy',
    'evently_booking_recommendations','evently_reservation_staff_notes','evently_schedule_proposals'
  ])
order by tablename, policyname;

-- Required dashboard notification/update triggers (all read-only checks).
with expected_triggers(table_name, trigger_name) as (
  values
    ('reservations','evently_notify_staff_reservation_created'),
    ('reservations','evently_notify_staff_schedule_change'),
    ('reservations','evently_notify_staff_booking_confirmation'),
    ('evently_booking_recommendations','evently_notify_booking_recommendation'),
    ('evently_booking_recommendations','evently_touch_recommendation_updated_at'),
    ('evently_schedule_proposals','evently_notify_schedule_proposal')
)
select expected.table_name,
       expected.trigger_name,
       (installed.oid is not null) as exists,
       installed.tgenabled as enabled_state
from expected_triggers expected
left join pg_catalog.pg_trigger installed
  on installed.tgrelid = to_regclass('public.' || expected.table_name)
 and installed.tgname = expected.trigger_name
 and not installed.tgisinternal
order by expected.table_name, expected.trigger_name;

-- 5. Inspect direct browser write grants. Expected: no direct writes to staff
-- permission/recommendation tables; SELECT is granted subject to RLS.
select table_name,
       has_table_privilege('authenticated', to_regclass('public.' || table_name), 'SELECT') as authenticated_select,
       has_table_privilege('authenticated', to_regclass('public.' || table_name), 'INSERT') as authenticated_insert,
       has_table_privilege('authenticated', to_regclass('public.' || table_name), 'UPDATE') as authenticated_update,
       has_table_privilege('authenticated', to_regclass('public.' || table_name), 'DELETE') as authenticated_delete
from (values
  ('evently_staff_permissions'),
  ('evently_booking_recommendations'),
  ('evently_staff_permission_policy'),
  ('evently_reservation_staff_notes'),
  ('evently_schedule_proposals')
) as target_tables(table_name);

-- Required unique index for deduplicated customer/staff/admin notifications.
select exists (
  select 1
  from pg_catalog.pg_index index_info
  join pg_catalog.pg_class index_relation on index_relation.oid = index_info.indexrelid
  join pg_catalog.pg_namespace index_namespace on index_namespace.oid = index_relation.relnamespace
  join pg_catalog.pg_class table_relation on table_relation.oid = index_info.indrelid
  join pg_catalog.pg_namespace table_namespace on table_namespace.oid = table_relation.relnamespace
  where index_namespace.nspname = 'public'
    and table_namespace.nspname = 'public'
    and index_relation.relname = 'notifications_dedupe_key_unique'
    and table_relation.relname = 'notifications'
    and index_info.indisunique
) as notification_dedupe_index_ready;

-- Expected after applying the staff migrations: true.
select case when to_regprocedure('public.evently_staff_role_ready()') is null then null
            else public.evently_staff_role_ready() end as staff_role_ready,
       case when to_regprocedure('public.evently_staff_permissions_ready()') is null then null
            else public.evently_staff_permissions_ready() end as staff_permissions_ready;
