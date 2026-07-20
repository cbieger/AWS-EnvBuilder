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
- `scripts/` guarded operational helpers, application scanner, account
  inventory, and ownership-safe self-destruct sequence;
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

## Proposed commit message for the scheduled self-destruct branch

```text
feat: add cancellable scheduled environment teardown

- prompt for a duration or local deadline and convert it safely to UTC
- require confirmed email and verified two-way SMS before arming
- send five milestone notices and accept only exact SMS CANCEL
- run deletion-only Terraform from an AWS CodeBuild control plane
- keep the expanded exact bootstrap actions in one ownership-tagged managed policy
- document costs, registrations, failure modes, and retained state
```

## Required review workflow

1. Confirm the Git remote is exactly `cbieger/AWS-EnvBuilder`.
2. Create a new branch from the intended reviewed base. A stacked pull request
   must name and link the prerequisite pull request until it reaches `main`.
3. Keep all source changes unstaged and uncommitted while the repository owner
   reviews the file summary and exact proposed commit title/body.
4. Run formatting, syntax, unit, secret-pattern, and Terraform checks.
5. The repository owner stages only the explicit approved paths; never use an
   unreviewed `git add .` in this shared directory.
6. The repository owner inspects the staged file list and runs
   `git diff --cached --check` before committing.
7. The repository owner normally performs every commit and push directly. An
   explicit later instruction to create a pull request authorizes the needed
   branch commit and push for that reviewed request only.
8. After the approved source is pushed, open a pull request that explains cost,
   safety controls, validation, and exclusions, then explicitly request a `+1`
   before merge.
9. Do not merge the pull request merely because it was opened; wait for the
   requested review decision.
