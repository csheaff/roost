---
name: verify-git-and-forge
description: >
  Model-check what Roost says of a task's merge: the helper's pull request
  record and its "landed" (which `x` retires on), and the row word "merged"
  in Emacs as polls and replies come and go. Use when a change touches
  has_tip, recorded_merge_at, landed, check_pull_requests,
  task_pull_requests, fetch_heads, record_push, push_pull_request,
  pull_request, safe_to_delete, merged_pull_request_head, add_git_stats, git_stamp or
  rpc's `pr` and `list` in scripts/roost_remote.py, or roost--refresh-host,
  roost--cache-task, roost--task-states, roost--landed or roost--merged-p in
  roost.el; or when asked to verify "Git and the forge" in
  docs/state-machines.md.
---

# Verify Git and the forge

Two TLA+ models in `test/formal/git_and_forge/`, checked by TLC through
`test/formal/check.py`. They hold the code to these rules:

- **RetireLosesNothing** (`Landed.tla`). Whatever the helper's record says
  merged at the tip did merge, here or on the forge, so `x`, which deletes
  the branch on that word, loses no commit. Harm if broken: retiring
  deletes work that is nowhere else.
- **RecordedMergesHappened** (`Landed.tla`). A record that says `MERGED`,
  or names a `mergedHead`, names a merge the forge made, at that head.
- **RepliesSayTrue** (`Landed.tla`). What a `list` reply tells Emacs is
  landed was, at the tip as it was measured.
- **CleanNoOlderThanLanded** (`MergedWord.tla`). A row says "merged" only
  with a cleanliness measured with, or after, the news that it landed.
- **MergedHeals** (`MergedWord.tla`, temporal). A row that says "merged" of
  work with commits the merge lacks stops saying so, as polls go on.

## Does the change touch it?

```
python3 test/formal/git_and_forge/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the models (below) before you trust a
pass. A change outside these functions can still matter if it changes what
they are given, such as the fields of a record or of a reply.

## Run it

```
python3 test/formal/check.py git_and_forge
```

About two minutes. Every line must say `ok`. `Landed.cfg`, `LandedTwoPRs.cfg`
and `MergedWord.cfg` must pass; each `Name.VARIANT.cfg` must fail as its
first line says, which proves the rule can still fail. `make formal` runs
every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the models say

`Landed.tla`, one task on its host. Commits are numbers with parents; 0 is
where the task started. The world moves at any step: the agent commits,
amends, pushes (forced or not), pulls the forge's branch, opens a pull
request; the forge takes commits, merges, closes, reopens once; you merge
the task by hand or pull a merge into the integration branch once.
Meanwhile one poll and one `P` run, in the code's locked steps:

| Model | Code |
| --- | --- |
| `HasTip`, `RecordedMergeAt`, `HostLanded` | `has_tip`, `recorded_merge_at`, `landed` |
| `PollList` | rpc `list`: `list_tasks`, then `branch_tip` and `pushed` in `check_pull_requests` |
| `PollAsk`, `Ours` | `task_pull_requests` (no answer: None) |
| `PollFetch`, `ToFetch` | `head_to_fetch`, `fetch_heads` |
| `PollWrite`, `Shown`, `Made` | `shown_pull_request`, `merged_tip`, the record and its compare-and-swap |
| `PollMeasure` | `add_git_stats`, and rpc's `landed()` of a task asked about |
| `PStartPush`, `PPush`, `PRecord` | rpc `pr` with a record: `push_pull_request`, `record_push` |
| `POpen`, `POpenRecord` | rpc `pr` with none, or a title after closed or merged: `pull_request` |
| `RetireLosesNothing` | `merged_pull_request_head` + `safe_to_delete` trust the record or a fresh forge answer |

`MergedWord.tla`, one task in Emacs, its agent idle and seen. The host's
landed is taken as true (Landed.tla checks that). Polls are quiet (`Q`) or
ask the forge too (`QP`); a quiet poll that sees the Git stamp move, or
finds measuring owed, starts a list of that task (`M`), or a full one
(`F`) when every task is owed; `g` is `F`. Replies come back good, failed,
or dropped as stale, as `roost--refresh-host`'s success lambda, `lost` and
`roost--measures-owed` and `roost--measures-due` handle them. `Merged` is `roost--merged-p` reduced
to `landed` and `dirty`.

Bounds: `Landed.cfg` three commits and one pull request, `LandedTwoPRs.cfg`
two and two, `MergedWord.cfg` two commits, two merges and two replies lost.

Left out: a second poll at once (another Emacs), the fields
`unfetched` (every poll may try a head again, any fetch may fail, which
covers trying once), `mergedBases` and `worktreePr`; GitLab's rebase
merges; branches of the same name from forks or earlier tasks
(`own_commits` is taken as so); the verdict, turn, notices and merge hooks;
the agent's status, seen, and a worktree on another branch.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it, at that point, with
that lock held or not. If it can, it is a bug: keep the rule, keep a config
that shows it (`\* expect: Rule`), and report it with those steps. Do not
weaken a rule or a bound until it passes, and do not fix product code
unless asked. If a step can't happen in the code, the model is wrong: fix
the action and point its comment at the code that rules the step out.

`MergedWord.TwoLost.cfg` was such a finding: two measurements of a change
lost in a row, and Emacs stopped asking. It is fixed: what is owed stays
owed, taken up later (`roost--measures-due`, the model's `later` and `Due`),
`MergedWord.cfg` has its bound of two replies lost, and
`MergedWord.GivesUp.cfg` undoes the fix.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new way to write the record, a new step outside the
lock, or a new reply field Emacs keeps goes in as an action. To prove a new
rule can fail, add a constant that breaks the code it guards the way a bug
would, a `Name.VARIANT.cfg` with `\* expect: Rule`, and keep it.

Once the models describe the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `e910487`, with the change to `roost--refresh-host` and
`roost--measures-due` that came with this line.
