-- Staff submission notifications are created by a database trigger, not by the browser.
-- This keeps alerts reliable regardless of which staff client sends a recommendation.
CREATE OR REPLACE FUNCTION public.evently_notify_admin_booking_recommendation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_reference text;
  v_staff_name text;
BEGIN
  IF NEW.review_state IS DISTINCT FROM 'awaiting_admin'
     OR (TG_OP = 'UPDATE' AND OLD.review_state = 'awaiting_admin') THEN
    RETURN NEW;
  END IF;
  SELECT reservation_code INTO v_reference FROM public.reservations WHERE id=NEW.reservation_id;
  SELECT full_name INTO v_staff_name FROM public.profiles WHERE id=NEW.staff_id;
  INSERT INTO public.notifications (user_id,title,message,type)
  SELECT p.id,
      'Staff booking recommendation awaiting approval',
      coalesce(nullif(v_staff_name,''),'A staff member')
        || ' recommended ' || CASE WHEN NEW.recommendation='approve' THEN 'approval' ELSE 'rejection' END
        || ' for booking ' || coalesce(v_reference, NEW.reservation_id::text)
        || '. Review in Admin > Staff Approval Queue. [review:' || NEW.id::text || ']',
      'booking'
  FROM public.profiles p
  WHERE p.role::text IN ('admin','owner');
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS evently_staff_recommendation_admin_alert ON public.evently_booking_recommendations;
CREATE TRIGGER evently_staff_recommendation_admin_alert
AFTER INSERT OR UPDATE OF review_state
ON public.evently_booking_recommendations
FOR EACH ROW
EXECUTE FUNCTION public.evently_notify_admin_booking_recommendation();

-- Alert admins about recommendations that were waiting before this fix.
INSERT INTO public.notifications(user_id,title,message,type)
SELECT p.id,'Staff booking recommendation awaiting approval',
       coalesce(nullif(s.full_name,''),'A staff member') || ' recommended '
       || CASE WHEN r.recommendation='approve' THEN 'approval' ELSE 'rejection' END
       || ' for booking ' || coalesce(b.reservation_code,r.reservation_id::text)
       || '. Review in Admin > Staff Approval Queue. [review:' || r.id::text || ']','booking'
FROM public.evently_booking_recommendations r
JOIN public.profiles p ON p.role::text IN ('admin','owner')
LEFT JOIN public.profiles s ON s.id = r.staff_id
LEFT JOIN public.reservations b ON b.id = r.reservation_id
WHERE r.review_state='awaiting_admin'
AND NOT EXISTS(
  SELECT 1 FROM public.notifications n
  WHERE n.user_id=p.id AND n.message LIKE '%[review:' || r.id::text || ']%'
);
