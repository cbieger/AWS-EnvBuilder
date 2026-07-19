# Credential and permission proof

## What the preflight proves

`./scripts/workspace.sh preflight --profile NAME --region REGION` performs only
read requests:

1. `sts:GetCallerIdentity` proves the credential works and names the account.
2. The script refuses an ARN ending in `:root`.
3. EC2 Availability Zone lookup proves the Region is enabled.
4. Small list/describe calls test EC2, Auto Scaling, ELBv2, CloudWatch Logs, ECR,
   S3, and AWS Budgets read access.
5. IAM `SimulatePrincipalPolicy` evaluates the create, update, tag, pass-role,
   and delete action patterns listed in `scripts/permissions.sh`.

No test resource is created and nothing is deleted.

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
