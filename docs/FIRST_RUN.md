# First run: replace AWS root with a service account

This page describes the one-time identity handoff in literal order. Read the
whole page before running the command. The first-run operation changes AWS IAM
and creates a long-term access key; ordinary validation and packaging do not.

## “Root” means AWS account root—not `sudo`

The required first caller is the **AWS account root identity**. Its STS ARN ends
in `:root`, for example:

```text
arn:aws:iam::123456789012:root
```

This is unrelated to the macOS/Linux `root` operating-system account. Do not
run `sudo ./scripts/first_run_setup.sh`. `sudo` cannot turn an IAM user into AWS
account root and may instead create local files owned by the wrong OS user.

The inverse rule applies after setup: every AWS-facing helper refuses the AWS
account root identity unless that one invocation includes `--run-as-root`.

## What the first-run helper does

After showing the account, proposed IAM user, and proposed local profile, the
helper requires the exact phrase `CREATE AWS SERVICE ACCOUNT`. It then:

1. creates one IAM user tagged as managed by AWS-EnvBuilder;
2. generates one customer-managed policy from the same action list the preflight audits;
3. tags that policy and attaches it only to the new user;
4. creates one programmatic access key;
5. writes the key directly to the standard AWS shared credentials file with
   owner-only permissions, without printing it or passing it on a command line;
6. configures the selected Region and JSON output for the new local profile;
7. authenticates as the new user and runs the complete strict read-only
   preflight under that identity; and
8. records only the profile name in ignored
   `.workspace/service-account-profile` so later helpers select it automatically.

If a step fails, the helper attempts to delete only the access key, tagged
managed policy, IAM user, and local profile sections created by that run. The retained
error transcript reports cleanup failures, but never intentionally includes the
secret access key.

## Important security tradeoff

The user requested an IAM service account, so this bootstrap creates a long-term
access key. AWS recommends temporary role or IAM Identity Center credentials
where practical. A reusable Terraform deployer is necessarily powerful: it can
create and pass EC2 roles, run instances, manage networking, publish images,
write logs, manage state storage, and create/delete budget definitions. The
generated policy does **not** allow the service account to create IAM users or
new access keys directly. However, creating roles, writing inline role policies,
and passing roles to EC2 is privilege-escalation-capable. Treat this credential
with the same care as an infrastructure administrator; the root refusal is not
a substitute for a company permission boundary.

For a company account, ask the AWS administrator to replace this user with a
short-lived assumable deployment role and narrow resource/tag conditions to the
company's naming rules. The generic package cannot know future account IDs,
project prefixes, or generated resource ARNs, so its bootstrap policy uses
`Resource: "*"` for the audited action list.

## Before touching the keyboard

You need all of the following:

- a macOS, Linux, or WSL2 terminal opened at the extracted kit's top folder;
- current AWS CLI v2, Terraform, Python, `jq`, and `curl` as described in
  [WORKSTATION_SETUP.md](WORKSTATION_SETUP.md);
- access to the AWS account root email address and its MFA method;
- the intended 12-digit AWS account ID written down for comparison;
- a unique IAM user name such as `aws-envbuilder-automation`;
- a unique local profile name (the IAM user name is the safe default); and
- permission from the AWS account owner to create this deployment identity.

Do not create or use an AWS root access key. The example below uses temporary
browser credentials for the one-time bootstrap.

## Exact first-run procedure

### 1. Validate the extracted kit locally

```bash
./scripts/workspace.sh validate
```

This command may download a Terraform provider, but it does not authenticate to
AWS or create an AWS resource. Correct every reported error before continuing.

### 2. Open a temporary AWS root browser session

`aws login` requires AWS CLI 2.32.0 or newer. This kit's strict preflight
requires the latest installed patch, so update AWS CLI before continuing.

```bash
aws login --profile aws-root-bootstrap
```

When the browser opens, sign in with the AWS **account root** email and MFA—not
an IAM user. Keep this profile name separate and obvious. Do not name it
`default`.

### 3. Prove which AWS identity the terminal will use

```bash
aws sts get-caller-identity --profile aws-root-bootstrap
```

Stop unless `Account` exactly matches the written-down account ID and `Arn`
ends in `:root`. A wrong account is not close enough.

### 4. Run the one-time setup

Interactive form—the script asks for the IAM user name:

```bash
./scripts/first_run_setup.sh \
  --root-profile aws-root-bootstrap \
  --region us-west-2
```

Fully named form—the local profile defaults to the user name:

```bash
./scripts/first_run_setup.sh \
  --root-profile aws-root-bootstrap \
  --region us-west-2 \
  --service-account aws-envbuilder-automation
```

Explicit profile form:

```bash
./scripts/first_run_setup.sh \
  --root-profile aws-root-bootstrap \
  --region us-west-2 \
  --service-account aws-envbuilder-automation \
  --service-profile customer-demo-deployer
```

Read the displayed account number and names. Type the exact confirmation only
when all are correct. Do not close the terminal while rollback is in progress.

### 5. End the root browser session

After the helper reports success:

```bash
aws logout --profile aws-root-bootstrap
```

Close any root console tab. In the AWS root security-credentials page, verify
that no root access key exists. Do not delete the new IAM user's key; that is
the credential the local service profile now uses.

### 6. Prove the handoff

Do not pass `--profile` in this check:

```bash
./scripts/workspace.sh preflight --region us-west-2
```

The helper reads `.workspace/service-account-profile` and should print an ARN
ending in `:user/YOUR_SERVICE_ACCOUNT`. This is the practical “login as the new
user” handoff: future AWS commands in this kit select the new AWS CLI profile.
It does not change the person logged into macOS/Linux and does not keep the root
session alive.

## Normal operation and the root failsafe

After first run, use ordinary commands without repeating a profile:

```bash
./scripts/bootstrap_backend.sh --region us-west-2 --project demo --environment dev
./scripts/workspace.sh plan --region us-west-2
./scripts/workspace.sh apply --region us-west-2
```

An explicit `--profile NAME` always overrides the saved local profile. Regardless
of how credentials are selected, AWS-facing helpers call STS and refuse an AWS
root ARN.

The exceptional override looks like this:

```bash
./scripts/workspace.sh preflight \
  --profile aws-root-bootstrap \
  --region us-west-2 \
  --run-as-root
```

The override applies to that command only. It does not modify the saved profile,
does not suppress the large warning, and does not bypass an apply/destroy exact
confirmation. Root cannot be evaluated by IAM's principal-policy simulator, so
a root-override preflight can prove reads but cannot provide a least-privilege
simulation. Do not use the flag for routine Terraform work.

## If first run says setup already exists

The marker is deliberately a failsafe, not an inconvenience. Do not delete it
just to make an error disappear. First inspect:

```bash
sed -n '1p' .workspace/service-account-profile
aws configure list-profiles
aws sts get-caller-identity --profile THE_PRINTED_PROFILE
```

If that identity is correct, continue normal operation. If it is wrong, stop
and have the AWS account owner audit the IAM user, its key age, attached policy,
CloudTrail history, and the local credentials/config files before deciding
whether to replace anything.

## Key rotation and removal

Normal deployment and ordinary workspace destroy do not automatically rotate or
delete a successful service account because doing so can strand Terraform state
or another project using the same profile. The separate full-project
self-destruct sequence can retire the exact bootstrap user only after no managed
runtime object remains in state, exact ownership/credential-shape checks pass, a
different cleanup identity proves delete permission, and the operator types an
account-specific confirmation. Read [SELF_DESTRUCT.md](SELF_DESTRUCT.md) before
considering it.

For routine rotation, the AWS account owner must still establish a schedule,
prove the replacement profile works, and only then deactivate/delete the old
key. Never create a second key and forget the first.

If a credential is exposed, stop using it immediately, deactivate it in IAM,
review CloudTrail, create a replacement through an approved administrator
process, update the protected AWS credentials file, and delete the exposed key.
Do not paste the key into a ticket, chat, commit, or troubleshooting transcript.

## Official AWS references

- [AWS CLI browser login with temporary console credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [AWS guidance for securing access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/securing_access-keys.html)
- [IAM users, credentials, and service-account use](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html)
- [IAM roles and temporary credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
