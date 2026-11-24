-- migration-022-preflight (CMD-62): READ-ONLY. Run by a human on production BEFORE migration-022. Prints COUNTS ONLY, never a PIN.
--
-- 022 hashes every existing users.pin and NULLs the column. Every former PIN keeps working, weak ones included. These counts say what that
-- will carry over. A PIN that is not exactly 4 digits can never log in through pin-login today either (it accepts only ^\d{4}$).
SELECT count(*) FILTER (WHERE pin IS NOT NULL AND pin <> '')                                                              AS users_with_a_pin,
       count(*) FILTER (WHERE pin IS NOT NULL AND pin <> '' AND pin !~ '^[0-9]{4}$')                                      AS pin_not_4_digits,
       count(*) FILTER (WHERE pin ~ '^(\d)\1{3}$' OR (pin ~ '^[0-9]{4}$' AND (position(pin IN '0123456789') > 0
                                                                              OR position(pin IN '9876543210') > 0)))  AS pin_trivial,
       count(*) FILTER (WHERE pin = '')                                                                                   AS pin_empty_string,
       count(*)                                                                                                           AS users_total
  FROM public.users;
-- Also, by hand: confirm no production process reads or writes users.pin directly (CMD-11 lists unknowns). The temporary trigger in 022 keeps a
-- writer from storing plain text but a READER of users.pin will now see NULL.
