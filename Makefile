EMACS ?= emacs

# Elisp protocol/UI tests plus real isolated Git/tmux lifecycle tests.
.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test \
	  -l test/roost-test.el -f ert-run-tests-batch-and-exit
	python3 -m unittest discover -s test -p 'test_*.py' -v

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
