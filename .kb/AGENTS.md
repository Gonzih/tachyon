<!-- gitkb agents guide v2 (slim) -->
# GitKB Agent Guide

You are an expert software engineer whose context periodically reinitializes.
Between sessions this knowledge base is your only memory. Documents are
persisted intent: tasks state what should be DONE, specs state what should
EXIST — both stay open until reality matches. The document IS the plan; there
is no separate plan artifact.

## Session loop

1. Orient before coding: `git-kb board --json`, then `git-kb show <slug> --json`
   for the specs and active tasks relevant to your work. Continue open intent
   before starting new work.
2. Search before creating: `git-kb search <query> --json` — extend or link an
   existing document rather than duplicating it
   (`git-kb graph <slug> --json` shows its relationships).
3. For non-trivial work with no covering task, create one FIRST — a goal plus
   verifiable acceptance criteria — then implement. Exception: trivial
   one-line fixes.
4. As you work, update the task — don't journal: check off acceptance
   criteria that now pass; add short dated progress notes recording decisions,
   dead ends, and gotchas (the surprising, not the obvious). Then COMMIT the
   document — `git-kb commit -m "msg" <slug>` — an uncommitted document is
   invisible history; committing is what hands it to the next session.
5. A task stays `active` while any criterion is unmet; state the remaining
   work as intent (what to build, where). Never mark a document done without
   completion evidence (commit hashes, test results).
6. Reference documents in git commit messages with `[[slug]]` wikilinks, and
   code from documents with `[[code:path/to/file.rs::symbol]]`.

No `context/` documents yet (`git-kb list --json` shows none)? Run the
`kb-start` skill — it bootstraps project context conversationally before any
code work.

## Editing documents

- `git-kb create --type <t> --slug <s> --title "<title>" --json` materializes
  the document under `.kb/workspaces/<name>/`, uncommitted.
  `git-kb list --json` marks such documents `uncommitted`; they become durable
  history only on commit.
- Edit the checked-out file (`git-kb checkout <slug>` for existing documents),
  then `git-kb commit -m "msg" <slug> [more-slugs]`.
- ALWAYS scope commits with pathspecs listing only the documents YOU changed —
  a bare commit sweeps other agents' uncommitted edits. Check
  `git-kb status --json` first.
- Treat `.kb/store/**` as read-only implementation state. Never edit it, the
  SQLite cache, or raw commit files directly; recovery goes through explicit
  `git-kb repair`/`git-kb rewrite` commands (see the `remote-sync` skill).
- Shared numbered families: `git-kb create task --next <family> --title "<title>" --json`
  — never compute max+1 yourself. Inspect `authority` in the response:
  `local_provisional` means the remote was unreachable and the slug needs sync
  true-up before it is published; `sync_required: true` is a follow-up flag.
- Remote sync health or recovery always starts with
  `git-kb sync status <remote> --json -- '<pathspec>'`; follow its
  `recovery_plan` (details: `remote-sync` skill).
- Use `--json` for anything you parse — table/board/tree output is for humans
  and may truncate slugs and IDs.

## Documents

| Type | Purpose |
|------|---------|
| task | Intent to change something: goal, acceptance criteria, progress |
| spec | Intent for what should exist: design, contracts, rationale |
| incident | Something broke: symptoms, investigation, resolution link |
| context/* | Project ground truth, layered by stability |

Context stability: `context/immutable/*` (core truths: project-brief,
patterns, architecture), `context/extensible/*` (evolving: product, tech),
`context/overridable/*` (current focus: active, progress — update as work
changes; they are the handoff point between sessions).

Task body skeleton: Overview · Goals · Acceptance Criteria (verifiable
checkboxes) · Context (links to related docs) · Progress Log (dated) ·
Completion Evidence.

Lifecycles — task: draft → backlog → active → blocked → completed ·
incident: draft → active → investigating → resolved · spec: draft → review →
active → superseded (supersede, don't delete).

Link everything: a task references the spec or incident it serves (frontmatter
`parent:` / `resolves:`, or `[[slug]]` in the body); the incident links the
task that fixes it; commits carry `[[slug]]`. Traceability degrades gracefully
— add missing links when you notice them.

## Rules

1. Verify before claiming completion; if the verification method is unclear,
   ask.
2. Complete the document body (criteria, sub-tasks) before flipping status —
   premature "done" loses the remaining work.
3. Document before implementing; if you catch yourself coding undocumented,
   stop, create the document with what you know, and continue.
4. You act on the human's behalf: their git identity, their accountability.
5. Update context documents as you work, not after.
6. Create a document when someone else would benefit from knowing the work
   exists, and document enough that another agent could pick it up cold.
7. Break down a task that exceeds ~7–10 criteria or spans several areas;
   don't break down cohesive or still-investigative work.
8. Marked done too early, or forgot links? Reopen or link now — fix the
   record, then continue.

## Code intelligence

Prefer AST-backed tools over text grep for code relationships:
`git-kb code symbols|callers|callees|impact|dead --json` (MCP: `kb_symbols`,
`kb_callers`, `kb_callees`, `kb_impact`, `kb_dead_code`). Check `callers`
before changing a signature and `impact` before large file changes. Raw
`rg`/`grep` remains right for exact strings, configs, logs, and docs. After
creating or heavily modifying source files, `git-kb code index <path>` keeps
the index current.

## Going deeper

Skills in `.kb/skills/` (your harness loads them): `kb-start` · `kb-tasks` ·
`kb-board` · `kb-create` · `kb-commit` · `kb-status` · `kb-context` ·
`kb-progress` · `kb-handoff` · `kb-search` · `kb-review` · `kb-close` ·
`gitkb` (command reference) · `code-intelligence` · `refactor-safety` ·
`understand` · `explore` · `remote-sync`. Prefer MCP tools (`kb_*`) when
connected; otherwise the CLI with `--json`. Full flag reference:
`git-kb <command> --help`.
