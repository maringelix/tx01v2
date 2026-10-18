## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Definition of Done

- [ ] `make verify` passes locally (or in the devcontainer) with `HARNESS_STRICT=1`
- [ ] CI is green (`static`, `test`)
- [ ] Docs updated in this PR (README status matrix, docs/*, CHANGELOG `[Unreleased]`)
- [ ] No new scanner ignore, or each new one has `statement` + `expired_at` and is explained below
- [ ] No IAM, network, RBAC or CORS widening, or the reason is stated below
- [ ] Contract (docs/CONTRACT.md) unchanged, or version bumped with a coordinated dx01v2 PR linked below
- [ ] Every new dependency, action or image is pinned (version + SHA256 / commit SHA / digest)
- [ ] No secrets or real identifiers (account IDs, IPs, e-mails) in code, docs or examples

## Cloud impact

<!-- "None" for docs/harness-only changes. Otherwise: what changes in AWS and the cost impact.
     Nothing here has been applied unless a cloud_run_report issue says so. -->

## Notes for the reviewer
