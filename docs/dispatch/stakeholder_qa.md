# Stakeholder Q&A — AD_PARKING_LOT_PKG

Questions raised by James Chu (10 Nov 2026) after reviewing the OIC → ATP dispatcher slide deck.

---

## Slide 8 — Can error messages be passed back to the source system?

Yes. The Parking Lot follows a three-phase design: Persist → Dispatch → Process.
Error handling and source-system notification belong to the **processing phase**, not the dispatcher.
The dispatcher's responsibility ends once it successfully hands the message off to OIC (HTTP 202).
From that point, the OIC processor integration is responsible for executing business logic,
handling downstream errors, and — if needed — notifying the source system (ERP, HCM, etc.) of data issues.

## Slide 8 — After a data issue is fixed and a new message is generated, how is the previous failed message discarded?

The failed message stays in `AD_MSG_AUDIT` with `STATUS = 'ERROR'` — a terminal state the dispatcher
never re-processes. When the source system sends a corrected message, it arrives as a new QUEUED row
and is picked up independently on the next cycle. The original error record remains as an audit trail
but does not interfere with the new message.

## Slide 6 — When message A fails, how does the system handle message B — discarded or processed the same?

Controlled by `AD_INT_DEPENDENCIES`. If Interface B is configured to depend on Interface A, B's messages
are **held** (not discarded) — they remain QUEUED and are not promoted for dispatch while Interface A
has messages in-flight or failed for the same `BUSINESS_IDENTIFIER1`. Once A reaches a terminal status,
B becomes eligible on the next dispatcher cycle. If no dependency is configured, A and B are processed
independently.
