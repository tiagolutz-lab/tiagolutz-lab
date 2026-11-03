# AD_PARKING_LOT_PKG — DISPATCH Pseudocode
## Entry Point: DBMS_SCHEDULER Job (fires every 15 seconds)

```
SCHEDULER_JOB "AD_PARKING_LOT_DISPATCH_JOB"  [fires every 15s]
  CALL  AD_PARKING_LOT_PKG.DISPATCH()
```

---

## DISPATCH()

```
PROCEDURE DISPATCH
─────────────────────────────────────────────────────────────────────

STEP 0a — Remove Duplicates
  CALL  REMOVE_DUPLICATES()
    → Keeps lowest MSG_ID per business key; deletes the rest from AD_MSG_AUDIT

STEP 0b — Sequence Messages
  CALL  SEQUENCE_MSGS()
    → Promotes QUEUED / RETRY → READY_TO_DISPATCH in AD_MSG_AUDIT

STEP 1 — Discover interfaces with pending messages
  SELECT DISTINCT interface_id, stage_number, priority, dispatch_type, max_msgs
    FROM AD_MSG_AUDIT  a
    JOIN AD_INT_MASTER m  ON  m.INTERFACE_ID = a.INTERFACE_ID
   WHERE a.STATUS = 'READY_TO_DISPATCH'
     AND m.STATUS = 'A'
     AND m.OUTAGE = 'N'
     AND m.DISPATCH_TYPE IN ('ATP_INDIVIDUAL', 'ATP_GROUP')
     AND (m.DISPATCH_FREQUENCY IS NULL
          OR f_next_dispatch_date(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
   ORDER BY m.PRIORITY, INTERFACE_ID, STAGE_NUMBER
  → Load results into l_intfs[]

  IF l_intf_count = 0  → EXIT (nothing pending)

STEP 2 — Load all active OIC environments
  SELECT env_id, base_url, max_msgs
    FROM AD_OIC_ENVIRONMENTS
   WHERE status = 'A'
  → Load results into l_envs[]

  IF l_env_count = 0  → EXIT

  Generate run_id = TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3')

STEP 3 — Fetch live running instance counts (async, max 5s)
  UPDATE AD_OIC_ENVIRONMENTS SET LAST_RUNNING_COUNT = NULL  (clear previous)
  COMMIT

  FOR each env i:
    SPAWN scheduler job "AD_GET_INST_{run_id}_{i}"
      CALL  GET_RUNNING_INSTANCES(env_id)
        → HTTP GET to OIC /monitoring/rest/… endpoint
        → Writes result back to AD_OIC_ENVIRONMENTS.LAST_RUNNING_COUNT
        → Job auto-drops after completion

  POLL every 0.5s, up to 10 iterations (5s total):
    SELECT COUNT(*) FROM AD_OIC_ENVIRONMENTS WHERE LAST_RUNNING_COUNT IS NULL
    EXIT WHEN all envs have responded

  FOR each env i:
    READ  LAST_RUNNING_COUNT  (NULL treated as -1 = timeout/failed)
    SET   available_cap = NVL(MAX_MSGS, 2147483647)   ← message cap for this run
    FETCH bearer_token  = f_get_bearer_token(env_id)  ← OAuth token (cached or fresh)

STEP 4 — Process each interface (ordered by PRIORITY)
  FOR each intf in l_intfs[]:

    IF NOT f_validate_allocation(interface_id, stage_number)
       → allocation percentages don't sum to 100% → SKIP interface

    CASE dispatch_type:

      WHEN 'ATP_INDIVIDUAL':
        CALL  p_dispatch_individual_intf(
                envs, env_count, interface_id, stage_number,
                interface_cap  ← AD_INT_MASTER.MAX_MSGS (NULL = no limit),
                run_id, INOUT global_worker)
        UPDATE AD_INT_MASTER SET LAST_DISPATCHED_DATE = SYSDATE
        COMMIT

      WHEN 'ATP_GROUP':
        CALL  p_dispatch_group_intf(
                envs, env_count, interface_id, stage_number,
                interface_cap, run_id, INOUT global_worker)
        UPDATE AD_INT_MASTER SET LAST_DISPATCHED_DATE = SYSDATE
        COMMIT

EXCEPTION
  ROLLBACK
  p_log_error(...)
```

---

## p_dispatch_individual_intf()

```
PROCEDURE p_dispatch_individual_intf(envs, env_count, interface_id,
                                      stage_number, interface_cap,
                                      run_id, INOUT global_worker)
─────────────────────────────────────────────────────────────────────

1. Fetch all READY_TO_DISPATCH message IDs for this interface
   SELECT MSG_ID FROM AD_MSG_AUDIT a JOIN AD_INT_MASTER m
    WHERE a.INTERFACE_ID = interface_id
      AND a.STAGE_NUMBER = stage_number
      AND a.STATUS       = 'READY_TO_DISPATCH'
      AND m.STATUS       = 'A'  AND m.OUTAGE = 'N'
      AND m.DISPATCH_TYPE = 'ATP_INDIVIDUAL'
    ORDER BY PRIORITY, MSG_ID
   → BULK COLLECT in batches of 1000 → l_all_msg_ids[]
   IF total = 0 → RETURN

2. Determine chunk size
   chunk_size = GREATEST(50, NVL(INDIVIDUAL_BATCH_SIZE, 50))
   ┌─ i.e. minimum 50 messages per DB job and per OIC HTTP call ─┐

3. Compute quotas per environment
   CALL  f_compute_interface_quotas(
           envs, env_count, interface_id, stage_number,
           total_units  = total_msgs,          ← in messages
           interface_cap = interface_cap,       ← AD_INT_MASTER.MAX_MSGS (or NULL)
           OUT quotas[])                        ← messages per env
   ├─ STATIC:  proportional to env allocation % in AD_INT_ENV_ALLOCATION
   └─ DYNAMIC: proportional to (MAX_MSGS − running_count) per env
   Deducts quota from each env's available_cap (in messages)

4. Assign CHUNK_ID per message (round-robin across envs by quota)
   chunk_id format = "{run_id}_{global_worker}_{env_id}"
   global_worker increments every chunk_size messages assigned to same env

   FOR i = 1 to total:
     IF quota for current env exhausted → advance to next env
     IF MOD(assigned_to_env, chunk_size) = 0 → global_worker++
     chunk_id = "{run_id}_{global_worker}_{env_id}"
     assign chunk_id to message i
     increment assigned_to_env
   END FOR
   Messages with no env capacity → chunk_id = NULL (not dispatched this run)

5. Bulk UPDATE AD_MSG_AUDIT
   SET STATUS   = 'PROCESSING'  (if chunk_id assigned)
       CHUNK_ID = chunk_id
   COMMIT

6. Spawn one scheduler job per unique CHUNK_ID
   FOR each unique chunk_id:
     job_name = "AD_DISP_IND_{run_id}_{seq}"   (max 128 chars)
     CALL  p_submit_job(job_name, chunk_id, 'DISPATCH_INDIVIDUAL_CHUNK')
       → DBMS_SCHEDULER.CREATE_JOB, up to 5 retries on failure
       → Job calls: AD_PARKING_LOT_PKG.DISPATCH_INDIVIDUAL_CHUNK(chunk_id)
```

---

## p_dispatch_group_intf()

```
PROCEDURE p_dispatch_group_intf(envs, env_count, interface_id,
                                  stage_number, interface_cap,
                                  run_id, INOUT global_worker)
─────────────────────────────────────────────────────────────────────

1. Fetch all distinct (MSG_SEQUENCE, MSG_SUB_GROUP_ID) groups
   SELECT DISTINCT MSG_SEQUENCE, MSG_SUB_GROUP_ID FROM AD_MSG_AUDIT
    WHERE INTERFACE_ID = interface_id  AND STATUS = 'READY_TO_DISPATCH'
   → l_groups[]   total_groups = l_groups.COUNT
   IF total_groups = 0 → RETURN

2. Compute quotas per env (same as individual — units = groups here)
   CALL  f_compute_interface_quotas(total_units = total_groups, ...)

3. Assign one CHUNK_ID per group (round-robin across envs)
   global_worker++ for each group
   chunk_id = "{run_id}_{global_worker}_{env_id}"

4. Bulk UPDATE all msgs belonging to each group
   SET STATUS   = 'PROCESSING'
       CHUNK_ID = chunk_id
   COMMIT

5. Spawn one scheduler job per group (= per chunk_id)
   job_name = "AD_DISP_GRP_{run_id}_{seq}"
   CALL  p_submit_job(job_name, chunk_id, 'DISPATCH_GROUP_CHUNK')
     → Job calls: AD_PARKING_LOT_PKG.DISPATCH_GROUP_CHUNK(chunk_id)
```

---

## DISPATCH_INDIVIDUAL_CHUNK(chunk_id)  [runs in scheduler job]

```
PROCEDURE DISPATCH_INDIVIDUAL_CHUNK(chunk_id)
─────────────────────────────────────────────────────────────────────

1. Parse env_id from chunk_id (last segment after final '_')
   CALL  f_env_from_chunk(chunk_id) → env_id

2. Lookup base_url from AD_OIC_ENVIRONMENTS WHERE env_id = env_id
   If not found → mark all msgs in chunk as ERROR, RETURN

3. Fetch all PROCESSING messages for this chunk
   SELECT MSG_ID, MSG_OBJECT_ID, INTERFACE_ID, BUSINESS_IDENTIFIER1..5,
          RETRY_COUNT, MAX_RETRY_COUNT, RETRY_ENABLED,
          OIC_PROCESSOR_INTEGRATION_URI, INDIVIDUAL_BATCH_SIZE
     FROM AD_MSG_AUDIT a JOIN AD_INT_MASTER m
    WHERE a.CHUNK_ID = chunk_id  AND a.STATUS = 'PROCESSING'
   → BULK COLLECT into l_msgs[]
   IF empty → RETURN

4. Fetch bearer token:  f_get_bearer_token(env_id)

5. Determine OIC batch_size = NVL(INDIVIDUAL_BATCH_SIZE, 1)

6. HTTP batch loop  (processes l_msgs in sub-batches of batch_size)
   WHILE batch_start ≤ l_msgs.COUNT:
     batch_end = MIN(batch_start + batch_size − 1, COUNT)

     a. Build JSON array  [batch_start..batch_end]
        '[' + JSON_OBJECT(MsgId, MsgObjectId, InterfaceId, BusinessId1..5) + ']'
        Built via DBMS_LOB.APPEND to avoid 32,767-byte VARCHAR2 limit

     b. Convert CLOB → BLOB (AL32UTF8) via DBMS_LOB.CONVERTTOBLOB

     c. HTTP POST to base_url + OIC_PROCESSOR_INTEGRATION_URI
        Headers: Content-Type=application/json, Authorization=Bearer {token}
        Body: JSON array BLOB

        IF 401 → refresh token (f_get_bearer_token force_fresh=TRUE) → retry once
        IF 202 → success; leave rows as PROCESSING (OIC will update when done)
        IF other → mark batch as failed
        IF no token → mark batch as failed

     d. For each msg in batch:
        IF success   → status=NULL, error=NULL  (no update needed)
        IF failed    → IF retry_enabled='Y' AND retry_count < max_retry_count
                         → status='RETRY'
                       ELSE → status='ERROR'

     batch_start = batch_end + 1

7. FORALL update  (only rows with errors)
   UPDATE AD_MSG_AUDIT SET STATUS = status, ERROR_MESSAGE = error,
          RETRY_COUNT = RETRY_COUNT + 1 (if RETRY)
    WHERE MSG_ID = msg_id  AND error IS NOT NULL
   COMMIT

EXCEPTION
  ROLLBACK
  p_log_error(...)
  UPDATE all PROCESSING rows in chunk → ERROR
  COMMIT
```

---

## DISPATCH_GROUP_CHUNK(chunk_id)  [runs in scheduler job]

```
PROCEDURE DISPATCH_GROUP_CHUNK(chunk_id)
─────────────────────────────────────────────────────────────────────

1. Parse env_id, lookup base_url  (same as individual)

2. Fetch bearer token

3. Fetch all PROCESSING messages for this chunk (one group)
   → l_rows[]
   IF empty → RETURN

4. Build single JSON object from first row:
   { "msgSequence": N, "interfaceId": "X",
     "subGroupId": N,  "stageNumber": N }

5. HTTP POST (Bearer token or error):
   base_url + OIC_PROCESSOR_INTEGRATION_URI
   Body: JSON object (via UTL_RAW.CAST_TO_RAW — groups are small, no LOB needed)

   IF 401 → refresh token → retry once
   IF 202 → success; all group rows stay PROCESSING
   IF failed → mark all rows RETRY or ERROR based on retry config

6. UPDATE AD_MSG_AUDIT for failed rows  COMMIT

EXCEPTION → same as DISPATCH_INDIVIDUAL_CHUNK
```

---

## Key Data Flow Summary

```
SCHEDULER JOB (every 15s)
  └─► DISPATCH()
        ├─ 0a: REMOVE_DUPLICATES  [clean AD_MSG_AUDIT]
        ├─ 0b: SEQUENCE_MSGS      [QUEUED/RETRY → READY_TO_DISPATCH]
        ├─ 1:  query pending interfaces  (AD_MSG_AUDIT + AD_INT_MASTER)
        ├─ 2:  load environments         (AD_OIC_ENVIRONMENTS)
        ├─ 3:  async: N × GET_RUNNING_INSTANCES jobs → poll 0.5s × 10
        │       └─ writes LAST_RUNNING_COUNT per env
        │       └─ fetch bearer tokens per env
        └─ 4:  for each interface:
               ├─ validate allocation (AD_INT_ENV_ALLOCATION sums to 100%)
               │
               ├─ ATP_INDIVIDUAL → p_dispatch_individual_intf()
               │     ├─ fetch READY_TO_DISPATCH MSG_IDs
               │     ├─ compute chunk_size = GREATEST(50, INDIVIDUAL_BATCH_SIZE)
               │     ├─ f_compute_interface_quotas() → msgs per env
               │     ├─ assign CHUNK_IDs (round-robin)
               │     ├─ bulk UPDATE STATUS='PROCESSING', CHUNK_ID=…
               │     └─ spawn N scheduler jobs "AD_DISP_IND_…"
               │           └─► DISPATCH_INDIVIDUAL_CHUNK(chunk_id)
               │                 ├─ fetch PROCESSING msgs for chunk
               │                 ├─ build JSON array (DBMS_LOB.APPEND)
               │                 ├─ HTTP POST to OIC (DBMS_CLOUD.SEND_REQUEST)
               │                 │   [batch_size msgs per call, 401→token refresh]
               │                 └─ UPDATE errors/retries in AD_MSG_AUDIT
               │
               └─ ATP_GROUP → p_dispatch_group_intf()
                     ├─ fetch distinct (MSG_SEQUENCE, SUB_GROUP_ID) groups
                     ├─ f_compute_interface_quotas() → groups per env
                     ├─ assign CHUNK_IDs (one per group)
                     ├─ bulk UPDATE STATUS='PROCESSING', CHUNK_ID=…
                     └─ spawn N scheduler jobs "AD_DISP_GRP_…"
                           └─► DISPATCH_GROUP_CHUNK(chunk_id)
                                 ├─ fetch PROCESSING msgs for group
                                 ├─ build single JSON object
                                 ├─ HTTP POST to OIC
                                 └─ UPDATE errors/retries in AD_MSG_AUDIT

Message lifecycle:
  QUEUED / RETRY
     ↓  SEQUENCE_MSGS
  READY_TO_DISPATCH
     ↓  p_dispatch_individual/group_intf (CHUNK_ID assigned)
  PROCESSING
     ↓  HTTP 202 accepted by OIC
  [OIC integration updates status when processing completes]
  SUCCESS / ERROR / RETRY

Cap enforcement (all in messages):
  • AD_OIC_ENVIRONMENTS.MAX_MSGS  = available_cap per env per DISPATCH run
  • AD_INT_MASTER.MAX_MSGS         = interface cap per DISPATCH run (NULL=unlimited)
  • chunk_size                     = GREATEST(50, INDIVIDUAL_BATCH_SIZE)
    → controls both DB job size and OIC HTTP call size
```
