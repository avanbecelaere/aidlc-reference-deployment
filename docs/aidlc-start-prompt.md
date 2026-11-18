# Starting prompt for the AI-DLC run

Launch from the repository root in a new session, in normal mode. Not plan mode,
not auto-accept edits.

```bash
cd <repo-root>
claude
```

Paste the prompt below as the first message. It opens with the exact phrase the
AI-DLC project documents as the activation trigger: "Using AI-DLC, ...". That
wording is not decoration. The rules also claim to activate on any software
development request, but the documented phrase is the reliable path, and
activation failing silently is the worst failure this workflow has.

---

## The prompt

> Using AI-DLC, build the system described in `docs/vision.md` in this
> repository. Read that document first. It is the requirements input and it is
> deliberately narrow.
>
> This is a greenfield project. The repository currently contains only
> documentation, the AI-DLC rules, a `.gitignore`, a licence, and one GitHub
> Actions workflow that verifies AWS credentials. There is no application or
> infrastructure code, so there is nothing to reverse engineer.
>
> Four constraints that are not in the vision document:
>
> 1. The Terraform state bucket, the GitHub OIDC identity provider, and the
>    deployment IAM role **already exist**. They were created by hand, outside
>    Terraform, and are documented in `docs/prerequisites.md`. Do not write
>    Terraform for any of them.
> 2. This repository is public and the state bucket name contains the AWS account
>    id. Use **partial backend configuration**: the `backend "s3"` block in code
>    must be empty of account-specific values, supplied at init time through a
>    `backend.hcl` file which is gitignored. No account id, bucket name or role
>    ARN may appear in any tracked file.
> 3. The GitHub Actions workflow reads the role ARN and region from the existing
>    repository variables `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION`. It needs
>    `permissions: id-token: write` and `contents: read`. Pin any third-party
>    action to a commit SHA, not a tag.
> 4. The whole thing has to be finished today, so stay inside the vision
>    document's scope. If you believe something it excludes is genuinely
>    required, say so and stop rather than adding it.
>
> Stop at every stage gate and wait for my explicit approval before starting the
> next stage. Do not run two stages in one turn.
>
> Before you do any work, tell me three things: that you have created
> `aidlc-docs/aidlc-state.md`, which stages you intend to run and which you intend
> to skip, and anything in the vision document you find ambiguous.

---

## What to check in its first reply

| Check | Why |
|---|---|
| The welcome banner appeared | Absent means the rules never loaded |
| `aidlc-docs/aidlc-state.md` and `audit.md` now exist | Workspace Detection creates them; their absence proves the workflow is not running, whatever the agent says |
| It classified the project greenfield | Brownfield triggers Reverse Engineering against documentation and wastes a stage |
| It named a stage sequence | That is Workflow Planning. No sequence means no agreed boundary to stop at |

If any of the first two are missing, stop, quit the session, and start again.
Rule changes never reach a session already running.

## Decisions it will ask you for

The rules scan `extensions/` at startup and offer opt-ins for a security
baseline, a resiliency baseline, and property-based testing. Each adds stages and
artifacts. For a single-day scope, declining all three is the defensible choice,
and you can speak to what they would add rather than running them.

Decide before it asks, so the answer is a choice rather than a reflex.

## If it does not activate

The upstream project's own verification for Claude Code is to ask it directly:

```
What instructions are currently active in this project?
```

It should name `CLAUDE.md`. `/config` shows the current configuration. If
`CLAUDE.md` is not listed, the rules are not loaded and nothing downstream will
behave as documented, whatever the agent says about following a workflow.
