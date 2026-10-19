-- READ-ONLY export required before authoring Phase 2 executable RPC SQL.
-- Run against the live/staging project and retain the complete output.

with required(signature) as (
  values
    ('public.create_evently_reservation(jsonb)'),
    ('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'),
    ('public.admin_review_payment(uuid,boolean,text)'),
    ('public.admin_set_reservation_status(uuid,public.booking_status,text)'),
    ('public.evently_submit_payment_proof(uuid,numeric,text,text,text)'),
    ('public.submit_evently_payment(uuid,numeric,text,text,text)'),
    ('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'),
    ('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)'),
    ('public.evently_admin_decide_schedule_proposal(uuid,boolean,text)'),
    ('public.admin_transition_reservation(uuid,text,text)'),
    ('public.evently_admin_approve_booking(uuid,boolean)'),
    ('public.evently_admin_approve_booking_before_readiness(uuid,boolean)'),
    ('public.evently_admin_approve_booking_before_payment_verification(uuid,boolean)'),
    ('public.evently_admin_approve_booking_before_shared_pool(uuid,boolean)'),
    ('public.is_evently_admin()'),
    ('public.evently_admin_check_reservation_schedule(uuid)'),
    ('public.evently_check_availability(uuid,date)')
)
select required.signature,
       proc.oid is not null as exists,
       case when proc.oid is not null then proc.prosecdef end as security_definer,
       case when proc.oid is not null then pg_catalog.pg_get_function_result(proc.oid) end as result_type,
       case when proc.oid is not null then pg_catalog.pg_get_function_arguments(proc.oid) end as arguments,
       case when proc.oid is not null then proc.proargnames end as argument_names,
       case when proc.oid is not null then proc.proacl end as privileges,
       case when proc.oid is not null then pg_catalog.pg_get_functiondef(proc.oid) end as full_definition
from required
left join pg_catalog.pg_proc proc on proc.oid=to_regprocedure(required.signature)
order by required.signature;

-- Include any additional current schedule/availability writer that may use a
-- different lock namespace or status convention from the repository drafts.
select proc.oid::regprocedure as signature,
       proc.prosecdef as security_definer,
       pg_catalog.pg_get_function_result(proc.oid) as result_type,
       pg_catalog.pg_get_function_arguments(proc.oid) as arguments,
       proc.proargnames as argument_names,
       proc.proacl as privileges,
       pg_catalog.pg_get_functiondef(proc.oid) as full_definition
from pg_catalog.pg_proc proc
join pg_catalog.pg_namespace namespace on namespace.oid=proc.pronamespace
where namespace.nspname='public'
  and proc.prokind='f'
  and (proc.proname ilike '%schedule%'
    or proc.proname ilike '%availability%'
    or proc.proname ilike '%reservation_status%'
    or proc.proname ilike '%approve_booking%')
order by proc.proname,proc.oid::regprocedure::text;
