---
name: verify-pull-request-merged
description: >
  Model-check a pull request Roost merges: the helper's `begin_merge`, its
  one `gh pr merge` and `end_merge`, and Emacs deciding when to ask and
  whose turn `to merge` is, with replies late, lost or out of order, a
  helper killed between the record and the call, and the agent, you, a
  reviewer and another Emacs acting at once. Use before committing a change
  to merge_asked, merges_asked, begin_merge, merge_pull_request, end_merge,
  what make_task does with `mergePr`, the `merge-pr` branch of answer or
  check_pull_requests in scripts/roost_remote.py, or to
  roost--merge-occurrence, roost--merge-asked, roost--merge-due-p,
  roost--merges-turn-p, roost--merge-itself, roost--yours,
  roost--pr-verdict, roost--pr-status, roost--prompting-p, roost--act or
  roost--cache-task in roost.el; when "A pull request Roost merges" in
  docs/state-machines.md changes; or for /verify-pull-request-merged.
---

# Verify a pull request Roost merges

One TLC model in `test/formal/pull_request_merged/`, checked two ways,
through `test/formal/check.py`. It holds the code to these rules, numbered as
the section's invariants in `docs/state-machines.md`:

- **OnlyMade** (I1). GitHub is asked to merge nothing of a task that was not
  made for Roost to merge. Harm if broken: a pull request you kept the last
  look at is merged.
- **OnlyGreen** (I2). This Emacs asks for no head that never read
  `to merge`. Harm if broken: a pull request with a failed check or an open
  thread is merged.
- **JudgedHead** (I3). It merged at a head some call asked for. Harm if
  broken: a push between what Emacs judged and the call is merged with it,
  unchecked.
- **OnceEachHead** (I4). GitHub is asked once for each head, whoever asks
  and whenever the helper is killed. Harm if broken: a merge GitHub refused
  is asked for at every poll, or by two Emacs at once.
- **RefusedIsYours** (I5). What the host refused, or never answered for,
  waits on you at once, not after the two minutes.
- **NotWhileThere** (I8). Nothing is asked for while you are at the task's
  terminal or writing its agent a prompt.
- **SaidOnce**. "Merged" is said of a head no more than once.

I6, that only the record's URL, a method and a commit reach `gh`, and I7,
that the agent's `updatedAt` stays, are no matter of order:
`test_a_pull_request_roost_merges_is_asked_for_once_for_each_head` holds
them. I5's "never neither for long" is time passing; the model holds one end
of it, above.

## Does the change touch it?

```
python3 test/formal/pull_request_merged/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the model (below) before you trust a
pass. `make_task`, `answer`, `check_pull_requests`, `roost--act`,
`roost--cache-task`, `roost--yours`, `roost--pr-verdict`, `roost--pr-status`
and `roost--prompting-p` are other sections' too: a change to them that
touches no `prMerge`, `prMergeAsked` or `prMergeHeads`, nor the `merge-pr`
branch, nor what reads `to merge`, is theirs.

## Run it

```
python3 test/formal/check.py pull_request_merged
```

Under a minute. Every line must say `ok`. `MergedPullRequest.cfg` and
`MergedPullRequestHost.cfg` must pass; each `Name.VARIANT.cfg` must fail as
its first line says, which proves the rule can still fail. `make formal`
runs every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the model says

`MergedPullRequest.tla`: one task with one pull request, made for Roost to
merge or not. Its head is a number each push of the agent's raises, and it
is green or not: what reads `to merge`, with a check that passed, into the
task's branch. A reviewer or a check changes that at the same head. At any
step the agent pushes, you come to the task's terminal or leave it, another
Emacs asks for any head it may have judged by, and the helper is killed.
Emacs holds a copy from replies that come late, out of order or never.

| Model | Code |
| --- | --- |
| `made` | `prMerge`, which only `make_task` writes |
| `Takes` | `begin_merge` under the registry lock: its refusals, `alreadyAsked` for a head in `prMergeHeads`, and `prMergeAsked` written before the call |
| `AsksForge` | `merge_pull_request`, with the lock let go: `gh pr merge --match-head-commit`, which GitHub takes at that head or refuses |
| `Ends` | `end_merge`: `merged` or `error`, unless another was asked for since |
| `Killed` | the helper killed after the record, or after the call |
| `OtherAsks` | another Emacs's `merge-pr`, of any head so far |
| `Poll` | rpc `list`: the record and the forge as they are, and the pull request's state recorded |
| `Verdict` | `roost--pr-verdict` saying `to merge`, with the passing check and the base `roost--merge-due-p` adds |
| `Asked`, `Due`, `MergesTurn`, `Yours` | `roost--merge-asked`, `roost--merge-due-p`, `roost--merges-turn-p`, `roost--yours` |
| `Asks` | `roost--merge-itself`: `roost--merging`, and not while you are there |
| `Hears` | its replies: `alreadyAsked` said nothing of, and left to you when the record has nothing of that head; a refusal into `roost--unmerged`; one to a request Emacs gave up on dropped |
| `GivesUp` | no reply in time: `roost--unmerged`, and said |
| `Merge` | `roost--cache-task`: the reply's word of the record replaces Emacs's, older or not, as no event of the agent's stamps it |
| `GraceEnds`, `expired` | `roost--pr-grace` over, by `roost--asked-here` or the record's time |

Two configs:

- `MergedPullRequest.cfg`: this Emacs with two requests and two lists,
  another Emacs with one, two pushes, one change of green, one visit of
  yours, and the helper killed at any step (7.8 million states).
- `MergedPullRequestHost.cfg`: the helper alone, asked four times by any
  Emacs for any head, and killed at any step (11.8 million states).

Checked once and too large to keep: `MergedPullRequest.cfg` with three
requests, three lists and two changes of green ran twelve minutes without
ending, and broke no rule in that time.

What it found, fixed before the section merged: the record kept only the
last merge asked for, so a head asked for, then the next, then the first
again, as by an Emacs that had yet to hear of the push, was asked for
twice. `prMergeHeads` remembers them all;
`MergedPullRequestHost.only-the-last-kept.cfg` is that bug.

The section's open questions, answered:

- A reply to `merge-pr` that comes after a list that already says merged:
  the reply has no word of the forge, so the copy stays merged; "Merged" is
  said once.
- Two Emacs asking at once: `begin_merge` runs under the registry lock, so
  the second is told `alreadyAsked`, whichever GitHub is being asked for.
- An older list reply that takes `prMergeAsked` out of the copy: Emacs asks
  again, the helper answers `alreadyAsked`, GitHub is not asked, and nothing
  is said twice.

Assumed: GitHub merges only at the head `--match-head-commit` names, and
its branch rules hold whatever else you rely on. Emacs judges by what a
list last said, which a reviewer may have changed since: the model lets it
ask for a head that was green and is no longer.

Not modelled: `B` changing the branch the task merges into between what
Emacs judged and the request, which `begin_merge` refuses by the `base`
Emacs sends (a test holds it); the two clocks of the two minutes, which Emacs reads by its
own where it asked; `roost--prompting-p`'s 30 seconds, which the model
takes as you being there; and GitLab, drafts and another branch's pull
request, which `roost--merge-due-p` leaves out before any of this.
