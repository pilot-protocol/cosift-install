SHELL := /bin/bash
REPO  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
JOBS  ?= 4
CASES ?=

.PHONY: check test e2e e2e-onboarding image list generate

# Fast, no container: the interview artifact matches its sources, install.sh carries that
# artifact, and the artifact's own invariants still hold.
check:
	@python3 $(REPO)/onboarding/tools/generate.py --check
	@python3 $(REPO)/tools/embed-onboarding.py --check
	@sh -n $(REPO)/install.sh && echo "install.sh: POSIX syntax ok"
	@$(REPO)/tools/shellcheck.sh $(REPO)/install.sh
	@sh $(REPO)/onboarding/tests/shell/run.sh

# Any change under onboarding/ needs both steps; the second is what reaches users.
generate:
	@python3 $(REPO)/onboarding/tools/generate.py
	@python3 $(REPO)/tools/embed-onboarding.py

test:
	@$(REPO)/tests/run.sh -j $(JOBS) $(CASES)

image:
	docker build -f $(REPO)/tests/Dockerfile -t cosift-install-tests:latest $(REPO)/tests

e2e:
	@$(REPO)/tests/e2e-staging.sh

e2e-onboarding:
	@$(REPO)/tests/e2e-onboarding.sh

list:
	@$(REPO)/tests/run.sh --list
