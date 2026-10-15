-- migration-007-preflight.sql: READ-ONLY. Run in production before migration-007 to see what it will change.
SELECT
  b.payment_status AS current_label,
  CASE WHEN COALESCE(s.paid, 0) >= b.final_amount THEN 'paid'
       WHEN COALESCE(s.paid, 0) > 0 THEN 'partial' ELSE 'unpaid' END AS correct_label,
  b.is_locked,
  COUNT(*) AS bookings
FROM public.bookings b
LEFT JOIN (SELECT booking_id, SUM(amount) AS paid FROM public.payments GROUP BY booking_id) s ON s.booking_id = b.id
WHERE b.payment_status <> 'refunded'
  AND b.payment_status <> CASE WHEN COALESCE(s.paid, 0) >= b.final_amount THEN 'paid'
                               WHEN COALESCE(s.paid, 0) > 0 THEN 'partial' ELSE 'unpaid' END
GROUP BY 1, 2, 3
ORDER BY 4 DESC;
