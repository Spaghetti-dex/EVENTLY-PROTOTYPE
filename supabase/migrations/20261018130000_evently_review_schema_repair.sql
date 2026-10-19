-- Repair the review workflow against the live relation:
-- reviews.reservation_id -> reservations.id -> reservations.package_id.
-- No existing review or reservation is deleted or rewritten except for adding
-- its privacy-screened public projection and broad service category.

alter table public.reviews
  add column if not exists sentiment_model_version text,
  add column if not exists sentiment_status text not null default 'pending',
  add column if not exists public_review_text text,
  add column if not exists service_category text,
  add column if not exists sentiment_confidence numeric(6,5),
  add column if not exists sentiment_analyzed_at timestamptz,
  add column if not exists sentiment_label text,
  add column if not exists moderation_status text not null default 'pending',
  add column if not exists moderation_reason text,
  add column if not exists is_published boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

alter table public.reviews alter column review_text drop not null;

create table if not exists public.evently_review_analysis_rate_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0
);
alter table public.evently_review_analysis_rate_limits enable row level security;
revoke all on public.evently_review_analysis_rate_limits from public, anon, authenticated;

update public.reviews
set sentiment_status = case
      when nullif(btrim(review_text), '') is null then 'unavailable'
      when sentiment_label in ('positive','neutral','negative') then 'complete'
      when sentiment_status = 'failed' then 'failed'
      else 'pending'
    end;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.reviews'::regclass
      and conname = 'evently_reviews_sentiment_status_check'
  ) then
    alter table public.reviews add constraint evently_reviews_sentiment_status_check
      check (sentiment_status in ('pending','complete','unavailable','failed')) not valid;
  end if;
end;
$$;
alter table public.reviews validate constraint evently_reviews_sentiment_status_check;

create or replace function public.evently_review_text_has_profanity(p_text text)
returns boolean
language sql immutable set search_path = ''
as $$
  with normalized as (
    select regexp_replace(translate(lower(coalesce(p_text,'')), '013457@!$', 'oieastais'), '[^a-z]+', ' ', 'g') as body
  )
  select body ~ '(^| )(fuck|fucking|shit|bullshit|bitch|bastard|asshole|cunt|putangina|putang ina|gago|tanga|bobo|pakyu|puki)( |$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])f[^[:alpha:]]*u[^[:alpha:]]*c[^[:alpha:]]*k([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])s[^[:alpha:]]*h[^[:alpha:]]*i[^[:alpha:]]*t([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])g[^[:alpha:]]*a[^[:alpha:]]*g[^[:alpha:]]*o([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])t[^[:alpha:]]*a[^[:alpha:]]*n[^[:alpha:]]*g[^[:alpha:]]*a([^[:alpha:]]|$)'
  from normalized;
$$;

create or replace function public.evently_review_text_needs_moderation(p_text text)
returns boolean
language sql immutable set search_path = ''
as $$
  select lower(coalesce(p_text,'')) ~* '(kill[[:space:]]+you|you[[:space:]]+should[[:space:]]+die|go[[:space:]]+die|threaten(ed|ing)?|racial[[:space:]]+slur|homophobic[[:space:]]+slur)'
    or coalesce(p_text,'') ~* '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
    or coalesce(p_text,'') ~* '\+?[[:digit:]][[:digit:] ()-]{7,}[[:digit:]]'
    or coalesce(p_text,'') ~* '(https?://|www\.)'
    or lower(coalesce(p_text,'')) ~* '(^|[[:space:]])(buy now|click here|limited offer|earn money fast)([[:space:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[[:space:]])([[:alnum:]_]+)([[:space:]]+\2){3,}([[:space:]]|$)';
$$;

-- Internal helper. It never returns private reservation/customer fields. If the
-- submitted text contains a known identity or booking detail, it is withheld
-- from the public projection; generic email, phone, and UUID patterns are
-- redacted as a second safeguard. Original review_text remains unchanged.
create or replace function public.evently_safe_public_review_text(
  p_customer_id uuid, p_reservation_id uuid, p_review_text text
) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_private record;
  v_text text := nullif(btrim(coalesce(p_review_text,'')), '');
begin
  if v_text is null then return null; end if;
  select profile.full_name, profile.username, profile.email, profile.mobile_number,
         reservation.customer_name, reservation.customer_email, reservation.customer_phone,
         reservation.reservation_code, reservation.package_name, reservation.package_variant,
         reservation.reservation_date, reservation.start_time, reservation.end_time,
         reservation.resource_name, reservation.special_requests
    into v_private
  from public.reservations reservation
  left join public.profiles profile on profile.id = p_customer_id
  where reservation.id = p_reservation_id and reservation.customer_id = p_customer_id;

  if not found then
    return '[Customer feedback withheld to protect private booking details]';
  end if;

  if (nullif(v_private.full_name,'') is not null and position(lower(v_private.full_name) in lower(v_text)) > 0)
    or (nullif(v_private.username,'') is not null and position(lower(v_private.username) in lower(v_text)) > 0)
    or (nullif(v_private.email,'') is not null and position(lower(v_private.email) in lower(v_text)) > 0)
    or (nullif(v_private.mobile_number,'') is not null and position(lower(v_private.mobile_number) in lower(v_text)) > 0)
    or (nullif(v_private.customer_name,'') is not null and position(lower(v_private.customer_name) in lower(v_text)) > 0)
    or (nullif(v_private.customer_email,'') is not null and position(lower(v_private.customer_email) in lower(v_text)) > 0)
    or (nullif(v_private.customer_phone,'') is not null and position(lower(v_private.customer_phone) in lower(v_text)) > 0)
    or (nullif(v_private.reservation_code,'') is not null and position(lower(v_private.reservation_code) in lower(v_text)) > 0)
    or (nullif(v_private.package_name,'') is not null and position(lower(v_private.package_name) in lower(v_text)) > 0)
    or (nullif(v_private.package_variant,'') is not null and position(lower(v_private.package_variant) in lower(v_text)) > 0)
    or (nullif(v_private.reservation_date::text,'') is not null and position(lower(v_private.reservation_date::text) in lower(v_text)) > 0)
    or (nullif(v_private.start_time::text,'') is not null and position(lower(v_private.start_time::text) in lower(v_text)) > 0)
    or (nullif(v_private.end_time::text,'') is not null and position(lower(v_private.end_time::text) in lower(v_text)) > 0)
    or (nullif(v_private.resource_name,'') is not null and position(lower(v_private.resource_name) in lower(v_text)) > 0)
    or (nullif(v_private.special_requests,'') is not null and position(lower(v_private.special_requests) in lower(v_text)) > 0)
  then
    return '[Customer feedback withheld to protect private booking details]';
  end if;

  v_text := regexp_replace(v_text, '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '[redacted email]', 'gi');
  v_text := regexp_replace(v_text, '\+?[[:digit:]][[:digit:] ()-]{7,}[[:digit:]]', '[redacted phone]', 'g');
  v_text := regexp_replace(v_text, '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-5][[:xdigit:]]{3}-[89abAB][[:xdigit:]]{3}-[[:xdigit:]]{12}', '[redacted ID]', 'g');
  return v_text;
end;
$$;

-- Resolve the category from the reservation's actual package relationship.
update public.reviews review
set service_category = case
      when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
      when lower(coalesce(package.service_type::text,'')) like '%pool%'
        or lower(coalesce(package.service_type::text,'')) like '%resort%'
        or lower(coalesce(package.service_type::text,'')) like '%room%'
        or lower(coalesce(package.service_type::text,'')) like '%stay%'
        or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
      when lower(coalesce(package.service_type::text,'')) like '%event%'
        or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
      else 'Venice experience'
    end
from public.reservations reservation
left join public.packages package on package.id = reservation.package_id
where reservation.id = review.reservation_id
  and (review.service_category is null or btrim(review.service_category) = '');

update public.reviews review
set service_category = 'Venice experience'
where review.service_category is null or btrim(review.service_category) = '';

update public.reviews review
set public_review_text = public.evently_safe_public_review_text(review.customer_id, review.reservation_id, review.review_text);

create or replace function public.evently_guard_one_review_per_reservation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.reservation_id::text, 0));
  if exists (
    select 1 from public.reviews existing
    where existing.reservation_id = new.reservation_id and existing.id <> new.id
  ) then
    raise exception 'A review already exists for this booking';
  end if;
  return new;
end;
$$;
do $$
begin
  if exists (select 1 from public.reviews group by reservation_id having count(*) > 1) then
    raise exception 'Duplicate legacy reviews exist for a reservation; no records were changed. Resolve duplicates explicitly before creating the unique review index.';
  end if;
end;
$$;
create unique index if not exists evently_reviews_one_per_reservation_uidx
  on public.reviews(reservation_id);
drop trigger if exists evently_one_review_per_reservation on public.reviews;
create trigger evently_one_review_per_reservation
  before insert or update of reservation_id on public.reviews
  for each row execute function public.evently_guard_one_review_per_reservation();

create or replace function public.evently_submit_customer_review(
  p_reservation_id uuid, p_rating integer, p_review_text text
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_review_id uuid;
  v_customer_id uuid := auth.uid();
  v_service_category text;
  v_review_text text := nullif(btrim(coalesce(p_review_text,'')), '');
  v_public_text text;
  v_flagged boolean;
begin
  if v_customer_id is null then raise exception 'Sign in to submit a review'; end if;
  if not exists (select 1 from public.profiles where id = v_customer_id and role = 'customer') then
    raise exception 'Only customer accounts may submit a review';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5 stars'; end if;
  if length(coalesce(v_review_text,'')) > 3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  if v_review_text is not null and public.evently_review_text_has_profanity(v_review_text) then
    raise exception 'Please edit profanity or abusive wording before submitting your review';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_reservation_id::text, 0));
  select case
      when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
      when lower(coalesce(package.service_type::text,'')) like '%pool%'
        or lower(coalesce(package.service_type::text,'')) like '%resort%'
        or lower(coalesce(package.service_type::text,'')) like '%room%'
        or lower(coalesce(package.service_type::text,'')) like '%stay%'
        or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
      when lower(coalesce(package.service_type::text,'')) like '%event%'
        or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
      else 'Venice experience'
    end into v_service_category
  from public.reservations reservation
  left join public.packages package on package.id = reservation.package_id
  where reservation.id = p_reservation_id
    and reservation.customer_id = v_customer_id
    and lower(reservation.status::text) = 'completed'
  for share of reservation;
  if not found then raise exception 'Only the customer who completed this booking may review it'; end if;

  v_public_text := public.evently_safe_public_review_text(v_customer_id, p_reservation_id, v_review_text);
  v_flagged := v_review_text is not null and (
    public.evently_review_text_has_profanity(v_review_text)
    or public.evently_review_text_needs_moderation(v_review_text)
    or v_public_text like '[Customer feedback withheld%'
  );

  insert into public.reviews(
    customer_id, reservation_id, rating, review_text, public_review_text, service_category,
    is_published, moderation_status, moderation_reason, sentiment_label,
    sentiment_confidence, sentiment_analyzed_at, sentiment_model_version, sentiment_status,
    created_at, updated_at
  ) values (
    v_customer_id, p_reservation_id, p_rating, v_review_text,
    v_public_text, v_service_category, not v_flagged,
    case when v_flagged then 'flagged' else 'approved' end,
    case when v_flagged then 'Automated review screen flagged content for Administrator review' else null end,
    null, null, null, null, case when v_review_text is null then 'unavailable' else 'pending' end, now(), now()
  ) returning id into v_review_id;
  return v_review_id;
exception when unique_violation then
  raise exception 'A review already exists for this booking';
end;
$$;

create or replace function public.evently_update_customer_review(
  p_review_id uuid, p_rating integer, p_review_text text
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_customer_id uuid := auth.uid();
  v_reservation_id uuid;
  v_service_category text;
  v_review_text text := nullif(btrim(coalesce(p_review_text,'')), '');
  v_public_text text;
  v_flagged boolean;
begin
  if v_customer_id is null or not exists (select 1 from public.profiles where id = v_customer_id and role = 'customer') then
    raise exception 'Only signed-in customers may update a review';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5 stars'; end if;
  if length(coalesce(v_review_text,'')) > 3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  if v_review_text is not null and public.evently_review_text_has_profanity(v_review_text) then
    raise exception 'Please edit profanity or abusive wording before submitting your review';
  end if;

  select reservation_id into v_reservation_id
  from public.reviews where id = p_review_id and customer_id = v_customer_id for update;
  if not found then raise exception 'Review not found for this customer'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation_id::text, 0));
  select case
      when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
      when lower(coalesce(package.service_type::text,'')) like '%pool%'
        or lower(coalesce(package.service_type::text,'')) like '%resort%'
        or lower(coalesce(package.service_type::text,'')) like '%room%'
        or lower(coalesce(package.service_type::text,'')) like '%stay%'
        or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
      when lower(coalesce(package.service_type::text,'')) like '%event%'
        or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
      else 'Venice experience'
    end into v_service_category
  from public.reservations reservation
  left join public.packages package on package.id = reservation.package_id
  where reservation.id = v_reservation_id
    and reservation.customer_id = v_customer_id
    and lower(reservation.status::text) = 'completed'
  for share of reservation;
  if not found then raise exception 'Only the customer who completed this booking may update its review'; end if;

  v_public_text := public.evently_safe_public_review_text(v_customer_id, v_reservation_id, v_review_text);
  v_flagged := v_review_text is not null and (
    public.evently_review_text_has_profanity(v_review_text)
    or public.evently_review_text_needs_moderation(v_review_text)
    or v_public_text like '[Customer feedback withheld%'
  );

  update public.reviews
  set rating = p_rating,
      review_text = v_review_text,
      public_review_text = v_public_text,
      service_category = v_service_category,
      is_published = not v_flagged,
      moderation_status = case when v_flagged then 'flagged' else 'approved' end,
      moderation_reason = case when v_flagged then 'Automated review screen flagged edited content for Administrator review' else null end,
      sentiment_label = null, sentiment_confidence = null, sentiment_analyzed_at = null,
      sentiment_model_version = null,
      sentiment_status = case when v_review_text is null then 'unavailable' else 'pending' end,
      updated_at = now()
  where id = p_review_id and customer_id = v_customer_id;
  return p_review_id;
end;
$$;

create or replace function public.evently_admin_moderate_review(
  p_review_id uuid, p_decision text, p_reason text default null
) returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin()
    and not (p_decision = 'flagged' and public.evently_staff_has_permission('moderate_reviews')) then
    raise exception 'Review moderation access required';
  end if;
  if not public.is_evently_admin() and p_decision <> 'flagged' then
    raise exception 'Staff may flag reviews for administrator oversight but cannot publish or reject them';
  end if;
  if p_decision not in ('approved','rejected','flagged') then raise exception 'Invalid moderation decision'; end if;
  if p_decision <> 'approved' and nullif(btrim(p_reason), '') is null then raise exception 'A moderation reason is required'; end if;

  update public.reviews
  set moderation_status = p_decision,
      is_published = case when public.is_evently_admin() then (p_decision = 'approved') else is_published end,
      moderation_reason = nullif(btrim(p_reason), ''), updated_at = now()
  where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'review_' || p_decision, 'review', p_review_id,
    coalesce(nullif(btrim(p_reason), ''), 'Review moderated'));
end;
$$;

create or replace function public.evently_record_review_sentiment(
  p_review_id uuid, p_sentiment text, p_confidence numeric,
  p_model_version text, p_analyzed_text text
) returns void language plpgsql security definer set search_path = ''
as $$
declare v_current_text text;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted analysis service required';
  end if;
  if p_sentiment not in ('positive','neutral','negative') then raise exception 'Invalid sentiment label'; end if;
  if nullif(btrim(p_model_version), '') is null then raise exception 'A sentiment model version is required'; end if;
  select review_text into v_current_text from public.reviews where id = p_review_id for update;
  if not found then raise exception 'Review not found'; end if;
  if nullif(btrim(v_current_text), '') is null then raise exception 'Star-only reviews do not have a sentiment result'; end if;
  if v_current_text is distinct from p_analyzed_text then raise exception 'Review text changed during analysis'; end if;
  update public.reviews
  set sentiment_label = p_sentiment,
      sentiment_confidence = case when p_confidence between 0 and 1 then p_confidence else null end,
      sentiment_analyzed_at = now(), sentiment_model_version = p_model_version,
      sentiment_status = 'complete', updated_at = now()
  where id = p_review_id;
end;
$$;

create or replace function public.evently_consume_review_analysis_quota(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted analysis service required';
  end if;
  if p_user_id is null then raise exception 'An analysis owner is required'; end if;
  insert into public.evently_review_analysis_rate_limits(user_id, window_started_at, request_count)
  values (p_user_id, now(), 1)
  on conflict (user_id) do update set
    request_count = case
      when public.evently_review_analysis_rate_limits.window_started_at < now() - interval '1 minute' then 1
      else public.evently_review_analysis_rate_limits.request_count + 1
    end,
    window_started_at = case
      when public.evently_review_analysis_rate_limits.window_started_at < now() - interval '1 minute' then now()
      else public.evently_review_analysis_rate_limits.window_started_at
    end
  returning request_count into v_count;
  return v_count <= 8;
end;
$$;

create or replace function public.evently_review_features_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select to_regclass('public.reviews') is not null
    and (
      select count(*) = 17
      from pg_catalog.pg_attribute
      where attrelid = 'public.reviews'::regclass
        and attname = any(array[
          'id','customer_id','reservation_id','rating','review_text','public_review_text','service_category',
          'is_published','moderation_status','moderation_reason','sentiment_label','sentiment_confidence',
          'sentiment_analyzed_at','sentiment_model_version','sentiment_status','created_at','updated_at'
        ]) and not attisdropped
    )
    and to_regprocedure('public.evently_submit_customer_review(uuid,integer,text)') is not null
    and to_regprocedure('public.evently_update_customer_review(uuid,integer,text)') is not null
    and to_regprocedure('public.evently_review_text_has_profanity(text)') is not null
    and to_regprocedure('public.evently_review_text_needs_moderation(text)') is not null
    and to_regprocedure('public.evently_record_review_sentiment(uuid,text,numeric,text,text)') is not null
    and to_regprocedure('public.evently_consume_review_analysis_quota(uuid)') is not null
    and to_regprocedure('public.evently_admin_moderate_review(uuid,text,text)') is not null
    and to_regclass('public.evently_public_reviews') is not null
    and exists (select 1 from pg_catalog.pg_class
      where oid = 'public.evently_public_reviews'::regclass
        and coalesce(reloptions, array[]::text[]) @> array['security_invoker=true'])
    and has_table_privilege('anon', 'public.evently_public_reviews', 'select')
    and exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.reviews'::regclass
      and tgname = 'evently_one_review_per_reservation' and not tgisinternal);
$$;

-- Safe, non-definer public projection. It reads only the stored privacy-screened
-- text, generic labels and public-facing aggregates. RLS remains active for the
-- invoker, including anonymous visitors.
create or replace view public.evently_public_reviews
with (security_invoker = true, security_barrier = true)
as
select rating,
       public_review_text as review_text,
       service_category,
       created_at as review_date,
       'Verified Customer'::text as display_name,
       true as verified_booking
from public.reviews
where is_published = true and moderation_status = 'approved';

alter table public.reviews enable row level security;
drop policy if exists "Published reviews are public; authors and moderators can read" on public.reviews;
drop policy if exists "Evently restrict review row visibility" on public.reviews;
drop policy if exists "Review rows are private to authors and authorized moderators" on public.reviews;
drop policy if exists "Evently restrict private review row visibility" on public.reviews;
drop policy if exists "Evently approved public review rows" on public.reviews;
drop policy if exists "Evently restrict anonymous reviews" on public.reviews;
drop policy if exists "Evently customer and moderator review rows" on public.reviews;
drop policy if exists "Evently restrict customer and moderator review rows" on public.reviews;

create policy "Evently approved public review rows" on public.reviews for select to anon
  using (is_published = true and moderation_status = 'approved');
create policy "Evently restrict anonymous reviews" on public.reviews as restrictive for select to anon
  using (is_published = true and moderation_status = 'approved');
create policy "Evently customer and moderator review rows" on public.reviews for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));
create policy "Evently restrict customer and moderator review rows" on public.reviews as restrictive for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));

revoke insert, update, delete on public.reviews from public, anon, authenticated;
revoke all on public.reviews from public, anon;
do $$
declare v_columns text;
begin
  select string_agg(pg_catalog.quote_ident(a.attname), ', ' order by a.attnum)
    into v_columns
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.reviews'::regclass
    and a.attnum > 0 and not a.attisdropped;
  if v_columns is not null then
    execute pg_catalog.format('revoke select (%s) on public.reviews from public, anon', v_columns);
  end if;
end;
$$;
grant select on public.reviews to authenticated;
grant select (rating, public_review_text, service_category, created_at, is_published, moderation_status)
  on public.reviews to anon;
revoke all on public.evently_public_reviews from public, anon, authenticated;
grant select on public.evently_public_reviews to anon, authenticated;

revoke all on function public.evently_review_text_has_profanity(text) from public, anon, authenticated;
revoke all on function public.evently_review_text_needs_moderation(text) from public, anon, authenticated;
revoke all on function public.evently_safe_public_review_text(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.evently_guard_one_review_per_reservation() from public, anon, authenticated;
revoke all on function public.evently_submit_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_update_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_admin_moderate_review(uuid,text,text) from public;
revoke all on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) from public, anon, authenticated;
revoke all on function public.evently_consume_review_analysis_quota(uuid) from public, anon, authenticated;
revoke all on function public.evently_review_features_ready() from public;
grant execute on function public.evently_submit_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_update_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_admin_moderate_review(uuid,text,text) to authenticated;
grant execute on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) to service_role;
grant execute on function public.evently_consume_review_analysis_quota(uuid) to service_role;
grant execute on function public.evently_review_features_ready() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
