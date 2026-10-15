---
name: flashco-workflow
description: Use when starting or resuming a Flashco repository task involving implementation, debugging, planning, or code review, or when explicitly asked to coordinate the agent through Superpowers.
---

# Flashco Workflow

Coordinate the current task through the installed `superpowers` skills and the repository's domain skills.
This is a routing entry point, not a background controller or permission grant.

## Start and resolve dependencies

1. Apply the current user instructions and [AGENTS.md](../../../AGENTS.md) intake first: stop requests,
   hard process triggers, then any required clarification. Reuse an answered clarification and an approved plan.
2. After intake, use `project-context-bootstrap` when available. Read the required project context and Git state;
   reuse current evidence already collected in this task. State the intended result, write scope, and completion check.
3. **Required entry skill:** read `superpowers:using-superpowers` from its location in the current skill catalog.
   Resolve every selected skill by its current catalog entry; read its instructions before following them.
   Do not pin plugin versions or copy skill bodies into this repository.
4. If a selected skill is absent, look for its installed source using the available skill discovery mechanism.
   If it is unavailable and essential, report the dependency as a blocker. Otherwise use the repository workflow
   and disclose the fallback. Do not install, recreate, or silently claim to have used a missing skill.

User authority and repository rules govern how generic Superpowers procedures apply. Use the tools actually exposed
by the current runtime; a skill's example tool name or configuration snippet is not an instruction to alter the host.

## Select the route

Load only the skills needed for the current stage; this table is not a checklist to execute in full.

| Current task | Route |
| --- | --- |
| Fully specified, low-risk edit | Relevant repo skill, direct scoped edit, focused verification. The repo's small-change rule takes precedence over mandatory brainstorming or plan creation. |
| Substantial feature with unresolved behavior | `superpowers:brainstorming`, then `superpowers:writing-plans`; follow the project's plan review before implementation. |
| Approved implementation plan | `superpowers:executing-plans` for inline work; use `superpowers:subagent-driven-development` when independent tasks, available tools, and applicable delegation rules permit it. Do not restart design. |
| Bug or failing test | `superpowers:systematic-debugging`; when a fix is authorized, use `superpowers:test-driven-development` subject to repo test-placement rules. Diagnosis-only stays read-only. |
| Review feedback | `superpowers:receiving-code-review`; verify each claim and make changes only within the authorized fix scope. |
| Implementation review | `superpowers:requesting-code-review`; preserve any configured external review gates. A review-only task produces findings without fixes. |
| Completion claim | `superpowers:verification-before-completion`, then `self-review-report` when available. Match evidence to the requested result. |

Add domain skills as needed: [ui-work](../ui-work/SKILL.md) for Flutter UI,
[localization](../localization/SKILL.md) for UI strings,
[core-platform](../core-platform/SKILL.md) for Core/service/platform behavior, and
[pre-commit-quality-review](../pre-commit-quality-review/SKILL.md) when a commit is requested.
Follow [commands](../../commands.md) and [rules](../../rules.md) for application checks and code generation.

## Keep execution within authority

- Work in the current checkout. `using-git-worktrees` or an execution helper does not authorize a worktree,
  repository copy, alias, or symlink. If a selected helper requires a forbidden workspace, use an allowed inline
  execution path; if none exists, report that blocker.
- Delegation must preserve the parent's scope and restrictions. Give each subagent a bounded task, allowed files,
  and verification requirement; keep overlapping writes sequential and verify returned work before accepting it.
- Plan steps and `finishing-a-development-branch` do not authorize commits, push, PR creation, merge, deploy,
  cleanup, or skill modifications. Apply the current user and project permission gates to each action.
- A completed-merge message follows the project's `development-handoff` trigger, not this table's normal completion route.
- Report the actual result, checks and limitations. Unavailable required checks remain blockers; do not turn
  partial evidence into a claim that the application works.

Example: an approved one-label change selects `localization`, updates ARB sources, regenerates locales, and runs
the required checks. It does not start a feature design cycle or create a worktree.
