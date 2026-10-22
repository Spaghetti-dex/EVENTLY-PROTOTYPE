-- Apply to production Supabase project after staging/rollback testing.
-- Fix table-specific fields in the shared booking/order cutoff trigger.
-- Previously OLD.event_date was evaluated on reservations, which only has reservation_date.
CREATE OR REPLACE FUNCTION public.evently_customer_change_cutoff()
RETURNS trigger LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE
 v_date date;
 v_today date := (now() AT TIME ZONE 'Asia/Manila')::date;
 v_change_requested boolean := false;
BEGIN
 IF TG_OP <> 'UPDATE' THEN RETURN NEW; END IF;
 IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM OLD.customer_id THEN RETURN NEW; END IF;
 IF TG_TABLE_NAME = 'reservations' THEN
   v_date := OLD.reservation_date;
   v_change_requested :=
      (NEW.status::text = 'cancelled' AND OLD.status::text IS DISTINCT FROM 'cancelled')
      OR NEW.reservation_date IS DISTINCT FROM OLD.reservation_date;
 ELSIF TG_TABLE_NAME = 'orders' THEN
   v_date := OLD.event_date;
   v_change_requested :=
      (NEW.status::text = 'cancelled' AND OLD.status::text IS DISTINCT FROM 'cancelled')
      OR NEW.event_date IS DISTINCT FROM OLD.event_date;
 ELSE
   RAISE EXCEPTION 'Unsupported table for booking cutoff: %', TG_TABLE_NAME;
 END IF;
 IF v_change_requested AND (v_date IS NULL OR v_today > v_date - 3) THEN
   RAISE EXCEPTION 'Cancellation and rescheduling require at least 3 calendar days advance notice (Asia/Manila).';
 END IF;
 RETURN NEW;
END
$function$;

-- Require a customer-entered transaction/reference number in demo and actual payment RPCs.
CREATE OR REPLACE FUNCTION public.evently_submit_demo_payment(p_reservation_id uuid, p_method text, p_reference_number text DEFAULT NULL::text, p_proof_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.reservations%rowtype; v_amount numeric(12,2); v_paid numeric(12,2); v_pending integer; v_id uuid; v_method public.payment_method;
begin
 if auth.uid() is null then raise exception 'Please sign in'; end if;
 select * into r from public.reservations where id=p_reservation_id and customer_id=auth.uid() for update;
 if not found then raise exception 'Reservation not found'; end if;
 if r.status::text not in ('pending','confirmed') then raise exception 'Reservation is not payable'; end if;
 if p_method not in ('gcash','bank_transfer','cash') then raise exception 'Choose GCash, bank transfer, or cash'; end if;
 v_method:=p_method::public.payment_method;
 select coalesce(sum(amount),0) into v_paid from public.payments where reservation_id=r.id and status='verified' and demo_mode=true;
 if exists(select 1 from public.payments where reservation_id=r.id and demo_mode=false and status in ('pending','verified')) then raise exception 'Cannot mix demo and actual payments on one reservation'; end if;
 select count(*) into v_pending from public.payments where reservation_id=r.id and status='pending';
 if v_pending>0 then raise exception 'Another payment is awaiting review'; end if;
 if r.total_amount is null or r.total_amount<=0 then raise exception 'Reservation total is unavailable'; end if;
 if v_paid>=r.total_amount then raise exception 'Reservation is already fully paid'; end if;
 v_amount:=case when v_paid=0 then round(r.total_amount*.30,2) else round(r.total_amount-v_paid,2) end;
 if nullif(btrim(coalesce(p_reference_number,'')),'') is null or length(btrim(p_reference_number)) > 160 then
   raise exception 'A sample payment reference (1–160 characters) is required';
 end if;
 if p_method='cash' and nullif(btrim(coalesce(p_proof_path,'')),'') is not null then
   raise exception 'Demo cash payments cannot include a receipt file';
 end if;
 if nullif(btrim(coalesce(p_proof_path,'')),'') is not null then
   if split_part(p_proof_path,'/',1)<>auth.uid()::text or not exists(select 1 from storage.objects where bucket_id='payment-proofs' and name=p_proof_path) then raise exception 'Proof must be uploaded privately to your own folder'; end if;
 end if;
 insert into public.payments(customer_id,reservation_id,amount,method,reference_number,status,proof_url,demo_mode)
 values(auth.uid(),r.id,v_amount,v_method,nullif(btrim(p_reference_number),''),'pending',nullif(btrim(p_proof_path),''),true) returning id into v_id;
 return jsonb_build_object('payment_id',v_id,'amount',v_amount,'status','pending','demo_mode',true,'message','Demo payment submitted for admin review. No funds transferred.');
end $function$;


CREATE OR REPLACE FUNCTION public.evently_submit_payment_proof(p_reservation_id uuid, p_amount numeric, p_method text, p_reference_number text, p_proof_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_customer uuid := auth.uid();
    v_res public.reservations%ROWTYPE;
    v_path text;
    v_method public.payments.method%TYPE;
    v_payment_id uuid;
BEGIN
    IF v_customer IS NULL THEN
        RAISE EXCEPTION 'Sign in is required'
            USING ERRCODE = '28000';
    END IF;

    -- Reservation must belong to the customer.
    SELECT *
    INTO v_res
    FROM public.reservations
    WHERE id = p_reservation_id
      AND customer_id = v_customer
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Reservation not found or access denied';
    END IF;

    IF v_res.status::text NOT IN ('pending', 'confirmed') THEN
        RAISE EXCEPTION
            'Payment submission is unavailable for this reservation';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Enter a valid payment amount';
    END IF;

    IF p_amount > COALESCE(v_res.total_amount, 0) THEN
        RAISE EXCEPTION
            'Payment exceeds the reservation total';
    END IF;

    IF NULLIF(btrim(p_method), '') IS NULL THEN
        RAISE EXCEPTION 'Payment method is required';
    END IF;

    IF NULLIF(btrim(p_reference_number), '') IS NULL OR length(btrim(p_reference_number)) > 160 THEN
        RAISE EXCEPTION 'A payment transaction reference (1–160 characters) is required';
    END IF;

    -- Convert the text input into the existing
    -- database method enum without assuming its name.
    SELECT (
        pg_catalog.jsonb_populate_record(
            NULL::public.payments,
            pg_catalog.jsonb_build_object(
                'method', p_method
            )
        )
    ).method
    INTO v_method;

    -- Store the private bucket object path.
    v_path := NULLIF(btrim(p_proof_path), '');

    IF v_path IS NULL OR length(v_path) > 1000 THEN
        RAISE EXCEPTION 'Valid receipt path is required';
    END IF;

    -- Customer files must be in their own folder.
    IF split_part(v_path, '/', 1) <> v_customer::text THEN
        RAISE EXCEPTION 'Receipt does not belong to this customer'
            USING ERRCODE = '42501';
    END IF;

    IF lower(
        pg_catalog.regexp_replace(
            v_path, '^.*\.', ''
        )
    ) NOT IN ('jpg', 'jpeg', 'png', 'webp') THEN
        RAISE EXCEPTION 'Unsupported receipt file type';
    END IF;

    -- Confirm receipt was uploaded to Supabase Storage.
    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects obj
        WHERE obj.bucket_id = 'payment-proofs'
          AND obj.name = v_path
    ) THEN
        RAISE EXCEPTION
            'Uploaded payment receipt was not found';
    END IF;

    -- Serialize submissions using the same receipt.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'evently-payment-proof:' || v_path, 0
        )
    );

    -- Prevent reuse of the same receipt.
    IF EXISTS (
        SELECT 1
        FROM public.payments
        WHERE proof_url = v_path
    ) THEN
        RAISE EXCEPTION
            'This payment receipt has already been submitted';
    END IF;

    INSERT INTO public.payments (
        customer_id,
        reservation_id,
        amount,
        method,
        reference_number,
        status,
        proof_url
    )
    VALUES (
        v_customer,
        p_reservation_id,
        p_amount,
        v_method,
        NULLIF(btrim(p_reference_number), ''),
        'pending',
        v_path
    )
    RETURNING id INTO v_payment_id;

    RETURN pg_catalog.jsonb_build_object(
        'payment_id', v_payment_id,
        'reservation_id', p_reservation_id,
        'status', 'pending',
        'message', 'Receipt submitted for admin verification'
    );
END;
$function$;;


NOTIFY pgrst, 'reload schema';
