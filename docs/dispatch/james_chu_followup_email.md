# Follow-up Email to James Chu — Points 1 & 3

**To:** James Chu (Enterprise Architect)  
**Subject:** Re: Parking Lot Dispatcher — OIC to ATP  
**Date:** 2026-11-10

---

Hi James,

Happy to continue on points 1 and 3.

## Point 1 — Error visibility and notification to the source system

All errors are already captured in `AD_MSG_AUDIT` (`STATUS = 'ERROR'`, `ERROR_MESSAGE` column) and in the `AD_ATP_ERRORS` log table, which is written by the dispatcher's autonomous error logger. This gives us a durable, queryable foundation.

On top of that we have a few directions we can take for visibility:

- The OIC processor integration can notify relevant teams directly — Fusion, OIC operations, or the source system — as part of its error handling logic. This is already the natural place for it in the three-phase design.
- For broader team visibility, we can build a lightweight layer on top of `AD_MSG_AUDIT` / `AD_ATP_ERRORS` — an APEX application, a Google Sheets feed, or a dashboard — to surface errors to the right people without requiring direct database access. This is something we can evolve over time as we understand the team's monitoring needs.

The data is there. The notification channel is a design choice we can make incrementally.

## Point 3 — Dependency behaviour when Interface A is in error

As explained, today's behaviour is: `ERROR` is treated as terminal, so Interface B is **not** blocked when Interface A's message has failed. The rationale is that the dispatcher should not hold B indefinitely just because A failed — that would require manual intervention to unblock.

This is intentional, and there is a broader architectural precedent for it. In a recent integration with the Magma target system, we had a similar dependency check at the middleware layer — Interface B was blocked waiting for a dependent object from Interface A. We found this created fragility at the middleware level. The decision was made to remove the dependency check from the middleware and push the responsibility to the target system, which implemented its own retry logic. The result is a more resilient pipeline: the middleware delivers messages regardless, and the target system handles sequencing and retries on its side.

That said, I recognise that for some use cases, blocking on `ERROR` may be the right behaviour. This could be made configurable — a flag on `AD_INT_DEPENDENCIES` (e.g. `BLOCK_ON_ERROR = Y/N`) — so each dependency rule can declare whether an errored prerequisite should hold the dependent interface or not. This would be a future enhancement rather than a change to the current design.

Happy to discuss further.

Regards,  
Tiago
