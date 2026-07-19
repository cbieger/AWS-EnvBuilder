# Troubleshooting and safe teardown

Start with the retained local error transcript under `logs/errors/`. Search for
the first `ERROR`, not merely the final cascade. Successful transcripts expire
sooner; failures remain for 90 days by default.

## Preflight says there are no credentials

Run `aws configure sso`, then `aws sso login --profile NAME`. Verify with:

```bash
aws sts get-caller-identity --profile NAME
```

The account ID must be the intended account, and the ARN must not be root. Pass
the same `--profile NAME` to every workspace helper.

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
./scripts/workspace.sh destroy --profile YOUR_PROFILE_NAME --region us-west-2
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
