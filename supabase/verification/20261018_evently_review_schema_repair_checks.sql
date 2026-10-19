-- Run after 20261018130000_evently_review_schema_repair.sql in Supabase SQL Editor.
-- Read-only assertions for the repaired schema and public access boundary.
do $$
begin
  if public.evently_review_features_ready() is distinct from true then
    raise exception 'Review feature readiness returned false';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'reviews'
      and column_name = 'sentiment_model_version'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'reviews'
      and column_name = 'sentiment_status'
  ) then
    raise exception 'Sentiment metadata columns are missing';
  end if;
  if to_regprocedure('public.evently_record_review_sentiment(uuid,text,numeric,text,text)') is null
    or to_regprocedure('public.evently_review_text_has_profanity(text)') is null
    or to_regprocedure('public.evently_review_text_needs_moderation(text)') is null
    or to_regprocedure('public.evently_submit_customer_review(uuid,integer,text)') is null
    or to_regprocedure('public.evently_update_customer_review(uuid,integer,text)') is null then
    raise exception 'One or more required review RPCs are missing';
  end if;
  if not has_table_privilege('anon', 'public.evently_public_reviews', 'select')
    or has_column_privilege('anon', 'public.reviews', 'customer_id', 'select')
    or has_column_privilege('anon', 'public.reviews', 'reservation_id', 'select')
    or has_column_privilege('anon', 'public.reviews', 'id', 'select') then
    raise exception 'Anonymous review projection permissions are unsafe';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.evently_public_reviews'::regclass
      and coalesce(reloptions, array[]::text[]) @> array['security_invoker=true']
  ) then
    raise exception 'Public review view is not security_invoker';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.reviews'::regclass and relrowsecurity
  ) then
    raise exception 'RLS is not enabled on reviews';
  end if;
  if has_function_privilege('anon', 'public.evently_submit_customer_review(uuid,integer,text)', 'execute')
    or has_function_privilege('authenticated', 'public.evently_record_review_sentiment(uuid,text,numeric,text,text)', 'execute') then
    raise exception 'Review RPC execution grants are unsafe';
  end if;
end;
$$;

select public.evently_review_features_ready() as review_features_ready,
       has_table_privilege('anon', 'public.evently_public_reviews', 'select') as anon_can_read_safe_view,
       has_column_privilege('anon', 'public.reviews', 'customer_id', 'select') as anon_can_read_customer_id,
       has_column_privilege('anon', 'public.reviews', 'reservation_id', 'select') as anon_can_read_reservation_id,
       has_column_privilege('anon', 'public.reviews', 'id', 'select') as anon_can_read_review_id;
