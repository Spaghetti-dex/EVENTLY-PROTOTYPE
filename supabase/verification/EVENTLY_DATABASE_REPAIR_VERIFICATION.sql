-- Read-only post-repair checks. Run after EVENTLY_COMPLETE_DATABASE_FIX.sql.
-- The assertion block raises on a failed contract; the trailing SELECTs give
-- a concise report to save with the deployment record.
do $$
begin
  if public.evently_review_features_ready() is distinct from true then
    raise exception 'FAIL: review readiness returned false';
  end if;
  if not has_table_privilege('anon','public.evently_public_reviews','select') then
    raise exception 'FAIL: anonymous role cannot read the safe public projection';
  end if;
  if has_table_privilege('anon','public.reviews','select')
     or has_column_privilege('anon','public.reviews','id','select')
     or has_column_privilege('anon','public.reviews','customer_id','select')
     or has_column_privilege('anon','public.reviews','reservation_id','select')
     or has_column_privilege('anon','public.reviews','review_text','select') then
    raise exception 'FAIL: anonymous role can read private review table fields';
  end if;
  if not exists(select 1 from pg_catalog.pg_class where oid='public.evently_public_reviews'::regclass
    and reloptions @> array['security_invoker=true']) then
    raise exception 'FAIL: public review view must be security_invoker';
  end if;
  if has_function_privilege('anon','public.evently_submit_customer_review(uuid,integer,text)','execute')
     or has_function_privilege('authenticated','public.evently_record_review_sentiment(uuid,text,numeric,text,text)','execute')
     or has_function_privilege('authenticated','public.evently_consume_review_analysis_quota(uuid)','execute') then
    raise exception 'FAIL: review RPC execution grants are too broad';
  end if;
  if has_function_privilege('authenticated','public.admin_review_payment(uuid,text,text)','execute') is false then
    raise exception 'FAIL: Administrator payment review RPC is unavailable';
  end if;
  if has_function_privilege('authenticated','public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)','execute') is false then
    raise exception 'FAIL: audited Administrator override RPC is unavailable';
  end if;
  if to_regprocedure('public.evently_customer_request_catering_change(uuid,text,text,date,time,time)') is null
     or to_regprocedure('public.evently_admin_decide_catering_change(uuid,text,text)') is null
     or not exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.reservations'::regclass
       and tgname='evently_guard_catering_change_request' and not tgisinternal) then
    raise exception 'FAIL: database-enforced Catering request/approval workflow is missing';
  end if;
  if has_function_privilege('anon','public.evently_customer_request_catering_change(uuid,text,text,date,time,time)','execute')
     or has_function_privilege('anon','public.evently_admin_decide_catering_change(uuid,text,text)','execute') then
    raise exception 'FAIL: anonymous role can submit or decide a Catering change request';
  end if;
  if position('72 hours' in pg_catalog.pg_get_functiondef(
       'public.evently_customer_request_catering_change(uuid,text,text,date,time,time)'::regprocedure))=0 then
    raise exception 'FAIL: Catering request function does not enforce the 72-hour rule';
  end if;
  if not exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.reservations'::regclass
       and tgname='evently_guard_catering_change_request' and not tgisinternal) then
    raise exception 'FAIL: direct Catering date/time/cancellation changes are not guarded';
  end if;
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
    ) and price in (100,150,200) and deposit_percentage=30 and resource_key='venice-main-pool'
       and resource_mode='exclusive' and schedule_mode in ('fixed','timed')) <> 3 then
    raise exception 'FAIL: verified pool package configuration does not match';
  end if;
  if to_regclass('cron.job') is not null and not exists(
    select 1 from cron.job where jobname='evently-expire-unpaid-reservations'
  ) then raise exception 'FAIL: unpaid reservation expiry job is missing'; end if;
end;
$$;

select public.evently_review_features_ready() as review_features_ready,
       to_regclass('public.evently_public_reviews') as public_review_view,
       has_table_privilege('anon','public.evently_public_reviews','select') as anon_can_read_projection,
       has_table_privilege('anon','public.reviews','select') as anon_can_read_base_table,
       has_column_privilege('anon','public.reviews','customer_id','select') as anon_can_read_customer_id,
       has_column_privilege('anon','public.reviews','reservation_id','select') as anon_can_read_reservation_id,
       has_function_privilege('authenticated','public.evently_customer_request_catering_change(uuid,text,text,date,time,time)','execute') as customer_can_request_catering_change,
       has_function_privilege('authenticated','public.evently_admin_decide_catering_change(uuid,text,text)','execute') as authenticated_can_call_admin_decision_rpc,
       has_column_privilege('authenticated','public.reservations','update') as customer_direct_reservation_update,
       has_column_privilege('authenticated','public.payments','update') as customer_direct_payment_update;

select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and table_name in ('reviews','reservations','payments','packages')
  and (table_name,column_name) in (
    ('reviews','reservation_id'),('reviews','sentiment_model_version'),('reviews','sentiment_status'),
    ('reviews','public_review_text'),('reviews','service_category'),('reservations','payment_due_at'),
    ('reservations','expired_at'),('packages','deposit_percentage')
  ) order by table_name,column_name;

select policyname, permissive, roles, cmd, qual, with_check
from pg_catalog.pg_policies where schemaname='public'
  and tablename in ('reviews','reservations','payments','orders','profiles','evently_catering_change_requests')
order by tablename,policyname;

select namespace.nspname as schema_name, procedure.proname as function_name,
       pg_catalog.pg_get_function_identity_arguments(procedure.oid) as arguments,
       procedure.prosecdef as security_definer,
       has_function_privilege('anon',procedure.oid,'execute') as anon_execute,
       has_function_privilege('authenticated',procedure.oid,'execute') as authenticated_execute,
       has_function_privilege('service_role',procedure.oid,'execute') as service_role_execute
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public' and procedure.proname in (
  'evently_submit_customer_review','evently_update_customer_review','evently_admin_moderate_review',
  'evently_record_review_sentiment','evently_review_features_ready','evently_check_availability',
  'create_evently_reservation','submit_evently_payment','admin_review_payment',
  'evently_admin_override_reservation','evently_expire_unpaid_reservations'
) order by procedure.proname,arguments;
