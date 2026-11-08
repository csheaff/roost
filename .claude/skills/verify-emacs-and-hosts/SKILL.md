---
name: verify-emacs-and-hosts
description: >
  Model-check how Emacs talks to its hosts: requests in flight at once,
  replies late, refused, dropped or timed out, refreshes, the helper copy
  pruned and installed again, and what each reply does to the tasks Emacs
  holds. Use after changing roost.el's host requests (roost--run,
  roost--request, roost--expire-request), refreshes (roost--refresh-host,
  roost--apply-snapshot), how a reply is cached (roost--cache-task,
  roost--cache-reply, roost--newer-events, roost--act, roost--create-task,
  roost--task-made, the inspects in roost--open and roost--notify-attention),
  or the helper's install, prune_helpers, rpc's locking or detach; when the
  "Emacs and its hosts" section of docs/state-machines.md changes; or for
  /verify-emacs-and-hosts.
---

# Verify Emacs and its hosts

`test/roost-sweep-late.el` holds back one reply at a time. This checks every
order of several requests at once, against a model of the code in TLA+.
TLC explores every state the model can reach within its bounds, and fails
with the shortest path to a broken rule.

## What it promises

`CachedTasks.tla` (Host refresh, Cached task):

- **NoRollback.** A reply never takes Emacs back to older news of a task: it
  doesn't bring back a task that went, drop one Emacs knows is there, or
  roll a record back to an older `updatedAt`. Harm: a retired task back in
  the sidebar, an agent asking again for what you answered, review notes
  deleted with a task a stale list lacked.
- **OneList.** At most one list per host is in flight, and
  `roost--refreshing` says whether one is; a full refresh owed has a refresh
  to run it. Harm: a host never asked again until Emacs restarts
  (REQUESTS-1), or two lists overtaking each other.

`HostRequests.tla` (Host request, Helper copy):

- **OneCallback.** Every request ends in exactly one callback, SUCCESS or
  FAILURE. Harm: a command that never hears back, or acts twice.
- **EveryRequestEnds.** Each request is answered in the end, by its host or,
  if the host never answers, by its timer (`roost--expire-request`). A
  property, checked under `TimedSpec`, which assumes only that the timer
  fires. Harm: a command that waits for ever.
- **ActionOnce.** What changes things runs at most once on the host, however
  Roost asks again. Harm: a stop, merge or prompt done twice.
- **NoHelperFailure.** A helper another Emacs pruned fails no request.

## Run it

```
python3 test/formal/check.py emacs_and_hosts
```

About 30 seconds; `make formal` runs every model. Java and TLC 1.7.4 come
from mise. Every line must say `ok`: `CachedTasks.cfg` and
`HostRequests.cfg` pass, and each other config fails the way its first line
says.

Read every result with the pstack statechart skill (`/pstack:statechart`):
it tells a failure's shortest path in plain words, and draws a passing
model as a chart.

## Does your change touch it?

Coverage, confirmed against the code at **d31ec86**. `git diff d31ec86 --
roost.el scripts/roost_remote.py` and look for these:

| Code | Model step |
| --- | --- |
| `roost--refresh-host`: the flag, `finish`, the `unwind-protect`, `revision` read at the start, the quiet poll calling itself | `CachedTasks`: `AskRefresh`, `Finish`, `Succeed` (list) |
| `roost--apply-snapshot` | `ApplySnapshot` |
| `roost--cache-task`'s merge, `roost--newer-events` | `CacheTask`, `NewerEvents` |
| `roost--cache-reply`, `roost--went-p` | `CacheReply` |
| `roost--act`: `listed`, the revision bump at the reply | `AskAct`, `Succeed` (stop, retire) |
| inspect in `roost--open` and `roost--notify-attention` | `AskAct` (inspect), `Succeed` |
| `roost--create-task`'s bump, `roost--task-made` | `AskCreate`, `Succeed` (create) |
| rpc under the registry lock; `list_tasks` | `HostRun`: one step each |
| `detach`, `DETACHED`: what changes things outlives Emacs's wait | `Kept`, `HostLoses` |
| `roost--run`: sentinel, `finished`, the `condition-case` | `HostRequests`: `Ask`, `Deliver`, `Callback` |
| `roost--expire-request`, a dropped connection | `GiveUp` (both models) |
| `roost--request`: `install-and-invoke`, `roost--helper-unusable-p` | `Deliver`, `Then` |
| `roost--install-code`, `prune_helpers` (a week by mtime) | `Host` (install), `OtherPrunes`, `WeekPasses` |

A change elsewhere doesn't need this. A change here does, even a refactor.

## Check a change

1. Mirror the change in the model, step for step: what the code does in one
   sentinel or one command is one step. Keep the names the code uses.
2. Run it. If the main config still passes, and every variant fails as it
   says, the change keeps the promises within the bounds.
3. If a main config fails, read the path with `/pstack:statechart` and walk
   each step against the code:
   - **A real bug** if every step can happen in Roost. Say it in the code's
     words, step by step. Don't weaken a rule or the model to make it pass.
   - **A modeling error** if a step can't happen: fix the model, and say
     what was wrong in the commit.
4. A new guard gets a variant: a `Break` value in the spec that takes the
   guard out, and a config `CachedTasks.NAME.cfg` or `HostRequests.NAME.cfg`
   whose first line is `\* expect: RULE`. Run it and watch it fail before you
   trust the guard's rule.
5. A new kind of request, a new way into the cache, or a new step that runs
   between Emacs's steps goes into the model and the table above.
6. Once the model describes the code again, move the commit above to the
   commit you checked, in the same change. Not before.

## Variants kept

Each takes one guard out of the code and must fail its rule, so the rules
are known to bite:

- `BumpAtRequest`: revision bumped as an action is asked, not as it
  replies. A list asked between them, read before the action, brings back
  what the action retired. NoRollback.
- `NoWentCheck`: `roost--cache-reply` caches a reply for a task that went.
  NoRollback.
- `NoNewerEvents`: an older `updatedAt` replaces a newer one. NoRollback.
- `NoRevisionCheck`: a list read before your retire lands after its reply.
  NoRollback.
- `NoRefreshingGuard`: two lists at once. OneList.
- `NoUnwind`: a refresh that can't start leaves the flag set (REQUESTS-1).
  OneList.
- `NoReinstall`: a pruned helper fails the request. NoHelperFailure.
- `RetryAnyFailure`: retrying on a timeout runs the action again beside the
  first, which went on. ActionOnce.
- `SetupErrorLeavesProcess`: an error after `make-process` calls FAILURE
  and leaves the process, whose sentinel calls back too. OneCallback.
- `NoTimer`: no timer, so a host that never answers holds the request for
  ever. EveryRequestEnds (`temporal`).

## Findings kept

The main config assumes neither of these happens. Each `Finding` config
allows one and must fail NoRollback, until the code changes. When a fix
lands, model it, and the finding config then passes: delete it, or turn it
into a variant of the fix.

- `FindingQuitDuringG`: `C-g` during `g` once `make-process` has run.
  `roost--run` catches `error`, not `quit`, so the process lives on while
  `roost--refresh-host`'s `unwind-protect` finishes the refresh. The next
  poll starts a second list; another Emacs retires a task; the poll's list
  lands, then the first, read before the retire, whose revision still
  matches: the task is back until the next poll. Needs Emacs to see the
  `C-g` within milliseconds.
- `FindingCreateReplyLate`: a list shows the task `create` just made before
  `create`'s reply arrives, and you finish the task meanwhile.
  `roost--task-made` caches the late reply with `roost--cache-task`, not
  `roost--cache-reply`, so the task is back, and opens, until the next poll.
  The window is the reply's way back to Emacs, under a second.

## Bounds and what is left out

- One host. Every table is keyed by host, so hosts don't meet. Tasks: one
  there from the start and one you create. Two refresh asks (plus the full
  refreshes they owe), two of stop, retire or inspect, on the first task, one
  create, `updatedAt` moving twice. Agents' events on the first task only.
  Three requests through the helper. The findings and variants run smaller.
- Left out: forgetting a host, what is owed to measure
  (`roost--measures-owed`), back-off and Offline, GitHub's stamp,
  notifications, seen, watching, the remembered files, the blocking wait, a
  helper of another version, two Emacs editing one task, and Python's own
  work (the crash tests and `test_remote.py` cover that).
- A refusal of an action is modelled as a timeout with nothing run: Emacs
  does the same with both.
- A pass covers the model within its bounds, not roost.el itself.
