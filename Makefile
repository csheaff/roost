EMACS ?= emacs

# Pure-logic tests: roost loads standalone (tmux-control is an optional,
# soft require), so no tmux or eat is needed here.
.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test \
	  -l test/roost-test.el -f ert-run-tests-batch-and-exit

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile roost.el
	@rm -f roost.elc
