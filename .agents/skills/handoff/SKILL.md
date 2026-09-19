---
name: handoff
description: Write a portable handoff when the user requests a transfer to another agent, person, or harness.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

For an explicitly requested transfer, write a handoff document summarising the current objective, completed work, important decisions, verification results, and next steps. Save to the temporary directory of the user's OS - not the current workspace. Follow the project's [continuation workflow](../../../docs/agent-workflow.md) for ordinary work and automatic compaction; preserve useful historical handoffs.

Include a "suggested skills" section in the document, naming which skills the next agent should call the Skill tool for.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
