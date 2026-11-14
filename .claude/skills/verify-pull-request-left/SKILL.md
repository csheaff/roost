---
name: verify-pull-request-left
description: >
  Model-check a pull request left to its agent: the helper's `leave` and
  `tell`, and Emacs deciding when to tell the agent and whose turn it is,
  with replies late, lost or out of order, a helper killed between the
  record and the paste, and the agent, you and a reviewer acting at once.
  Use before committing a change to leave, tell, told, counted, send,
  check_pull_requests or rpc's lock around `list` in scripts/roost_remote.py, or to roost--tell-due-p, roost--agents-turn-p,
  roost--tell-agent, roost--tell-key, roost--tell-occurrence, roost--told,
  roost--yours, roost--prompting-p, roost--newer-left, roost--pr-verdict,
  roost--pr-status, roost-leave-pull-request or roost--cache-task in
  roost.el; when "A pull request left to its agent" in
  docs/state-machines.md changes; or for /verify-pull-request-left.
---

# Verify a pull request left to its agent

One TLC model in `test/formal/pull_request_left/`, checked three ways,
through `test/formal/check.py`. It holds the code to these rules, numbered as
the section's invariants in `docs/state-machines.md`:

- **OnlyAtRest** (I2). A line of Roost's lands only at a prompt the agent
  rests at, after a turn it ended itself. Harm if broken: the line answers a
  question the agent asked, or joins a turn under way.
- **ToldOnce** (I3). Once for each thing, a head or a newest comment, each
  time the pull request is left. Harm if broken: an agent told twice of one
  failure, as after a helper killed mid-telling.
- **AtMost** (I5). `TOLD_MOST` times at most for one kind, each time it is
  left. Harm if broken: an agent whose every fix fails is told for ever.
- **RecordedIsPasted** (I3). What the record says the agent was told, it
  was, unless the helper was killed or tmux said the paste failed, which
  Emacs then leaves to you. Harm if broken: "told", with nothing pasted, and
  the failure hidden from you for two minutes.
- **ThreadsNoEcho** (I4). Of threads again only for a comment that is not
  the agent's own.
- **CacheLeftNewest** (I7). An older reply undoes no leaving, taking back
  or telling in Emacs.
- **RefusedIsYours**, **HadItsTurnIsYours** (I6). What Roost knows it did
  not tell the agent, and what the agent was told, acted on and left
  standing, wait on you at once, not after the two minutes.

I1, that Roost types only its own words, is not a matter of order:
`test_an_agent_is_told_only_what_roost_writes_and_only_at_rest` holds it.
I6's "never neither for long" is time passing; the models hold its two
ends, above.

## Does the change touch it?

```
python3 test/formal/pull_request_left/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the model (below) before you trust a
pass. `roost--cache-task` and `roost--act` are other sections' too: a change
to them that touches no `prLeft`, `prTold`, `prLeftAt` or `prLeftGen`, nor
the order of `roost--newer-events` and `roost--newer-left`, is theirs.

## Run it

```
python3 test/formal/check.py pull_request_left
```

About a minute. Every line must say `ok`. `LeftPullRequest.cfg`,
`LeftPullRequestThreads.cfg` and `LeftPullRequestHost.cfg` must pass; each
`Name.VARIANT.cfg` must fail as its first line says, which proves the rule
can still fail, or, for a finding, that the bug is still there. `make formal`
runs every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the model says

`LeftPullRequest.tla`: one task with one open pull request. Its head is a
number each push of the agent's raises, with a check that fails on it or
not; review threads are the time of the newest comment in one unresolved.
The host's clock is a number each stamped write raises. At any step the
agent takes what was pasted, pushes, answers or resolves a thread, stops or
exits; you interrupt it, prompt it yourself, or press `L`; a reviewer
comments. Emacs holds a copy from replies that come late, out of order or
never.

| Model | Code |
| --- | --- |
| `Leave` | `leave`: `prLeft`, `prTold` dropped, a new `prLeftGen`, `prLeftAt` |
| `Take` | `tell`, to where it writes the record: its refusals in the code's order, `alreadyTold`, `TOLD_MOST`, at rest, the pane |
| `Recorded`, `Kept` | `prTold` written before the paste, every entry kept |
| `Paste`, `Record`, `SendId` | `send` under `tell`'s ID: the paste, tmux taking the line or not and saying it failed, the ID written after |
| `Killed` | the helper killed after the record, or after the paste |
| `Busy` | the registry lock, which the agent's hooks wait for |
| `Turn` | `roost--any-turn` of `roost--pr-verdict`: the forge asked after the agent's last event (`roost--pr-status`), and the agent not at work |
| `Key`, `Occ`, `ToldOf`, `Entries` | `roost--tell-key`, `roost--tell-occurrence`, `roost--told`, `roost--told-entry` |
| `Due`, `AgentsTurn` | `roost--tell-due-p`, `roost--agents-turn-p` |
| `Tells`, `Reply`, `NoReply` | `roost--tell-agent`: `roost--telling`, its success, and `roost--untold` on a refusal or no reply |
| `Merge` | `roost--cache-task`: `roost--newer-events`, then `roost--newer-left`, and `prStatus` from the reply that has it |
| `Deliver` with `mine` | the reply to your own `L`, which forgets `roost--untold` |
| `GraceEnds`, `expired` | `roost--pr-grace` over, by `roost--told-here` or the entry's time |
| `Poll`, `PollAsks`, `polled` | rpc `list`: the record read under the lock, and `check_pull_requests` once it is let go; one step unless a config has `PollSplit` |
| `OtherAsks` | another Emacs's `tell`, of what the forge says then |

Three configs, as the whole is too large for one:

- `LeftPullRequest.cfg`: one Emacs, failed checks, two pushes, `L` twice,
  two tellings, two lists, one prompt of your own, and requests the helper
  takes after Emacs stopped waiting (`LateTake`).
- `LeftPullRequestThreads.cfg`: one Emacs, two comments, the agent's or a
  reviewer's, and no push or prompt of your own.
- `LeftPullRequestHost.cfg`: the helper alone, asked by any Emacs at any
  time and killed at any step: two pushes, `L` twice, three tellings.

Checked once and in no config, for its two minutes: `LeftPullRequest.cfg`
with `PollSplit` passes (60 million states).

Assumed: the forge's clock and the host's agree. A comment's time is the
forge's and `updatedAt` the host's, and `roost--tell-due-p` compares them:
on a host whose clock is behind by more than the rest of the agent's turn,
its own answer reads as newer than its last event, and it is told of it.
The model has one clock.

Left out: conflicts, which are told as a failed check is, by the head;
`to merge`, which is never the agent's; you at the task's terminal, a draft
to it open and the thirty seconds after a prompt of yours, which only keep
Emacs from asking, as never asking does; the two-minute patience of
`roost--pr-verdict`, taken as over; a second pull request for the task; what
the line says (`told_words`); notices and the row's word, which follow
`roost--yours`; `leavePr` on create, which is `Leave` before anything else;
and a resumed agent, whose prompt may hold what you left half typed.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it, at that point, with
that lock held or not. If it can, it is a bug: keep the rule, keep a config
that shows it (`\* expect: Rule`), and report it with those steps. Do not
weaken a rule or a bound until it passes, and do not fix product code
unless asked. If a step can't happen in the code, the model is wrong: fix
the action and point its comment at the code that rules the step out.

### Findings

Open, all of one cause: Emacs judges by the copy it holds, and `tell`
doesn't know what that copy was.

- `LeftPullRequest.finding-told-after-a-turn.cfg` (NothingSinceJudged). A
  check has failed and the agent rests. You prompt the agent from where
  Roost doesn't see it, as from another terminal or Remote Control. It takes
  a turn, perhaps fixing the failure, and rests again before Emacs has
  heard of the turn. Emacs asks `tell` by what it held, the helper finds
  the agent at rest, and the agent is told of what stood before its turn.
  One line too many, once. A fix: Emacs sends the `updatedAt` it judged by,
  and `tell` refuses when the record's is another.
- `LeftPullRequestThreads.finding-told-of-its-own-answer.cfg`
  (ThreadsNoEcho). The same, with a thread: told after a turn in which it
  answered there, by a paste tmux took and said failed, so that Emacs
  holds no word of the telling; Emacs then takes the agent's own answer
  for the first news of the thread, and the agent is told of it. The fix
  above ends this path.
- `LeftPullRequestThreads.finding-answered-while-a-list-asks.cfg`
  (ThreadsNoEcho). With no prompt of yours: a list reads the record of an
  agent at rest, just told of a thread. While the list asks the forge, the
  agent takes the line, answers in the thread and rests again. Emacs then
  holds its answer beside the time of its event before, which makes the
  answer news, and the agent is told of it. It needs a whole turn within
  one list's asking. The fix above ends this too: the record has moved.

Fixed before the model, each kept as the variant that undoes it:
`LeftPullRequestHost.record-after-paste.cfg`,
`LeftPullRequestHost.send-id-without-gen.cfg`,
`LeftPullRequestHost.told-trimmed.cfg`,
`LeftPullRequest.refused-stays-hidden.cfg` and
`LeftPullRequest.grace-after-its-turn.cfg` are what review of #268 found.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new refusal in `tell`, a new field Emacs keeps of
the record, or a new guard in `roost--tell-due-p` goes in where its code
is. To prove a new rule can fail, add a constant that breaks the code it
guards the way a bug would, a `Name.VARIANT.cfg` with `\* expect: Rule`,
and keep it. To fix a finding, follow `.claude/skills/fix-a-finding`.

Once the model describes the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `6476f2f`, where the model was written.
