# Roost

An Emacs package (`roost.el`) that runs coding agents in tmux, each task in
a Git worktree of its own, and a host helper (`scripts/roost_remote.py`)
that Roost copies to each host, this machine or one over SSH, under a name
from its content hash. Emacs and the helper talk JSON. The helper owns Git,
tmux and the task records on its host, and the agents' hooks report to it.
The [manual](docs/manual.md#how-it-works) says how it fits together.

## Checks

- `make test compile` before each commit: the ERT suite (tmux-control
  stubbed), the Python lifecycle tests against real Git and isolated tmux
  sockets, and a byte-compile with no warnings. CI runs it on Emacs 29.1
  and 30.1.
- `test/roost-sweep.el` presses every button and key of the task panel,
  dashboard, sidebar and search results in a gallery of task states, and
  checks rules any of them must keep (no Lisp errors, a way back from each
  change to a view, keys it names apply). Give a new kind of task a state in
  `roost-sweep--gallery`, and a new view an entry in `roost-sweep--views`.
  It also runs the commands that quote your own buffers (a region, a
  diagnostic, an Org entry, a diff line) in a gallery of buffer states,
  `roost-sweep--buffers`, and checks the file and lines they name. Give a
  new kind of buffer a state there.
  To check a new rule, break Roost the way it should catch and watch it fail.
- Tests hold Roost to what it says about security. Every ERT test fails if
  Roost starts a program not in `roost-test--programs`; the helper's
  `Subprocesses` test allows a shell only for the project's own setup and
  teardown commands; and hostile names, prompts, branches and paths go
  through each action against real Git and tmux. A new program, or a new
  way to start one, goes on those lists on purpose.
- One ERT test, or those matching a regexp:
  `emacs -Q --batch -L . -L test -l test/roost-test.el -l test/roost-sweep.el --eval '(ert-run-tests-batch-and-exit "REGEXP")'`.
  Python: `python3 -m unittest discover -s test -p 'test_remote.py' -k PATTERN`.
- The tests of Roost in Magit and its Evil keys are skipped unless Magit,
  Evil and evil-collection are on `TEST_LOAD_PATH`.
- After an agent updates, or when changing what Roost reads from it:
  `make contract` (a free scan of each installed agent), then
  `make contract-live` (real Claude sessions of a few Haiku turns, in
  manual mode, auto mode and with its sandbox on, about seven minutes;
  `CONTRACT_AGENTS="codex pi opencode"` for others). A live run that
  passes records what the agent sent in `test/captures`, which `make test`
  replays: commit a new capture, and read the diff of a changed one.

## Rules

- The agent's own terminal is how you talk to it. Roost adds what lives
  outside the agent: moving between tasks, worktrees, review, merging,
  notifications. Don't rebuild the agent's menus or add Roost keys that
  answer, approve or interrupt it.
- Roost never answers an agent's prompts, never changes global agent
  settings (`~/.claude`, `~/.codex`), and never stages or commits the
  user's work. It deletes work only when the user discards a task and types
  its name.
- Emacs 29.1 and transient 0.4.1 are the floor. Magit, Evil and Org are
  optional: declare their functions, never require them at load.
- The helper is one file of Python 3.9's standard library. Hosts can hold
  records from older helpers, so keep reading their fields.
- What differs between agents (launch and resume arguments, reading their
  hooks) stays in each agent's adapter in the helper; Git, SSH and tmux stay
  out of the adapters.
- Wrap ERT tests in `roost-test--isolated`. It fails on an unstubbed
  `y-or-n-p` or `yes-or-no-p`, which would otherwise hang batch Emacs.

## Where features stop

Advice rather than a rule. Roost stays small by leaving to the agents what
they can do themselves.

- Ask whether a feature would still belong in Roost if every agent could do
  it. What sits between tasks or around them passes: which agent needs you,
  worktrees, merging, review in Magit, remote hosts. What happens inside one
  conversation, such as watching a pull request, fixing CI or answering
  review comments, is the agent's, through its own features and plugins.
- Prefer what works the same for every agent, or does nothing for one that
  can't, and what uses data Roost already has or one `git` or `gh` call. A
  new dependency, option or key has to earn its place.

## Trying it for real

- Leave the user's running Emacs, their Roost state and their tmux server
  alone. Start a separate Emacs (`--init-directory`, its own server name),
  with `roost-state-directory` and `roost-socket-name` set to scratch values.
- Reloading `roost.el` into a running Emacs doesn't redefine keymaps made
  with `defvar-keymap`: set changed keys with `keymap-set`, or restart.
- A checkout runs uncompiled, so measure performance uncompiled too.
- `make qa` does all this with a fake agent: a GUI Emacs of its own, journeys
  through the menu, terminal, panel and merge, each step checked and, on
  macOS, captured (see the manual's Development section). Use it for changes
  to what Roost shows. A whole run takes about 25 minutes, so while you work,
  name the journeys your change touches, and run the whole of it once before
  asking for review. After that, rerun the journeys that failed or that a fix
  touches, and the whole run only for a fix to what every view uses. A
  journey that stops can leave tasks that fail later journeys: fix the first
  failure before reading into the rest. Look at the screenshots of the
  journeys your change touches and of each step with a problem: the checks
  don't see what merely looks wrong. Give a new flow a journey in
  `test/qa/qa.py`. A new way to open a task, or something new you can leave
  unfinished (a question, a menu, a buffer), goes in the `walk_away` grid,
  `WALK_INTERRUPTERS` or `WALK_STARTERS`, which tries it against all the
  others. `--popular` and `--remote` find what a plain local run doesn't.
- A UX design review, of how Roost reads and feels on real journeys rather
  than its code, follows `.claude/skills/ux-review` (`/ux-review`).

## Docs and changes

- The README is short and shows the idea; the manual has every command and
  option. Each user-visible change gets a line in `CHANGELOG.md` under
  Unreleased, with what to do when upgrading. `docs/validation.md` records
  live runs, and new ideas go in `docs/roadmap.md`.
- Write plainly and briefly, in terms of what the user sees and does, with
  no hype. Messages say what happened ("Sent to X").
- Commit messages and pull request titles are one imperative sentence
  ("Shorten the README around new screenshots").
- Review a branch that changes code before opening its pull request (in
  Claude Code, `/code-review high` for asynchronous Emacs code, the
  helper's protocol, Git snapshots or merging and remote hosts, `medium`
  otherwise), and fix what holds up. Docs and one-line edits skip it.
- Pull requests get a Copilot review. Fix the findings that hold up and
  answer the rest in a line on their thread. Ask for another round only
  after a fix that changes behaviour: "Needs a closer look" with no open
  issues is as far as Copilot goes. Squash-merge once CI passes and every
  thread is resolved. Main takes no direct pushes.
