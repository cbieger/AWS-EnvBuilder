# Git commit and review policy

This workspace is connected to
`https://github.com/cbieger/AWS-EnvBuilder.git`. Changes are published on a
feature branch, proposed through a pull request, and merged only after a
reviewer records a `+1`. The repository's existing GPLv2 license is preserved.

## Approved source scope

The proposed commit contains only this workspace's reviewed source artifacts:

- `.gitignore`;
- `README.md`;
- `docs/` guides for architecture, costs, setup, permissions, application
  integration, first run, packaging, troubleshooting, and this commit plan;
- `scripts/` guarded operational helpers and scanner;
- `terraform/` declarations, bootstrap template, documented
  variable example, and `.terraform.lock.hcl` provider checksums;
- `tests/` Python scanner, identity-guard, generated-policy, and package tests.

The commit must exclude:

- `AGENTS.md` and everything under `sources/` because they are project-managed;
- `terraform/.terraform/`, state, saved plans, `backend.hcl`, real
  `terraform.tfvars`, and generated `application.auto.tfvars.json`;
- every runtime log;
- AWS CLI credentials, environment files, keys, tokens, and secrets;
- unrelated files that appeared in the shared workspace, including any
  `bangr_handoff_2026-07-18*` artifact, unless their owner separately requests
  them in a different commit.

## Proposed commit message

```text
feat: package guarded AWS service-account bootstrap

- require AWS account root only for the one-time service-user handoff
- default later commands to the saved local profile and refuse root by default
- add an explicit per-command root override without bypassing approvals
- build source-only portable archives with checksums and exclusion tests
- document identity risk, rollback, packaging, usage, and recovery step by step
```

## Required review workflow

1. Confirm the Git remote is exactly `cbieger/AWS-EnvBuilder`.
2. Create a new branch from the current `origin/main` commit.
3. Keep all source changes unstaged and uncommitted while the repository owner
   reviews the file summary and exact proposed commit title/body.
4. Run formatting, syntax, unit, secret-pattern, and Terraform checks.
5. The repository owner stages only the explicit approved paths; never use an
   unreviewed `git add .` in this shared directory.
6. The repository owner inspects the staged file list and runs
   `git diff --cached --check` before committing.
7. The repository owner performs every commit and push directly.
8. After the owner pushes, open a pull request that explains cost, safety
   controls, validation, and exclusions, then explicitly request a `+1` before
   merge.
9. Do not merge the pull request merely because it was opened; wait for the
   requested review decision.
