---
name: verify-agent-status
description: >
  Model-check what Roost says an agent is doing, the task's status, against
  every order its hooks, OSC 7501 reports, the poll and the runner can land
  in. Use before committing a change to how the helper records an agent's
  status: an adapter's observe, update_hook, beside_program_status,
  apply_program_status, the relay's recorder, the runner's end, list_tasks'
  crash check or its guesses, stop or spawn. Also when an agent's hooks or
  reports change (a new capture in test/captures), or for /verify-agent-status.
  Not for how Emacs words or colours a status (that is The word).
---

# Verify what an agent is doing

A TLA+ model, `test/formal/agent_status/AgentStatus.tla`, of the helper
writing a task's `status` from four senders at once, with Claude or Codex,
relayed or not. It checks one promise, in five rules:

**Roost shows which agent needs you.** Once nothing is in flight and the
poll has looked, an agent asking you something shows `permission`
(`AskingShown`), at a request and at Codex's menu about its plan; one at its
prompt shows `ready` or `failed`, and one that
ended shows so (`DoneShownDone`); one at work never shows as waiting
(`WorkNotWaiting`, though `permission` may stand while unsure); a hook's
word that a turn failed or left work in the background stands
(`TurnEndKept`); and, at every moment, the runner's end and `stopped` are
final (`EndsAreFinal`).

**The harm** when one breaks: Roost notifies you of an agent that is
working, hides one that asks, or keeps saying an agent works when it waits,
and it stays that way until the agent's next event.

## Does your change touch it?

It does if the diff changes any of these, or what an agent sends:

| Code (`scripts/roost_remote.py`) | In the model |
| --- | --- |
| `ClaudeAgent.observe`, `CodexAgent.observe`, `plan_asked_about` | `Observe`, `EndPlan` |
| `beside_program_status`, `run_ended` | `Beside`, `s1` in `Hook` |
| `update_hook` (status, `hookAt`, `requestCommand`) | `Hook` |
| `apply_program_status`, `asks_about_plan` | `Report`, `PlanAsk` |
| `program_status_recorder` (`record`, `finish`) | `Record`, `RunnerEnd` |
| `runner`, its `finally` | `RunnerEnd` |
| `list_tasks` (crash, recovery, `was_interrupted`, `approved_command_running`) | `Poll` |
| `stop`, `resume`, `spawn` | `StopTask`, `Resume` |
| The order of hooks and reports in `test/captures/claude-*`, `codex-*` | each step's script (`Prompt`, `Ask`, `End` ...) |

Last confirmed to describe the code at `342ec40`, with the change to
`CodexAgent.observe` and `apply_program_status` for Codex's plan menu that
came with this line. To see what has changed since:
`git diff 342ec40 -- scripts/roost_remote.py`. Move this commit forward only
after you have read the diff of the functions above against the model and it
still describes them.

## Run it

```
python3 test/formal/check.py agent_status
```

About a minute; `make formal` runs every model. Each line is one config:

- `AgentStatus.cfg` must say `pass`: Claude and Codex, relayed or not, up to
  ten steps over two runs, every order the code allows, with a report still
  waiting for the lock as Claude's turn ends.
- `AgentStatus.No*.cfg` each break the code on purpose (the `Break`
  constant) and must fail on the rule they name, so each rule can still fail.
- `LatePermissionPrompt`, `LateIdlePrompt` and `PlanMenuClosed` are findings:
  the code as it is, under timings or moves of yours `AgentStatus.cfg` leaves
  out. They must fail as they say until the code is fixed.

`all models as expected` is a pass. Read every result, pass or fail, with
the pstack `/statechart` skill: a violation as its shortest path in plain
words, a pass as a chart of how a task moves between statuses.

## A rule broke: bug or model?

1. Mirror your change in the model first: the operator in the table above,
   in the code's own terms. A model that still describes the old code proves
   nothing about the new.
2. If `AgentStatus.cfg` then fails, tell the counterexample as steps
   ("Claude reports working; its Stop hook lands first ..."), and replay it
   on the real helper: a `Store` in a temporary folder, a record saved with
   `status`, `runId`, `programStatusRun`, then `update_hook` and
   `apply_program_status` in the trace's order, as
   `test_a_codex_report_older_than_its_last_hook_is_left_out` does. If the
   real code ends as the trace does, it is a bug: fix the code, not the rule.
3. If the real code ends otherwise, the model is wrong there: fix the
   operator to match the code, and say what it missed.

A `No*` variant that passes means a rule no longer catches what it was made
to catch: the change moved the code that variant breaks; break it where it
is now. A finding that passes means it is fixed: drop its config, set its
constant in `AgentStatus.cfg` (say `LagPastTurnEnd = TRUE`), and keep a
`Break` variant that undoes the fix.

## Changing the model

- New status, event or sender: add it to `Observe`, `Hook` or `Report` as the
  code has it, and a step whose script follows a capture.
- New rule: an `INVARIANT` in `AgentStatus.cfg`, and a `No*` variant that
  breaks the code to show it fails (`\* expect: Rule` on its first line, a
  `Break` value in the spec).
- Keep a run under a minute: grow `MaxSteps` only while it stays so.

## What it leaves out

Pi, OpenCode and their report chains; subagents, and so a request of one that
outlasts the turn of the agent you talk to (`claude_answers`); MCP questions,
dialogs, `/clear` and compaction; what an agent says it is doing (`activity`),
which is no status; a hook Codex kills after 3 s (STATUS-3); a false
`crashed` from tmux not answering; `seen` and the word Emacs shows. Hooks of
one agent are taken as awaited, so in order, as the captures show. Bounds:
ten steps, two runs, a gone agent may read `failed` or `exited` from a hook
that landed after the crash.

## Findings open at `342ec40`

Fixed: **StaleReport**. A relayed Claude's `working`, read before its
`StopFailure` or `Stop` with background work and recorded after, made the
task `ready`. Every hook that records a status sets `hookAt` now, and
`background` stands over whatever its reports of the turn had yet to
replace. `AgentStatus.NoTurnEndHookAt.cfg` and `NoTurnEndOverStale.cfg`
undo each half.

- **LatePermissionPrompt** (`DoneShownDone`), only if Claude doesn't wait for
  its Notification hook: you press Esc at a request as its `permission_prompt`
  fires; the hook lands after, moving `updatedAt` past the interrupt marker,
  so the poll can't read the Esc. An unrelayed Claude at its prompt reads
  `permission` until its next event, and `send` refuses without force.
- **LateIdlePrompt** (`WorkNotWaiting`), same condition: an `idle_prompt` a
  minute after a turn lands after your next prompt, and an unrelayed Claude
  at work reads `ready` until its next hook.
- **PlanMenuClosed** (`DoneShownDone`), accepted: Codex says nothing when you
  close its plan's menu, with Esc or "No, stay in Plan mode", so a Codex at
  its prompt reads `permission` until your next prompt. `send` asks first and
  goes through when you say so, and retiring and merging go ahead
  (`require_finished`). Nothing short of reading its screen would tell.
