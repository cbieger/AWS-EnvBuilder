# Troubleshooting and safe teardown

Start with the retained local error transcript under `logs/errors/`. Search for
the first `ERROR`, not merely the final cascade. Successful transcripts expire
sooner; failures remain for 90 days by default.

## Preflight says there are no credentials

If this is a brand-new standalone account, complete
[`FIRST_RUN.md`](FIRST_RUN.md). If first run already succeeded, inspect the
saved non-secret profile name:

```bash
sed -n '1p' .workspace/service-account-profile
aws configure list-profiles
```

For an organization-provided SSO profile, run `aws configure sso`, then
`aws sso login --profile NAME`. Verify with:

```bash
aws sts get-caller-identity --profile NAME
```

The account ID must be the intended account, and the ARN must not be root. Pass
the same `--profile NAME` when overriding the saved local service profile.

## A normal command refuses AWS root

This is the expected failsafe. “Root” means the AWS account root ARN returned by
STS, not the operating-system account and not `sudo`. End the AWS root session
and use the service profile created by first run:

```bash
aws logout --profile aws-root-bootstrap
./scripts/workspace.sh preflight --region us-west-2
```

Use `--run-as-root` only for an exceptional, owner-approved root operation. It
applies to one invocation, prints warnings, cannot produce an IAM simulation,
and does not bypass cost/destruction confirmation.

## First run stopped partway through

Read the retained transcript under `logs/errors/`. The helper attempts to remove
only the new access key, tagged managed policy, IAM user, and local profile sections made
by that failed run. If cleanup reports an error, have the account owner compare
IAM and the local AWS profile immediately; do not rerun until the half-created
identity is reconciled. The secret key is never intentionally logged, so it
cannot be recovered from the transcript.

## Strict preflight says AWS CLI is not current

Follow the vendor update instructions linked from `docs/WORKSTATION_SETUP.md`.
Close/reopen the terminal and run `aws --version`. Strict mode also fails when it
cannot reach AWS's official changelog; restore network access rather than
silently disabling the safety proof for an apply.

## IAM simulation is unavailable

The caller probably lacks `iam:SimulatePrincipalPolicy`, is a federated-user
session that cannot map to an IAM role, or is blocked by policy. Read
`docs/PERMISSIONS.md` and have an AWS administrator run or review the check. An
ordinary non-strict diagnostic can continue with a warning; plan/apply cannot.

## Terraform initialization fails

- Missing `backend.hcl`: run the guarded backend bootstrap.
- `AccessDenied` on S3: confirm the profile, account, bucket, and state-key policy.
- Lock error: another Terraform process may be running. Do not delete the `.tflock`
  object until the other operator confirms they have stopped.
- Provider download error: restore access to `registry.terraform.io`; do not copy
  an unverified provider binary into `.terraform`.

## EC2 targets stay unhealthy

1. Run `workspace.sh status` and note the instance ID.
2. Open CloudWatch Logs and inspect `/<project>-<environment>/errors` first.
3. Inspect the 14-day bootstrap and application groups.
4. Confirm the application listens on `0.0.0.0:<container_port>`.
5. Confirm `health_check_path` returns 200-399 without authentication.
6. Confirm the ECR digest exists and matches x86-64.
7. Use Session Manager only if log evidence is insufficient. Do not open SSH.

The bootstrap waits five minutes for local health. A failure is written to the
longer-retained error group; Auto Scaling may then replace the bad instance.

## The URL is HTTP, not HTTPS

That is intentional and visibly documented. Do not send passwords, session
cookies, personal data, or private business data through it. A domain and ACM
certificate are ownership decisions the stub cannot infer. Add them in a reviewed
extension before meaningful use.

## Logs are too expensive or too sparse

Adjust only supported retention values in `terraform.tfvars`, preview, and apply.
Keep `error_log_retention_days` greater than `routine_log_retention_days`; a
Terraform check enforces that. Application code controls log quality. It must not
log secrets, authorization headers, or full sensitive requests.

## Safe teardown

Run:

```bash
./scripts/workspace.sh destroy --region us-west-2
```

Read the destroy plan. Only type `DESTROY AWS WORKSPACE` if the plan identifies
the correct account/environment and only the intended resources. ECR images,
CloudWatch groups, and ALB log objects are deliberately disposable and are
removed with the runtime. The three Terraform-managed budget definitions are
also removed; AWS's native Free Tier alert preference is not changed.

The separate state bucket remains. After destroy succeeds:

1. Run `terraform -chdir=terraform show`; it should contain no managed runtime
   resources.
2. In the AWS Resource Groups Tag Editor, search the Region for
   `Application=<project>` and `Environment=<environment>`.
3. Check EC2 instances, load balancers, EBS volumes, public IPv4 insights, ECR,
   CloudWatch log groups, and S3 for unexpected leftovers.
4. Confirm the workspace budget names are gone, and keep a separately managed
   account-level budget if monitoring must continue without the workspace.
5. Recheck the Billing dashboard the next day because usage reporting is delayed.
6. Keep the tiny state bucket for audit/recovery until the account owner approves
   its separate deletion and version-history retention obligations.

If Terraform destroy partially fails, do not repeatedly delete random resources
in the console. Fix the first permission/dependency error and rerun the same
destroy so Terraform can preserve dependency order.

## Scheduled self-destruct does not arm

Run the read-only command:

```bash
./scripts/workspace.sh schedule-status --region us-west-2
```

If the state is `PENDING`, find AWS SNS's subscription-confirmation email and
click its confirmation link. The confirmation must be detected while more than
12 hours remain. If it was late, the feature intentionally fails closed and does
not delete. Create a freshly reviewed schedule in a future deployment or use the
manual destroy procedure; never edit DynamoDB state to force activation.

If channel validation blocks before plan, confirm that the supplied AWS End User
Messaging number is account-owned, `ACTIVE`, U.S. `TOLL_FREE`, includes SMS
capability, has **Two-way SMS** enabled, uses carrier-managed opt-outs, and sends
inbound messages to the exact SNS topic ARN in the selected account and Region.
Other number types are blocked because AWS can treat `CANCEL` as an opt-out keyword
before Lambda sees it. Check registration, SMS sandbox/destination verification,
and IAM errors. Validation uses `--dry-run`; do not replace it with a billable test.

If `CANCEL` receives no acknowledgement, run `schedule-status`. `CANCELLED` is
authoritative even if an acknowledgement channel failed. Any other state means
the response may have come from the wrong phone/to the wrong AWS number, included
extra characters, or arrived after `EXECUTING`. Email replies are never a valid
cancellation channel. Read [SCHEDULED_SELF_DESTRUCT.md](SCHEDULED_SELF_DESTRUCT.md)
before attempting recovery.

## Full-project self-destruct

Ordinary `workspace.sh destroy` keeps the protected state backend and first-run
service identity. If the entire attached project must be retired, do not empty
the bucket or remove the IAM user manually. Run the default review-only
self-destruct sequence, inspect the complete inventory and saved deletion plan,
obtain independent approval, and only then start a fresh execute run.

The exact syntax, optional-scope proofs, confirmation phrase, partial-failure
order, and final account checks are in [SELF_DESTRUCT.md](SELF_DESTRUCT.md).
Unrelated or ambiguous account assets are inventory-only and never automatically
deleted.
