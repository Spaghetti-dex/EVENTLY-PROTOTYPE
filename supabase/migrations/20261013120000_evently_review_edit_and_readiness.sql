-- Incremental review workflow hardening for the existing public.reviews table.
-- This leaves the original customer/reservation/rating/text/publication columns intact.

alter table public.reviews
  add column if not exists package_id uuid references public.packages(id) on delete set null,
  add column if not exists moderation_status text not null default 'pending',
  add column if not exists moderation_reason text,
  add column if not exists sentiment_label text,
  add column if not exists sentiment_confidence numeric(6,5),
  add column if not exists sentiment_analyzed_at timestamptz,
  add column if not exists sentiment_model_version text,
  add column if not exists updated_at timestamptz not null default now();

update public.reviews review
set package_id = reservation.package_id
from public.reservations reservation
where review.reservation_id = reservation.id
  and review.package_id is null;

update public.reviews
set moderation_status = 'approved'
where is_published and moderation_status = 'pending';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_rating_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_rating_check check (rating between 1 and 5) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_moderation_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_moderation_check check (moderation_status in ('pending','approved','rejected','flagged')) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_sentiment_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_sentiment_check check (sentiment_label is null or sentiment_label in ('positive','neutral','negative')) not valid;
  end if;
end;
$$;

create or replace function public.evently_submit_customer_review(
  p_reservation_id uuid, p_rating integer, p_review_text text
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_review_id uuid; v_package_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to submit a review'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Only customer accounts may submit a review';
  end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'Rating must be between 1 and 5'; end if;
  if length(trim(coalesce(p_review_text,''))) < 10 then raise exception 'Write at least 10 characters in your review'; end if;
  if length(p_review_text) > 3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  if public.evently_review_text_has_profanity(p_review_text) then
    raise exception 'Please edit profanity or abusive wording before submitting your review';
  end if;
  select reservation.package_id into v_package_id
  from public.reservations reservation
  where reservation.id = p_reservation_id
    and reservation.customer_id = auth.uid()
    and lower(reservation.status::text) = 'completed'
  for share;
  if not found then raise exception 'Only the customer who completed this booking may review it'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_reservation_id::text, 0));
  if exists (select 1 from public.reviews where reservation_id = p_reservation_id and customer_id = auth.uid()) then
    raise exception 'A review already exists for this booking. Edit that review instead.';
  end if;

  insert into public.reviews(
    customer_id, reservation_id, package_id, rating, review_text, moderation_status,
    moderation_reason, is_published, sentiment_label, sentiment_confidence,
    sentiment_analyzed_at, sentiment_model_version, updated_at
  ) values (
    auth.uid(), p_reservation_id, v_package_id, p_rating, trim(p_review_text),
    case when public.evently_review_text_needs_moderation(p_review_text) then 'flagged' else 'pending' end,
    case when public.evently_review_text_needs_moderation(p_review_text)
      then 'Automated flag: potentially abusive phrasing requires manual review' else null end,
    false, null, null, null, null, now()
  ) returning id into v_review_id;
  return v_review_id;
exception when unique_violation then
  raise exception 'A review already exists for this booking. Edit that review instead.';
end;
$$;

create or replace function public.evently_update_customer_review(
  p_review_id uuid, p_rating integer, p_review_text text
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_reservation_id uuid; v_package_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to update your review'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Only customer accounts may update a review';
  end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'Rating must be between 1 and 5'; end if;
  if length(trim(coalesce(p_review_text,''))) < 10 then raise exception 'Write at least 10 characters in your review'; end if;
  if length(p_review_text) > 3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  if public.evently_review_text_has_profanity(p_review_text) then
    raise exception 'Please edit profanity or abusive wording before submitting your review';
  end if;

  select reservation_id into v_reservation_id
  from public.reviews where id = p_review_id and customer_id = auth.uid() for update;
  if not found then raise exception 'Review not found for this customer'; end if;
  select reservation.package_id into v_package_id
  from public.reservations reservation
  where reservation.id = v_reservation_id
    and reservation.customer_id = auth.uid()
    and lower(reservation.status::text) = 'completed'
  for share;
  if not found then raise exception 'Only the customer who completed this booking may update its review'; end if;

  update public.reviews
  set package_id = v_package_id,
      rating = p_rating,
      review_text = trim(p_review_text),
      is_published = false,
      moderation_status = case when public.evently_review_text_needs_moderation(p_review_text) then 'flagged' else 'pending' end,
      moderation_reason = case when public.evently_review_text_needs_moderation(p_review_text)
        then 'Automated flag: potentially abusive phrasing requires manual review' else null end,
      sentiment_label = null,
      sentiment_confidence = null,
      sentiment_analyzed_at = null,
      sentiment_model_version = null,
      updated_at = now()
  where id = p_review_id and customer_id = auth.uid();
  return p_review_id;
end;
$$;

create or replace function public.evently_admin_moderate_review(
  p_review_id uuid, p_decision text, p_reason text default null
) returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin() and not (p_decision = 'flagged' and public.evently_staff_has_permission('moderate_reviews')) then
    raise exception 'Review moderation access required';
  end if;
  if not public.is_evently_admin() and p_decision <> 'flagged' then
    raise exception 'Staff can flag reviews for admin oversight but cannot publish or reject them';
  end if;
  if p_decision not in ('approved','rejected','flagged') then raise exception 'Invalid moderation decision'; end if;
  if p_decision <> 'approved' and nullif(trim(p_reason), '') is null then raise exception 'A moderation reason is required'; end if;

  update public.reviews set moderation_status = p_decision,
    is_published = case when public.is_evently_admin() then (p_decision = 'approved') else is_published end,
    moderation_reason = nullif(trim(p_reason), ''), updated_at = now()
  where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'review_' || p_decision, 'review', p_review_id,
      coalesce(nullif(trim(p_reason), ''), 'Review moderated'));
end;
$$;

-- Only the trusted Edge Function may write model output. The analyzed text is
-- compared again in the transaction so a concurrent edit cannot store stale sentiment.
drop function if exists public.evently_record_review_sentiment(uuid,text,numeric,text);
create or replace function public.evently_record_review_sentiment(
  p_review_id uuid, p_sentiment text, p_confidence numeric, p_model_version text, p_analyzed_text text
) returns void language plpgsql security definer set search_path = ''
as $$
declare v_current_text text;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted analysis service required';
  end if;
  if p_sentiment not in ('positive','neutral','negative') then raise exception 'Invalid sentiment label'; end if;
  select review_text into v_current_text from public.reviews where id = p_review_id for update;
  if not found then raise exception 'Review not found'; end if;
  if v_current_text is distinct from p_analyzed_text then
    raise exception 'Review text changed during analysis; analyze the updated text instead';
  end if;
  update public.reviews set sentiment_label = p_sentiment,
    sentiment_confidence = case when p_confidence between 0 and 1 then p_confidence else null end,
    sentiment_analyzed_at = now(), sentiment_model_version = p_model_version,
    updated_at = now()
  where id = p_review_id;
end;
$$;

create or replace function public.evently_review_features_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select to_regclass('public.reviews') is not null
    and (
      select count(*) = 15
      from pg_catalog.pg_attribute
      where attrelid = 'public.reviews'::regclass
        and attname = any(array[
          'id','customer_id','reservation_id','package_id','rating','review_text','is_published',
          'moderation_status','moderation_reason','sentiment_label','sentiment_confidence',
          'sentiment_analyzed_at','sentiment_model_version','created_at','updated_at'
        ])
        and not attisdropped
    )
    and to_regprocedure('public.evently_submit_customer_review(uuid,integer,text)') is not null
    and to_regprocedure('public.evently_update_customer_review(uuid,integer,text)') is not null
    and to_regprocedure('public.evently_admin_moderate_review(uuid,text,text)') is not null
    and to_regprocedure('public.evently_record_review_sentiment(uuid,text,numeric,text,text)') is not null
    and to_regprocedure('public.evently_consume_review_analysis_quota(uuid)') is not null;
$$;

revoke insert, update, delete on public.reviews from public, anon, authenticated;
revoke all on function public.evently_submit_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_update_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_admin_moderate_review(uuid,text,text) from public;
revoke all on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) from public, anon, authenticated;
revoke all on function public.evently_review_features_ready() from public;
grant select on public.reviews to authenticated;
grant execute on function public.evently_submit_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_update_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_admin_moderate_review(uuid,text,text) to authenticated;
grant execute on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) to service_role;
grant execute on function public.evently_review_features_ready() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
