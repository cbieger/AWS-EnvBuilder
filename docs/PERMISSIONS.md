# Credential and permission proof

## What the preflight proves

`./scripts/workspace.sh preflight --region REGION` performs only read requests.
After first run it automatically selects the saved service profile; an explicit
`--profile NAME` overrides that selection.

1. `sts:GetCallerIdentity` proves the credential works and names the account.
2. The script refuses an AWS account-root ARN unless that single invocation has
   the exceptional `--run-as-root` flag.
3. EC2 Availability Zone lookup proves the Region is enabled.
4. Small list/describe calls test EC2, Auto Scaling, ELBv2, CloudWatch Logs, ECR,
   S3, AWS Budgets, IAM inventory, and the Resource Groups Tagging API.
5. IAM `SimulatePrincipalPolicy` evaluates the create, update, tag, pass-role,
   and delete action patterns listed in `scripts/permissions.sh`.

No test resource is created and nothing is deleted.

## One-time bootstrap identity and policy

`first_run_setup.sh` has the opposite identity rule: it accepts only the AWS
account root ARN. That root session is used once to create the requested IAM
service account and is then logged out. The bootstrap is intentionally Bash,
not Terraform, because a Terraform-managed access key would be present in state
and an already-running Terraform provider cannot safely switch itself to a key
it just created.

The inline service-user policy is generated from the exact `REQUIRED_ACTIONS`
array in `scripts/permissions.sh`. This keeps first-run access and later policy
simulation aligned. It deliberately excludes IAM user/access-key management;
the service account has no direct `iam:CreateUser` or `iam:CreateAccessKey`
allowance. It does include powerful role/instance/network/state lifecycle
operations required by this reusable deployer, including role-policy writes and
`iam:PassRole`. That combination is privilege-escalation-capable and uses
`Resource: "*"` because generic packaging cannot know future accounts and
generated names. Treat it as an infrastructure-administrator credential. An
organization should replace it with a temporary role, permission boundary, and
narrower ARN/tag conditions.

The access key is written directly to the standard AWS shared credentials file
with restrictive permissions and is never intentionally printed. AWS recommends
temporary credentials, roles, or IAM Identity Center instead of long-term keys
where practical. See [FIRST_RUN.md](FIRST_RUN.md) for the exact handoff, rollback,
rotation, and incident procedure.

## Important limitation

Policy simulation is evidence, not certainty. It may not model an AWS
Organizations Service Control Policy, permission boundary, session policy,
resource/tag condition, service quota, Region opt-in, service-linked role timing,
or a policy change made after the check. A saved Terraform plan also does not
guarantee a later apply. The actual AWS APIs are the final authority.

Strict mode fails if simulation is denied. An administrator may grant the caller
`iam:SimulatePrincipalPolicy` on its own IAM user/role, run the check on the
caller's behalf, or review the action list manually. Do not blindly attach
`AdministratorAccess` merely to make a preflight green.

AWS root cannot be a policy-simulation source. With the explicit root override,
the helpers perform read checks, display prominent warnings, and skip simulation;
that path therefore cannot prove least-privilege readiness.

## Permission families the deployer needs

The exact calls are kept in the `REQUIRED_ACTIONS` array in
`scripts/permissions.sh` so the check and documentation cannot silently diverge.
They cover:

- VPC, subnet, route, Internet Gateway, security-group, launch-template, image,
  instance, and tag lifecycle in EC2;
- Auto Scaling Group, instance-refresh, and target-tracking lifecycle;
- ALB, listener, target-group, attribute, and tag lifecycle;
- role, inline policy, managed-policy attachment, instance-profile, tagging,
  service-linked role, and `iam:PassRole` lifecycle;
- CloudWatch Log Group lifecycle and queries;
- ECR repository/lifecycle plus image push/read/delete;
- S3 state and ALB log bucket lifecycle, encryption, versioning, policies,
  ownership, public-access blocking, objects, and tags;
- AWS Budgets and email-subscriber lifecycle for actual and forecast cost alerts.

Account inventory additionally requires `tag:GetResources`, `iam:ListUsers`,
`iam:ListRoles`, and `iam:ListInstanceProfiles`. These read actions are included
in the generated service-account policy because self-destruct review must fail,
not silently omit sections, when its census cannot be completed.

## Separate permission proof for service-account deletion

The normal deployment service account deliberately cannot manage IAM users or
their access keys. Therefore, selecting `--delete-service-account` requires a
working local profile that resolves to the candidate IAM user plus a different
cleanup IAM user/role or the explicit AWS-root exception. A user name alone is
not accepted as ownership proof. Before the confirmation prompt,
`self_destruct.sh` reads the exact bootstrap user's tags,
credentials, memberships, and policy shape and asks IAM's read-only simulator
about these three additional actions for a non-root cleanup principal:

- `iam:DeleteAccessKey`;
- `iam:DeleteUserPolicy`; and
- `iam:DeleteUser`.

Those actions are **not** added to the service-account policy. Root cannot be
simulated and is permitted only with `--run-as-root`, which displays that proof
limitation. Simulation remains evidence rather than certainty; an SCP,
permission boundary, or later policy change can still block the actual call.
See [SELF_DESTRUCT.md](SELF_DESTRUCT.md) before selecting identity removal.

The bootstrap additionally calls `s3:PutBucketOwnershipControls`. Application
publishing uses ECR upload actions. Human Session Manager use needs
`ssm:StartSession`, `ssm:ResumeSession`, and `ssm:TerminateSession` under an
organization-approved session policy.

## How to request access from an AWS administrator

Give the administrator:

1. this entire repository or a reviewed commit, not a copied fragment;
2. the target account ID and Region;
3. the proposed tag values and resource name prefix;
4. the `REQUIRED_ACTIONS` list;
5. the saved Terraform plan after read access is available;
6. the requirement that `iam:PassRole` be limited to the generated instance-role
   prefix and passed only to EC2 where policy tooling permits;
7. the teardown requirement, not merely create permission.

Ask for a short-lived assumable role. Separate plan/read and apply/write roles
are even better in a team environment.

## Credential failure procedure

- `Unable to locate credentials`: complete SSO/browser login and pass its profile.
- `ExpiredToken`: rerun the SSO login; never extend a token in source code.
- `AccessDenied`: read the service/action in the retained error transcript and
  provide only that evidence to the administrator. Do not send credential files.
- Wrong account ID: stop. Log out or choose the correct profile. Never "try it"
  in the wrong account.
- Root refusal: use the saved first-run service profile. Do not add
  `--run-as-root` merely to silence the failsafe.
