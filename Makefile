EMACS ?= emacs

# Extra -L arguments for the ERT run, such as Magit and its dependencies;
# without Magit, the tests of Roost in Magit are skipped.
TEST_LOAD_PATH ?=

# Elisp protocol/UI tests, the sweep of every view's buttons and keys, the
# sweep of late replies, plus real isolated Git/tmux lifecycle tests, on
# every core: see test/run.py. JOBS=2 uses two; K=REGEXP keeps to the ERT
# tests matching it and the Python tests whose names hold it.
JOBS ?=
K ?=
RUN = python3 test/run.py --emacs "$(EMACS)" $(if $(JOBS),--jobs $(JOBS)) $(if $(K),-k '$(K)') \
  $(if $(TEST_LOAD_PATH),--load-path='$(TEST_LOAD_PATH)')

.PHONY: test
test:
	$(RUN)

# The same with one case in twelve of each sweep, which are most of the
# time, and without a suite that passed in full on what it reads now: half
# a minute after a change to roost.el alone, for while you work. Run
# `make test` before a commit.
.PHONY: quick
quick:
	$(RUN) --quick

# The whole suite in one Emacs and one Python, as it ran before test/run.py:
# about four times as long, and the order a test may have come to rely on.
.PHONY: test-serial
test-serial:
	$(EMACS) -Q --batch -L . -L test $(TEST_LOAD_PATH) \
	  -l test/roost-test.el -l test/roost-sweep.el -l test/roost-sweep-late.el \
	  -f ert-run-tests-batch-and-exit
	python3 -m unittest discover -s test -p 'test_*.py' -v

# The helper killed at every step of every action, as a dropped connection
# or a reboot would, and what a user does next: see test/crash_harness.py.
# Slow, and slower with CRASH_SWEEP=lines, which kills it at every line it
# reaches too.
CRASH_SWEEP ?= commands

.PHONY: crash
crash:
	ROOST_CRASH_SWEEP=$(CRASH_SWEEP) python3 -m unittest discover -s test -p 'test_crash.py' -v

# Roost used as you would, in a GUI Emacs of its own with a fake agent,
# each step checked and captured: see test/qa/qa.py.  Emacs needs
# tmux-control, and Magit for review, as in
#   make qa QA_FLAGS="-L ../tmux-control --package-dir ~/.emacs.d/elpa"
QA_FLAGS ?=

.PHONY: qa
qa:
	python3 test/qa/qa.py --emacs "$(EMACS)" $(QA_FLAGS)

# Roost's TLA+ models of its state machines, each with the broken variants
# it must catch: see test/formal/check.py and .claude/skills/verify-*.
.PHONY: formal
formal:
	python3 test/formal/check.py

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile roost.el
	@rm -f roost.elc

# Roost's reading of the installed agents (see test/agent_contract.py): a
# free scan of each, and with contract-live real sessions of a few turns,
# kept in test/captures. Claude Code by default; for others, as in
#   make contract-live CONTRACT_AGENTS="codex pi opencode" CONTRACT_FLAGS=--program-status
CONTRACT_AGENTS ?= claude
CONTRACT_FLAGS ?=

.PHONY: contract contract-live
contract:
	python3 test/agent_contract.py

contract-live:
	python3 test/agent_contract.py --live $(CONTRACT_FLAGS) $(CONTRACT_AGENTS)

# Pictures of the task panel and dashboard in every task state of
# the sweep's gallery, with no agent or host: see test/qa/gallery.el. Needs
# a display, as Xvfb gives, and ImageMagick's import.
GALLERY_OUT ?= gallery
GALLERY_THEME ?=

.PHONY: gallery
gallery:
	GALLERY_OUT="$(GALLERY_OUT)" GALLERY_THEME="$(GALLERY_THEME)" $(EMACS) -Q -L . -L test -L test/qa \
	  $(TEST_LOAD_PATH) --eval "(setq inhibit-startup-screen t)" \
	  -l test/roost-test.el -l test/roost-sweep.el -l test/qa/gallery.el -f roost-gallery
