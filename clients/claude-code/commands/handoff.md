---
description: Write NOTES.md so the work can continue in a fresh session (then run /clear)
argument-hint: "[optional focus for the next session]"
---

The context of this session is getting long, which makes a local model slower. Write a handoff so a fresh session can continue without the conversation history.

Create or update `NOTES.md` in the project root (keep anything still valid from an existing one) with these sections:

1. **Goal** — what we are building or fixing, in one or two sentences.
2. **Current state** — what is done and verified, what is half-done.
3. **Decisions** — choices made and why, including approaches that were tried and rejected.
4. **Files** — the files that matter for the next step, with a one-line note each.
5. **Next steps** — a short numbered list, most important first.
6. **How to verify** — the exact commands to build, test or run.
7. **Open questions** — anything that needs the user.

Rules:
- Stay under 800 words. Point to files and line ranges instead of pasting code.
- Only write facts from this session; mark anything unverified as such.
- Never include secrets, API keys or tokens.
- Extra focus for the next session: $ARGUMENTS

When done, reply with one line: `NOTES.md updated — run /clear, then: Read NOTES.md and continue with the next step.`
