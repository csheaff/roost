EMACS ?= emacs

# Extra -L arguments for the ERT run, such as Magit and its dependencies;
# without Magit, the tests of Roost in Magit are skipped.
TEST_LOAD_PATH ?=

# Elisp protocol/UI tests, the sweep of every view's buttons and keys,
# plus real isolated Git/tmux lifecycle tests.
.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test $(TEST_LOAD_PATH) \
	  -l test/roost-test.el -l test/roost-sweep.el -f ert-run-tests-batch-and-exit
	python3 -m unittest discover -s test -p 'test_*.py' -v

# Roost used as you would, in a GUI Emacs of its own with a fake agent,
# each step checked and captured: see test/qa/qa.py.  Emacs needs
# tmux-control, and Magit for review, as in
#   make qa QA_FLAGS="-L ../tmux-control --package-dir ~/.emacs.d/elpa"
QA_FLAGS ?=

.PHONY: qa
qa:
	python3 test/qa/qa.py --emacs "$(EMACS)" $(QA_FLAGS)

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile roost.el
	@rm -f roost.elc

# Roost's reading of the installed Claude Code (see test/claude_contract.py):
# a free scan, and with contract-live a real session of a few Haiku turns.
.PHONY: contract contract-live
contract:
	python3 test/claude_contract.py

contract-live:
	python3 test/claude_contract.py --live
