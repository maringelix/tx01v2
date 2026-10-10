# tx01v2 harness entry points. CI runs exactly these targets (see docs/HARNESS.md).
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

HARNESS := bash scripts/harness.sh

.PHONY: help tools static test verify all clean

help: ## Show the available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z-]*:.*## / { printf "  %-8s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

tools: ## Install the pinned harness tools into .tools/ (SHA256-verified)
	@bash scripts/install-tools.sh

static: ## Policies, fmt, validate, lock files, tflint, trivy, actionlint, shellcheck, kubeconform, helm template, gitleaks
	@$(HARNESS) static

test: ## terraform test (mock AWS provider) for terraform/bootstrap and terraform/envs/lab
	@$(HARNESS) test

verify: ## static + test (what CI runs)
	@$(HARNESS) static test

all: ## Every stage (in this repo: same as verify)
	@$(HARNESS) all

clean: ## Remove installed tools, harness scratch data and local Terraform working dirs
	@rm -rf .tools .cache
	@find terraform -type d -name .terraform -prune -exec rm -rf {} +
	@find terraform/modules -name .terraform.lock.hcl -delete
	@rm -rf "$${TMPDIR:-/tmp}/tx01v2-harness"
