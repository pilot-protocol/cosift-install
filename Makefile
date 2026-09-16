SHELL := /bin/bash
REPO  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
JOBS  ?= 4
CASES ?=

.PHONY: test e2e image list

test:
	@$(REPO)/tests/run.sh -j $(JOBS) $(CASES)

image:
	docker build -f $(REPO)/tests/Dockerfile -t cosift-install-tests:latest $(REPO)/tests

e2e:
	@$(REPO)/tests/e2e-staging.sh

list:
	@$(REPO)/tests/run.sh --list
