# Board sync requirements

Target: <https://github.com/orgs/gfx-rs/projects/7> ("WebGPU for Firefox").

## Board conventions

- PRs don't go on the board directly; only issues and draft items for Bugzilla bugs.
- Security bugs may show nothing beyond the bug number (draft title `Bug <N>`). Public bugs use
  `Bug <N> - <summary>`.
- Match bugs by number, never by title: titles change, and sec bugs have none on the board.
- Meta bugs (`meta` keyword) stay off the board. Larger-than-one-task efforts are tracked as GitHub
  issues instead (with sub-issues). Possible exception: platform-release metas (e.g., Linux,
  Android).
- App-specific reports are case-by-case: some share a root cause tracked elsewhere (keep off),
  others are their own root cause. Blocking the `webgpu-apps` meta (bug 1849916) doesn't settle it.
  When the team focuses on app-specific problems, those items go in `Current`.
- A GitHub issue *represents* a Firefox bug only if its description says so explicitly:
  `Firefox downstream tracking: [bug N](…)` (or `Firefox tracking:`), or `re-filed from … bug N`.
  Any other mention (e.g., citing an app report as where a root cause was found) makes the bug
  `referenced`: it's not considered on the board, isn't added automatically, and status doesn't
  propagate between them.
- Query Bugzilla anonymously (with a `User-Agent`), so restricted bugs can't leak a summary.

## Step 1: presence (implemented in `board-sync.nu`)

Missing items are appended with `Status: Todo` and no `Priority`. The `Bugzilla item(s)` field is
unused and not maintained (the title already carries the bug number), but it's still read when
matching, since some existing items have it.

## Step 2: out-of-sync detection (when both sides exist)

Each finding has:

- **Level:** `error` (definitely wrong), `warning` (possibly wrong), or `info` (not a conflict, but
  needs attention, e.g., untriaged).
- **Resolution:** a `fix` the tool can apply, or a `decision` for a human. A decision comes with a
  suggested course of action, backed by a timeline of events as evidence. Destructive fixes (e.g.,
  removing an item from the board) are still fixes, but require confirmation before being applied.

**Bugzilla is the source of truth for Bugzilla bugs.** GitHub Projects has no field-change
history, so only the Bugzilla side has a timeline, and its state and events drive changes on the
board with confidence. Human decisions should be rare.

### Review before acting: plan, then apply

A user must be able to review changes before they're made on their behalf.

```
fx-triage sync          # default: plan → review interactively → apply
  ├─ fixes:     [a]ccept / [s]kip / accept [A]ll of this kind
  └─ decisions: choose an outcome / skip
fx-triage plan > file   # file-based flow, for careful or batch review
fx-triage apply file
```

The plan is derived from current state, so anything not applied simply reappears in the next
`plan`, with fresh evidence and `FROM` values. There's no need to save "remaining" changes. In the
file flow, users can mass-delete anything they're unsure of and re-plan later.

Deferred until there's usage experience: whether to remember skipped/deferred decisions, so
re-plans don't keep re-proposing them.

Gated changes include at least: removing board items, and any Bugzilla write (it sends bugmail and
is permanent history).

What's gated is a user parameter; **by default, everything is**. Once users trust the tool, they can
opt categories out of review themselves (e.g., safe board-only fixes).

#### Plan file format

Line-based, in the style of `git rebase --interactive`'s todo file:

```
# ── Bug 2074667 - Vulkan zero-readback presentation should issue a queue family ownership transfer
bmo 2074667
  priority P3 P1
  # board: "Current" → P1
project PVTI_lADOAH1Sts4AZes7zg8NvS4
  status Todo "In Progress"
  # bug: patch D123456 posted 2026-10-02

# DECISION: bug 1953233 resolved WONTFIX 2026-10-01. Uncomment one:
# project PVTI_… status "In Progress" Done
# project PVTI_… remove
```

- `<service> <ref>`, then indented `<property> FROM TO` lines. Values with spaces are quoted.
- `FROM` is a per-field compare-and-swap (like `git push --force-with-lease`): `apply` refuses a
  change if the field no longer holds `FROM`, so concurrent edits to *other* fields don't block it.
  Whole-entity leases (`last_change_time`, `updatedAt`) are too coarse, since any comment bumps them.
  There's still a short check-then-write race; neither API seems to offer conditional updates
  (unverified for BMO REST).
- `#` comments carry evidence/timelines and are ignored by `apply`.
- Each pair is one block with a `# ──` header comment. The grouping is stylistic only, so every
  change line stays self-contained and safe to delete or reorder.
- Decisions are commented-out alternatives; uncomment one to choose it.
- **Header titles come from the board by default**, since board titles have already passed the
  sec rule. `--emit-sec-bug-titles` opts into Bugzilla summaries (including sec bugs) in comments,
  for users who treat plan files as private. If any such title is emitted, the file starts with a
  loud warning:

  ```
  # ⚠️  WARNING: this plan contains summaries of restricted (security) bugs.
  # ⚠️  Do not share it. Generated with --emit-sec-bug-titles.
  ```

### Status

| # | Bugzilla | Board | Level | Resolution |
| --- | --- | --- | --- | --- |
| 0 | anything | `Status` empty | error | fix: set `Todo` |
| 1a | `RESOLVED FIXED` (or other terminal + `FIXED`) | item exists, not `Done` | error | fix: set `Done` |
| 1b | terminal, non-`FIXED` (`WONTFIX`, `INVALID`, `DUPLICATE`, `WORKSFORME`, `INCOMPLETE`, …) | item exists, not `Done` | error | decision: `Done` or delete |
| 2 | ≥1 non-abandoned patch (WIP counts) | `Todo` or empty | error | fix: set `In Progress` |
| 3 | open GitHub PR in `See also` | `Todo` or empty | warning | decision: suggest `In Progress` |

| 4 | open | GitHub issue item `Done` | ? | ? |

Rule 4 exception: leave it alone if the bug depends on `webgpu-update-wgpu` (bug 1851881, the
re-vendoring meta) or on a re-vendoring bug (i.e., one blocking 1851881, like "Update wgpu to
upstream (week of …)"). That's the legitimate "fixed upstream, not yet vendored" state.

Notes:

- `ASSIGNED` on its own is ambiguous, so it's never reported.
- Rule 2 "non-abandoned patch": Phabricator attachments (`text/x-phabricator-request`) not marked
  obsolete. (Unconfirmed: abandoned revisions → obsolete attachments.)
- Rule 3 is a warning because `See also` doesn't say why a PR is linked.
- Rule 1b evidence: e.g., a `DUPLICATE` whose target is already on the board suggests deleting.

### Title (draft items)

| Bugzilla (anonymous fetch) | Board draft title | Level | Resolution |
| --- | --- | --- | --- |
| public | not `Bug <N> - <current summary>` | error | fix: retitle |
| restricted | anything other than `Bug <N>` | error | fix: retitle to `Bug <N>` |

The restricted case covers bugs that became sec bugs after being added with a summary. Retitling
stops further exposure, but can't undo what was already public.

### Assignee

- Identity mapping (BMO email → GitHub login) is user-provided data, not checked in (e.g.,
  `~/.config/fx-triage/identities.nuon`, overridable by flag).
- Mapped assignee differs → fix: set the board assignee from Bugzilla.
- Unmapped assignee → decision. If both sides are assigned, a heuristic (BMO real name / `:nick`
  vs. GitHub login / display name) may suggest a mapping entry. It's never applied automatically.
- Bugzilla unassigned (`nobody@mozilla.org`) but the board has an assignee → decision (for now).
  Someone may have claimed it on the board without taking it in Bugzilla yet.

### Priority

**Exception: the board is the source of truth for priority.** Board priorities say what we mean and
are stack-ranked, while the mapping to Bugzilla is many-to-one (four queues all mean P1), so
corrections flow board → Bugzilla.

Several board priorities are "can do now" queues the team draws current work from: `Urgent/Critical`,
`Current`, `CTS burndown`, `Linux release`, and eventually `Android release`.

| Board priority | Accepted BMO priority | Suggested on conflict |
| --- | --- | --- |
| `Urgent/Critical`, `Current`, `CTS burndown`, `Linux release` | P1 | P1 |
| `Android release` | P1, P2 | P2 |
| `Incorrect existing` | P2 | P2 |
| `Missing core` | P3 | P3 |
| `Missing optional` | P4 | P4 |
| `Needs more triage`, `diagnostic`, `refactor`, `performance`, `Infrastructure` | P4, P5 | P4 |
| `out of scope` | none: Bugzilla bugs don't belong here | — |

`out of scope` holds things that *may* eventually become relevant, but certainly aren't right now.

The tool writes the Bugzilla priority, which needs an API key. Lookup order:

1. `BUGZILLA_API_KEY` env var (CI, one-off overrides).
2. python-bugzilla's `bugzillarc` (`~/.config/python-bugzilla/bugzillarc`, then `~/.bugzillarc`),
   `api_key` in the `[bugzilla.mozilla.org]` section. This is the de facto standard: mozilla-central's
   `mach manifest skip-fails` docs and in-tree tooling use it, as do several third-party tools.

Erich is migrating his key there from `~/.config/bugzilla.toml`, which no other tool reads. Authenticated requests must stay
separate from the anonymous reads used for draft titles, so the key never helps a sec bug's summary
reach the board.

Empty board priority (e.g., newly added items) is **not a conflict**, but still presents a decision:
triage it. Suggest a value when the BMO priority maps to exactly one board value (P2 →
`Incorrect existing`, P3 → `Missing core`); otherwise, no suggestion.

A Bugzilla bug in `out of scope` → error; fix: remove it from the board, **with confirmation**.
Irrelevant bugs simply don't belong on the board, so the only question is whether the tool may
do it, not whether the item stays.


## Where we left off (2026-10-06)

- Sweep of open Core › Graphics: WebGPU bugs: 147 present, 5 referenced, 245 missing.
  - All 30 missing meta bugs: excluded.
  - Next: the 86 missing bugs blocking 1886808 ("needing priority revision"), batched by BMO
    priority (P1 first), discussed case by case. App-specific reports blocking 1849916 are also
    case by case.
- Bug 2075089 is only `referenced` (via wgpu#10446): add a draft, or a tracking line on the issue?
- Rule 4 still needs a level/resolution (suggested: warning + decision).
- The write path (`item-add`/`item-create` + `Status: Todo`) is still untested live.

## Later iterations

- Lint on out-of-order bug severities.
- Traverse PRs to find the issues/bugs they're linked to.
- Richer discovery of linked items.
- Discover input from Bugzilla queries, e.g., all open bugs in Core › Graphics: WebGPU. (On
  2026-10-06, 245 of 397 such bugs weren't on the board.)
- Use bug properties (rather than anonymous access) to detect sec bugs.
- Fetch board items with a lean GraphQL query; full `gh project item-list` pulls appear to trip
  rate limits.
