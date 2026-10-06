#!/usr/bin/env nu

# Ensure Bugzilla bugs and GitHub issues are represented on a GitHub Projects (v2) board.
#
# Items already on the board are left untouched. Missing items are appended to the bottom with
# `Status` set to `Todo` and no `Priority`.
#
# References may be:
#
# - Bugzilla: `1953233`, `https://bugzilla.mozilla.org/show_bug.cgi?id=1953233`, `https://bugzil.la/1953233`
# - GitHub issues: `https://github.com/gfx-rs/wgpu/issues/10435`
#
# PRs are reported as `skipped`; they are not added to the board. Bugs only mentioned in an issue
# body (outside a "Firefox downstream tracking:" or "re-filed from" line) are reported as
# `referenced`, and also not added.
def main [
  ...refs: string # Bug or issue references.
  --file: path # Read references from a file, one per line. Blank lines and `#` comments are ignored.
  --owner: string = "gfx-rs"
  --project: int = 7
  --dry-run # Report what would be added, without changing the board.
  --items-from: path # Use a saved `gh project item-list --format json` snapshot instead of fetching. Implies `--dry-run`.
]: nothing -> table {
  let dry_run = $dry_run or $items_from != null
  let file_refs = if $file == null {
    []
  } else {
    open --raw $file | lines | each { str replace --regex '#.*$' '' | str trim } | where $it != ''
  }
  let parsed = $refs | append $file_refs | each { parse-ref }

  let items = if $items_from == null { board-items $owner $project } else { open $items_from }
  let results = $parsed | each {|ref|
    match $ref.kind {
      bug => { $ref | merge (find-bug $items $ref.bug) }
      issue => { $ref | merge (find-issue $items $ref.url) }
      _ => $ref
    }
  }

  let fields = if $dry_run or ($results | all { $in.state != missing }) {
    null
  } else {
    board-fields $owner $project
  }

  $results | each {|r|
    if $r.state != missing {
      $r
    } else if $dry_run {
      $r | update state would-add
    } else {
      $r | merge (add-item $owner $project $fields $r)
    }
  } | select ref kind state matched_by title item
}

const USER_AGENT = "fx-triage-board-sync/0.1 (+https://github.com/orgs/gfx-rs/projects/7)"

def parse-ref []: string -> record {
  let ref = $in
  let base = {ref: $ref, kind: null, state: null, matched_by: null, title: null, item: null}

  let bug = $ref | parse --regex '^(?:(?:https?://)?(?:bugzilla\.mozilla\.org/show_bug\.cgi\?id=|bugzil\.la/))?(?<id>\d+)\b'
  if ($bug | is-not-empty) {
    return ($base | merge {kind: bug, bug: ($bug.0.id | into int)})
  }

  let gh = $ref | parse --regex '^https://github\.com/(?<repo>[^/]+/[^/]+)/(?<type>issues|pull)/(?<number>\d+)'
  if ($gh | is-not-empty) {
    let gh = $gh.0
    let url = $"https://github.com/($gh.repo)/($gh.type)/($gh.number)"
    if $gh.type == pull {
      return ($base | merge {kind: pr, state: skipped, url: $url})
    }
    return ($base | merge {kind: issue, url: $url})
  }

  $base | merge {kind: unknown, state: error, title: "unrecognized reference"}
}

def board-items [owner: string, project: int]: nothing -> table {
  let total = gh project view $project --owner $owner --format json | from json | get items.totalCount
  # Over-ask, in case items get added between the two calls.
  gh project item-list $project --owner $owner --limit ($total + 100) --format json
  | from json
  | get items
}

def board-fields [owner: string, project: int]: nothing -> record {
  let project_id = gh project view $project --owner $owner --format json | from json | get id
  let fields = gh project field-list $project --owner $owner --format json | from json | get fields
  # Every item should have a Status, so refuse to add anything if we can't set one.
  let status = $fields | where name == Status | get --optional 0
  let todo = $status.options? | default [] | where name == Todo | get --optional 0.id
  if $todo == null {
    error make {msg: "board has no `Status` field with a `Todo` option"}
  }
  {
    project_id: $project_id
    status_field: $status.id
    status_todo: $todo
  }
}

# Lines in an issue body that explicitly make the issue stand in for a Firefox bug.
const TRACKING_LINE = '(?i)firefox (?:downstream )?tracking:|re-?filed from'

# Find a bug number in items' titles, `Bugzilla item(s)` fields, and bodies. Digits on either side
# disqualify a match, so `123` doesn't match `1234`.
#
# A body only *represents* the bug on a `TRACKING_LINE`. Any other body mention (e.g., an issue
# citing an app report as where a root cause was found) is merely a reference: the bug is
# `referenced`, not `present`, and isn't added.
def find-bug [items: table, bug: int]: nothing -> record {
  let pattern = ['(?:^|\D)' $bug '(?:\D|$)'] | str join
  let hits = $items | each {|item|
    let body_lines = $item.content.body? | default '' | lines | where $it =~ $pattern
    let where_found = [
      [name represents text];
      [title true $item.title]
      [bugzilla-field true ($item | get --optional "bugzilla item(s)" | default '')]
      [body-tracking true ($body_lines | where $it =~ $TRACKING_LINE | str join "\n")]
      [body-mention false ($body_lines | where $it !~ $TRACKING_LINE | str join "\n")]
    ] | where $it.text =~ $pattern
    if ($where_found | is-not-empty) {
      {item: $item, represents: ($where_found | any { $in.represents }), matched_by: ($where_found.name | str join '+')}
    }
  }
  let representing = $hits | where represents
  if ($representing | is-not-empty) {
    found-record $representing
  } else if ($hits | is-not-empty) {
    found-record $hits | update state referenced
  } else {
    {state: missing}
  }
}

def find-issue [items: table, url: string]: nothing -> record {
  let hits = $items | where {|i| $i.content.url? == $url } | each {|i| {item: $i, matched_by: url} }
  if ($hits | is-empty) { {state: missing} } else { found-record $hits }
}

# Multiple hits are all reported, since a bug mentioned in several items is worth a human glance.
def found-record [hits: table]: nothing -> record {
  {
    state: present
    matched_by: ($hits | get matched_by | str join ', ')
    title: ($hits | get item.title | str join ' | ')
    item: ($hits | each {|h| $h.item.content.url? | default $h.item.id } | str join ' ')
  }
}

# Fetch a bug's summary anonymously, so restricted (e.g., security) bugs can never leak a summary.
def bug-summary [bug: int]: nothing -> record {
  let resp = http get --full --allow-errors --headers {User-Agent: $USER_AGENT} $"https://bugzilla.mozilla.org/rest/bug/($bug)?include_fields=id,summary"
  match $resp.status {
    200 => { {access: public, summary: ($resp.body.bugs | get --optional 0.summary)} }
    401 => { {access: restricted, summary: null} }
    _ => { {access: error, summary: null, error: ($resp.body.message? | default $"HTTP ($resp.status)")} }
  }
}

def add-item [owner: string, project: int, fields: record, ref: record]: nothing -> record {
  match $ref.kind {
    issue => {
      let added = gh project item-add $project --owner $owner --url $ref.url --format json | from json
      set-todo $fields $added.id
      {state: added, title: $added.title, item: $ref.url}
    }
    bug => {
      let info = bug-summary $ref.bug
      if $info.access == error {
        return {state: error, title: $info.error}
      }
      let title = if $info.summary == null { $"Bug ($ref.bug)" } else { $"Bug ($ref.bug) - ($info.summary)" }
      let added = gh project item-create $project --owner $owner --title $title --format json | from json
      set-todo $fields $added.id
      {state: added, title: $title, item: $added.id}
    }
  }
}

def set-todo [fields: record, item_id: string]: nothing -> nothing {
  gh project item-edit --id $item_id --project-id $fields.project_id --field-id $fields.status_field --single-select-option-id $fields.status_todo | ignore
}
