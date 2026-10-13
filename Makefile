# tx01v2 harness entry points. CI runs exactly these targets (see docs/HARNESS.md).
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

HARNESS := bash scripts/harness.sh

.PHONY: help tools static test verify e2e all local-up local-check local-down clean

help: ## Show the available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z-]*:.*## / { printf "  %-8s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

tools: ## Install the pinned harness tools into .tools/ (SHA256-verified)
	@bash scripts/install-tools.sh

static: ## Policies, fmt, validate, lock files, tflint, trivy, actionlint, shellcheck, kubeconform, helm template, gitleaks
	@$(HARNESS) static

test: ## terraform test (mock AWS provider) for terraform/bootstrap and terraform/envs/lab
	@$(HARNESS) test

verify: ## static + test (the CI jobs static and test)
	@$(HARNESS) static test

e2e: ## Local lab end to end on Docker: up, every probe, down + leftover check (CI job e2e)
	@$(HARNESS) e2e

all: ## Every stage: static + test + e2e
	@$(HARNESS) all

local-up: ## Create the local lab and install the platform (LOCAL_PROFILE=core|observability|operations|full)
	@bash scripts/local-lab.sh up

local-check: ## Run the platform probes against the running local lab
	@bash scripts/local-lab.sh check

local-down: ## Destroy the local lab and check for leftovers
	@bash scripts/local-lab.sh down

clean: ## Remove installed tools, harness scratch data and local Terraform working dirs
	@rm -rf .tools .cache
	@find terraform -type d -name .terraform -prune -exec rm -rf {} +
	@find terraform/modules -name .terraform.lock.hcl -delete
	@rm -rf "$${TMPDIR:-/tmp}/tx01v2-harness"
