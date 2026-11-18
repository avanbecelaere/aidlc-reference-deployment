# Running AI-DLC v1 reliably

AI-DLC v1 rules version 1.0.1, from the `v1` branch of
[awslabs/aidlc-workflows](https://github.com/awslabs/aidlc-workflows/tree/v1).

This document exists because AI-DLC v1 can appear to be running when it is not,
and can appear to respect its approval gates when it does not. Both failures are
quiet, and both have been observed in practice. Everything below is a check you
perform, not a thing you assume.

---

## What v1 actually is

v1 is **a set of markdown rules injected into a coding agent's context**. It is
not a plugin, extension, tool, or state machine. Nothing in it can prevent a file
write.

That single fact explains both failure modes. The workflow runs only while its
rule text is present in context and the model elects to follow it, and its
approval gates are instructions in prose, not enforcement.

## Installed layout

```text
<project-root>/
├── CLAUDE.md                   # core-workflow.md, the rule itself
└── .aidlc-rule-details/        # 31 stage detail files
    ├── common/
    ├── inception/
    ├── construction/
    ├── extensions/
    └── operations/
```

Claude Code reads `CLAUDE.md` as project memory. Note this layout is specific to
Claude Code: Kiro uses `.kiro/steering/`, Cursor uses `.cursor/rules/`, and
installing for the wrong harness silently produces a project where the workflow
never loads.

`CLAUDE.md` is 539 lines. The repository's own troubleshooting guidance
warns that rules beyond about 500 lines should be split into focused rules,
because gate instructions buried deep in a long rule compete poorly against a
short, concrete, recently-written artifact. Keep that in mind when a gate is
missed: it is a known weakness, not a surprise.

## Before you start: the competing-workflow trap

**This is the most likely reason a run fails, and it is not obvious.**

Every modern coding tool ships its own planning workflow whose shape is nearly
identical to AI-DLC's Inception phase: ask clarifying questions, research the
codebase, produce a reviewable plan, then build it. When that native workflow is
active, the model can fully satisfy its contract and never reach for AI-DLC's,
while still sounding to you as though it is following a structured process.

The first line of `core-workflow.md` is:

```text
# PRIORITY: This workflow OVERRIDES all other built-in workflows
```

That line exists precisely because the rule has to defeat the host tool's native
behaviour. It does not always win.

| Tool | Use this mode | Not this mode |
|---|---|---|
| Claude Code | normal mode, permission prompts on | plan mode, or auto-accept edits |
| Kiro IDE | Vibe mode | Spec mode |
| Cursor | Agent mode | Plan Mode |

In Claude Code the mode is cycled from the keyboard, which makes it easy to change
by accident and easy to be in the wrong one without noticing. Check it before you
start and again after any interruption. Plan mode is the competing workflow.
Auto-accept edits is worse for this particular demonstration: it takes the human
out of file writes altogether, which is exactly the claim being made to the
audience.

Kiro will sometimes prompt you to switch to spec mode mid-run. Decline it. If you
accept, you have handed the run to a competing workflow.

A further hazard: if the native workflow already produced a plan artifact, that
artifact stays in context as an ordered, checkbox-shaped implementation list.
Tools typically execute an approved plan in one pass without further prompts. You
then have two state machines in context, one saying stop at the next gate and one
saying work the list to completion. The concrete checklist tends to win. Delete
such artifacts before starting, including any copy the tool saved outside the
project directory.

## Clean-start check

Run these and read the output. A resumed or misclassified run produces confusing
failures later that look unrelated to their cause.

```bash
git status --porcelain      # any ?? lines are untracked leftovers
ls -la aidlc-docs/          # must NOT exist for a clean start
```

Two specific traps:

- **A surviving `aidlc-state.md` causes resume, not restart.** Workspace Detection
  checks for the state file and resumes when it finds one. Stale checkboxes make
  the next run pick up at the wrong stage, which looks exactly like a skipped
  gate but has a completely different cause.
- **Surviving generated code flips greenfield to brownfield.** Leftover files make
  the agent classify the project as brownfield and run Reverse Engineering against
  code it may have written minutes earlier, then treat that analysis as
  authoritative for everything downstream.

Untracked files are the usual culprit, and neither a conversational revert nor
`git checkout` removes them.

## Activation check

Start Claude Code from the project root in a **new session**, so the rule is read
at startup:

```bash
cd <project-root>
claude
```

Rule changes never reach a session already in flight, so if you edited `CLAUDE.md`
or moved the rule details, the running session will not pick them up. Quit and
start again.

After the first prompt, confirm all three. **The agent's own report that it is
following AI-DLC is not evidence of anything.**

1. The welcome banner appeared, beginning "Welcome to AI-DLC".
2. `aidlc-docs/aidlc-state.md` and `aidlc-docs/audit.md` now exist. Workspace
   Detection creates them, so their absence proves the workflow never activated.
3. In Claude Code, `/config` shows the configuration, and asking "What
   instructions are currently active in this project?" names `CLAUDE.md`. In Kiro,
   the steering files panel lists `core-workflow` under Workspace.

If any of the three is missing, stop. Do not continue and hope. Fix the
installation, open a brand new chat, and start again: rule changes do not reach a
session already in flight.

## The permission layer, and why it helps here

v1's approval gates are prose with nothing behind them. Claude Code, run in normal
mode, adds something v1 does not have: **every file write and every command needs
a human decision before it happens.**

This matters because of how the gates failed in a previous workshop. The analysis
of that failure noted that the host tool's plan mode "has all tools enabled, so
there is no mechanical boundary between planning and doing". In Claude Code's
normal mode there is such a boundary, on every single write.

So the permission prompts are not an annoyance to click through during this run.
They are the only real enforcement present, and they are visible to the audience,
which makes them the most honest demonstration of human-in-the-loop available.
Two consequences:

- Do not enable auto-accept edits, for any part of the run, however tedious.
- When a permission prompt appears for a stage you have not approved yet, that is
  the gate working mechanically where the prose gate did not. Decline it and say
  so out loud; it is a better moment for the audience than a clean run.

## Stage sequence

Inception, in order, with conditional stages skipped for simple work:

1. Workspace Detection (always)
2. Reverse Engineering (brownfield only)
3. Requirements Analysis (always)
4. User Stories (conditional)
5. Workflow Planning (always). Declares and gets approval for the stage sequence
6. Application Design (conditional)
7. Units Generation (conditional)

Construction, then looping per unit: Functional Design, NFR Requirements, NFR
Design, Infrastructure Design, Code Generation, then Build and Test once across
all units. Operations is a placeholder in v1 and does nothing.

Knowing this sequence is what lets you notice a skipped stage. Workflow Planning
matters most: it is where the stage list itself is agreed, so if it did not run,
there is no agreed sequence to hold the run to.

## Gate discipline during the run

Each gate is text of this shape:

```text
Wait for Explicit Approval: ... DO NOT PROCEED until user confirms
```

There is no hook, no tool permission, and no code behind it. So watch for the
agent producing a stage artifact and then continuing into the next stage in the
same turn without pausing. The observed failure was Requirements Analysis
completing and Code Generation beginning with no approval requested.

Check `aidlc-docs/audit.md` as you go. It should record each stage and its
approval. An audit trail that skips from one stage to a later one is the record
of a gate that did not hold.

## If a gate is missed

Do **not** ask the agent to revert to an earlier point. That is reconstruction,
not restoration: the agent holds no file-state snapshot, so it infers what to
undo from whatever remains in context and deletes or rewrites accordingly. Any
built-in checkpoint restore the tool offers only covers files the agent edited
with its own edit tools, leaving anything written through a terminal command in
place.

Establish the real state with version control instead:

```bash
git status --porcelain
git stash list
ls -la aidlc-docs/
```

Prefer a clean slate to surgical unwinding. A fresh clone into a new directory, or
`git clean -fdx` where there is a clean committed baseline and you accept that it
permanently deletes all untracked work. Reconstructed state produces a second
confusing failure later, and by then you cannot tell whether the cause was the
revert or the rules.

This is why this project keeps a committed baseline from the start. It makes a
clean restart a single command instead of a judgement call under time pressure.

## Where artifacts land

```text
aidlc-docs/
├── inception/      plans, requirements, user-stories, application-design
├── construction/   plans, {unit-name}/{functional-design,nfr-*,infrastructure-design,code}
├── operations/     placeholder
├── aidlc-state.md  the stage pointer
└── audit.md        the approval record
```

Application code goes in the workspace root, not under `aidlc-docs/`. Files under
`aidlc-docs/construction/{unit}/code/` are markdown summaries only, not the code
itself.
