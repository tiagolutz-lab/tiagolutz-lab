-- =============================================================================
-- TEST_F_NEXT_DISPATCH_DATE.sql
--
-- Quick diagnostic for the dispatch frequency gate.
-- Run with SERVEROUTPUT ON.
--
-- Usage:
--   SET SERVEROUTPUT ON SIZE UNLIMITED
--   @TEST_F_NEXT_DISPATCH_DATE.sql
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT
PROMPT ── Test 1: NULL frequency (should always be due) ──────────────────────
DECLARE
    l_next DATE;
BEGIN
    l_next := AD_PARKING_LOT_PKG.F_NEXT_DISPATCH_DATE(
                  p_dispatch_frequency   => NULL,
                  p_last_dispatched_date => SYSDATE
              );
    DBMS_OUTPUT.PUT_LINE('Next fire : ' || TO_CHAR(l_next,  'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('SYSDATE   : ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Due now?  : ' || CASE WHEN l_next <= SYSDATE THEN 'YES — OK' ELSE 'NO — BUG' END);
END;
/

PROMPT
PROMPT ── Test 2: 50s interval, anchor = 43s ago (should NOT be due yet) ─────
PROMPT    Uses anchor as start_date — next fire should be anchor+50s
DECLARE
    l_next   DATE;
    l_anchor DATE := SYSDATE - (43/86400);   -- 43 seconds ago
BEGIN
    l_next := AD_PARKING_LOT_PKG.F_NEXT_DISPATCH_DATE(
                  p_dispatch_frequency   => 'FREQ=SECONDLY;INTERVAL=50',
                  p_last_dispatched_date => l_anchor
              );
    DBMS_OUTPUT.PUT_LINE('Anchor    : ' || TO_CHAR(l_anchor, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Next fire : ' || TO_CHAR(l_next,   'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Expected  : ' || TO_CHAR(l_anchor + (50/86400), 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('SYSDATE   : ' || TO_CHAR(SYSDATE,  'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Due now?  : ' || CASE WHEN l_next <= SYSDATE THEN 'YES — BUG (should be NO)' ELSE 'NO — OK' END);
END;
/

PROMPT
PROMPT ── Test 3: 50s interval, anchor = 55s ago (should be due) ─────────────
DECLARE
    l_next   DATE;
    l_anchor DATE := SYSDATE - (55/86400);   -- 55 seconds ago
BEGIN
    l_next := AD_PARKING_LOT_PKG.F_NEXT_DISPATCH_DATE(
                  p_dispatch_frequency   => 'FREQ=SECONDLY;INTERVAL=50',
                  p_last_dispatched_date => l_anchor
              );
    DBMS_OUTPUT.PUT_LINE('Anchor    : ' || TO_CHAR(l_anchor, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Next fire : ' || TO_CHAR(l_next,   'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Expected  : ' || TO_CHAR(l_anchor + (50/86400), 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('SYSDATE   : ' || TO_CHAR(SYSDATE,  'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Due now?  : ' || CASE WHEN l_next <= SYSDATE THEN 'YES — OK' ELSE 'NO — BUG (should be YES)' END);
END;
/

PROMPT
PROMPT ── Test 4: NULL last_dispatched_date, first-ever run (should be due) ───
DECLARE
    l_next DATE;
BEGIN
    l_next := AD_PARKING_LOT_PKG.F_NEXT_DISPATCH_DATE(
                  p_dispatch_frequency   => 'FREQ=SECONDLY;INTERVAL=50',
                  p_last_dispatched_date => NULL
              );
    DBMS_OUTPUT.PUT_LINE('Next fire : ' || TO_CHAR(l_next,  'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('SYSDATE   : ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('Due now?  : ' || CASE WHEN l_next <= SYSDATE THEN 'YES — OK' ELSE 'NO — BUG (should be YES)' END);
END;
/

PROMPT
PROMPT ── Test 5: Raw EVALUATE_CALENDAR_STRING using anchor as start_date ─────
PROMPT    This is what the fixed function will do internally.
PROMPT    next fire should be exactly anchor+50s, NOT be due yet at anchor+43s.
DECLARE
    l_anchor   TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP - INTERVAL '43' SECOND;
    l_next_run TIMESTAMP WITH TIME ZONE;
BEGIN
    DBMS_SCHEDULER.EVALUATE_CALENDAR_STRING(
        calendar_string   => 'FREQ=SECONDLY;INTERVAL=50',
        start_date        => l_anchor,          -- anchor as origin
        return_date_after => l_anchor,          -- same anchor as gate
        next_run_date     => l_next_run
    );
    DBMS_OUTPUT.PUT_LINE('Anchor      : ' || TO_CHAR(l_anchor,              'DD-MON-YYYY HH24:MI:SS TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('Next fire   : ' || TO_CHAR(l_next_run,            'DD-MON-YYYY HH24:MI:SS TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('Expected    : ' || TO_CHAR(l_anchor + INTERVAL '50' SECOND, 'DD-MON-YYYY HH24:MI:SS TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('SYSTIMESTAMP: ' || TO_CHAR(SYSTIMESTAMP,          'DD-MON-YYYY HH24:MI:SS TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('Due now?    : ' || CASE WHEN l_next_run <= SYSTIMESTAMP THEN 'YES — BUG (should be NO)' ELSE 'NO — OK' END);
END;
/
