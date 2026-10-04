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
