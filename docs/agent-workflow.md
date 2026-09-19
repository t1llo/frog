# Same-session continuation

OpenCode automatically compacts context around **170K tokens** and resumes work in the **same session**, as configured in this working environment. Treat this as context management, not a task boundary or a universal model limit.

Continue through the agreed scope automatically across work chunks, tickets, phases, and compaction. Elapsed time and context size are not stopping criteria. Do not generate routine copy-paste continuation prompts, require a new session, clear context between tickets, or ask “shall I continue?” to proceed with already agreed work.

Stop only when the agreed work is complete, the user asks to stop, or a genuine blocker or required decision needs user input. Preserve explicit approval gates, permissions, dependencies, and scope limits. Continue independent authorized work while a decision is pending where possible. Automatic compaction never expands scope: drafting tickets does not authorize their publication or implementation.

## Durable progress

Maintain one concise, current progress note for the active effort; this project's note is [progress.md](progress.md). Update it after meaningful completion, decisions, verification, or blockers. Replace stale next steps instead of appending a session transcript.

Record only:

- **Objective:** agreed scope and completion criterion.
- **Completed:** significant finished work, with artifact pointers.
- **Decisions:** constraints, approvals and unresolved decisions that affect execution.
- **Verification:** commands/results, including failures and unverified behavior.
- **Next steps:** ordered actions and any genuine blocker requiring input.

After compaction, consult the progress note and linked authoritative artifacts, inspect relevant working-tree state, and resume the next authorized action without asking the user to reconstruct context. Recheck evidence when changes or uncertainty warrant it; avoid replaying completed work or repeating successful checks solely because compaction occurred.

## Explicit handoffs

Keep historical handoffs as useful records. Create a new handoff only for an explicitly requested transfer to another agent, person, or harness. Directory changes and automatic compaction do not inherently require one. Link existing requirements, issues and decisions rather than duplicating them; redact secrets. A handoff is a portability tool, not routine continuation management.
