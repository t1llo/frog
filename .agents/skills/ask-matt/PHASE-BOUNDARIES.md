# Phase boundaries

A **phase** is a chunk of work with a completion criterion, such as resolving design questions, implementing behavior, or verifying a change. Phase completion is a progress checkpoint, not a session limit.

Follow the project's [same-session continuation workflow](../../../docs/agent-workflow.md), which defines automatic compaction, durable notes, stopping conditions, and explicit handoffs.

## Advancing the work

1. Check the phase's completion criterion and record significant results in the current progress note, linking primary evidence.
2. Identify the next action within the agreed scope and any genuine dependencies or approval gates.
3. Continue that action automatically when authorized. If a required decision blocks it, request the specific input and continue independent authorized work where possible.
4. After automatic compaction, recover from the note and authoritative artifacts and continue in the same session, even if compaction occurred mid-phase.

Tickets organize dependencies and verification; they do not impose one-ticket-per-session execution. Delegate only when the user or applicable instructions authorize delegation, not merely to avoid compaction.

## Keeping evidence useful

Progress summaries aid navigation; source files, verification output, specs, decisions, and issue records remain the evidence. Link these rather than copying transcripts. Consult the originals when a summary leaves a consequential ambiguity. Retain useful historical handoffs and make current decisions discoverable without rewriting history.
