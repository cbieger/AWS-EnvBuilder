# AWS Stateless Development Workspace

This repository is a reusable, deliberately cautious starter kit for running a
containerized web application on replaceable Amazon EC2 instances. Terraform
creates the AWS resources. Small Bash and Python helpers check the operator's
computer, credentials, permissions, application files, projected cost, logs,
and approval before Terraform is allowed to change AWS.

No AWS resource is created merely by downloading this repository or running
the local `validate` command.

New accounts use a guarded one-time identity handoff: AWS account root creates
one dedicated IAM service account, then every routine AWS command refuses root
unless the operator explicitly adds `--run-as-root`. Here, “root” always means
the AWS account root identity—not `sudo` or the computer's root user. Read the
[literal first-run guide](docs/FIRST_RUN.md) before creating that identity.

<p><font color="red" size="6"><strong>THIS WORKSPACE IS NOT GUARANTEED TO BE FREE. THE DEFAULT LOW-TRAFFIC BUILD IS ESTIMATED AT ABOUT US$1.40 PER DAY (ABOUT US$42 PER 30-DAY MONTH) IN US-WEST-2, BEFORE TAX, HEAVY TRAFFIC, OR UNUSUAL LOG VOLUME.</strong></font></p>

AWS prices and Free Tier rules change. Read [the cost guide](docs/COSTS.md)
before approving a deployment. The scripts repeat the warning immediately
before any billable infrastructure is created.

## What this creates

The default deployment creates:

1. One isolated VPC in one AWS Region.
2. Two public subnets in separate Availability Zones.
3. One internet-facing Application Load Balancer (ALB).
4. An Auto Scaling Group with one `t3.micro` Amazon Linux 2023 EC2 instance.
   The group may grow to two instances when CPU utilization is high.
5. No SSH port. Administrators connect through AWS Systems Manager Session
   Manager instead.
6. An Amazon ECR repository where a project-specific container image can live.
7. CloudWatch log groups with 14-day routine retention and 90-day error
   retention, plus an S3 bucket for 30 days of ALB request logs.
8. Three account-wide monthly AWS Budgets that email on actual or forecast
   gross spend above approximately $0.01, $1, and $5.
9. Encrypted root disks, required IMDSv2, security groups, and least-purpose
   instance permissions.

The instances are *stateless*: an instance can be terminated and replaced
without losing application data. Therefore, the application must not store
uploads, sessions, databases, or irreplaceable files on its local disk. Add a
managed database or object store as a separate, deliberately designed module.

See [the architecture guide](docs/ARCHITECTURE.md) for a plain-language tour.

## Command syntax and usage reference

Run every command below from the repository's top-level directory—the folder
that contains this README. Text written as `YOUR_SOMETHING` is a placeholder:
replace it with your own value and do not type the angle brackets sometimes
used in technical documentation.

The main command has this shape:

```text
./scripts/workspace.sh COMMAND [--profile PROFILE_NAME] [--region AWS_REGION] [--run-as-root]
```

- `COMMAND` is one action from the table below.
- `--profile` selects the named AWS CLI login. If omitted after first run, the
  ignored local service-profile marker is selected automatically.
- `--region` selects the AWS Region. If omitted, it defaults to `us-west-2`.
- `--run-as-root` is an exceptional one-command override of the AWS-root block.
  It never bypasses cost or destruction confirmation.
- Square brackets in the syntax mean "optional." Do not type the brackets.
- Run `./scripts/workspace.sh help` whenever you need the short built-in help.

| Command | What it does | Contacts AWS? | Can change AWS? |
| --- | --- | --- | --- |
| `help` | Prints the built-in command guide. | No | No |
| `validate` | Checks Terraform formatting/structure, Bash syntax, and Python tests. | No | No |
| `cost` | Prints the documented conservative estimate. | No | No |
| `preflight` | Checks installed tools, AWS login, Region access, and expected IAM permissions. | Yes, read-only calls | No |
| `init` | Connects Terraform to the previously created S3 state backend. | Yes | Normally no; Terraform may download providers locally |
| `plan` | Produces and displays a saved proposal named `workspace.tfplan`. | Yes | No infrastructure change |
| `apply` | Rebuilds the proposal, requests exact cost approval, and creates or updates the workspace. | Yes | **Yes** |
| `status` | Displays the application URL and current Auto Scaling instances. | Yes | No |
| `logs` | Follows the previous hour of application logs; press Control-C to stop. | Yes | No |
| `destroy` | Produces a destroy proposal, requests exact approval, and removes runtime resources. | Yes | **Yes—destructive** |

Common examples:

```bash
# Local-only checks. This is the safest first command.
./scripts/workspace.sh validate

# Read-only AWS readiness check.
./scripts/workspace.sh preflight --profile company-dev --region us-west-2

# Preview, create, inspect, and eventually remove the workspace.
./scripts/workspace.sh plan --profile company-dev --region us-west-2
./scripts/workspace.sh apply --profile company-dev --region us-west-2
./scripts/workspace.sh status --profile company-dev --region us-west-2
./scripts/workspace.sh logs --profile company-dev --region us-west-2
./scripts/workspace.sh destroy --profile company-dev --region us-west-2
```

The supporting commands use these forms:

```text
./scripts/first_run_setup.sh [--root-profile ROOT_PROFILE] [--region AWS_REGION] [--service-account IAM_USER] [--service-profile LOCAL_PROFILE]
./scripts/bootstrap_backend.sh [--profile PROFILE_NAME] [--region AWS_REGION] [--project PROJECT_NAME] [--environment ENVIRONMENT_NAME] [--run-as-root]
./scripts/inspect_app.sh APPLICATION_DIRECTORY [--json]
./scripts/publish_app.sh APPLICATION_DIRECTORY [--profile PROFILE_NAME] [--region AWS_REGION] [--tag IMAGE_TAG] [--run-as-root]
./scripts/cost_estimate.py [--instances INSTANCE_COUNT]
./scripts/rotate_logs.sh
./scripts/package.sh [--output DIRECTORY] [--version LABEL]
./scripts/self_destruct.sh [--review-only | --execute --expected-account ACCOUNT_ID] [--profile PROFILE_NAME] [--region AWS_REGION] [--project PROJECT_NAME] [--environment ENVIRONMENT_NAME] [--delete-state-bucket] [--delete-service-account] [--service-account IAM_USER] [--service-profile LOCAL_PROFILE] [--run-as-root]
```

Examples with actual values:

```bash
# One-time AWS account-root handoff to the service account. This changes IAM.
aws login --profile aws-root-bootstrap
./scripts/first_run_setup.sh \
  --root-profile aws-root-bootstrap \
  --region us-west-2 \
  --service-account aws-envbuilder-automation
aws logout --profile aws-root-bootstrap

# One-time protected state storage setup. This changes AWS after confirmation.
./scripts/bootstrap_backend.sh \
  --region us-west-2 \
  --project customer-demo \
  --environment dev

# Inspect an app directory without changing AWS. Add --json for machine output.
./scripts/inspect_app.sh /Users/your-name/projects/customer-app --json

# Build and push an approved app image after the infrastructure exists.
./scripts/publish_app.sh /Users/your-name/projects/customer-app \
  --region us-west-2 \
  --tag release-2026-07-19

# Recalculate the estimate for two continuously running instances.
./scripts/cost_estimate.py --instances 2

# Apply the documented local log age/count limits immediately.
./scripts/rotate_logs.sh

# Create a portable, source-only release and SHA-256 checksum under dist/.
./scripts/package.sh --version 1.0.0

# Inventory account assets and preview complete teardown without deleting.
./scripts/self_destruct.sh \
  --review-only \
  --region us-west-2 \
  --project customer-demo \
  --environment dev
```

All helpers return exit code `0` when they finish successfully and a nonzero
code when they block or fail. Complete output is copied into `logs/`; error-run
logs are retained longer than successful-run logs. There is deliberately no
general `--yes` switch. Billable or destructive operations require the exact
confirmation phrase displayed at runtime.

## The safe path from zero to a running workspace

The examples below assume macOS or Linux, a terminal opened in this repository,
and permission from the AWS account owner to perform the one-time identity
handoff. Do **not** use the AWS account root user for daily deployment work.

### Step 1: validate the downloaded code without contacting AWS

Run:

```bash
./scripts/workspace.sh validate
```

This checks formatting, shell syntax, Python tests, and Terraform structure. It
does not create, update, or delete AWS resources. If a required program is
missing, follow [the workstation setup guide](docs/WORKSTATION_SETUP.md).

### Step 2: perform the one-time AWS root-to-service-account handoff

“Root” in this step means AWS account root. Do not use `sudo`. Open temporary
browser credentials under a clearly named profile, verify the ARN ends in
`:root`, and run the guarded setup:

```bash
aws login --profile aws-root-bootstrap
aws sts get-caller-identity --profile aws-root-bootstrap
./scripts/first_run_setup.sh \
  --root-profile aws-root-bootstrap \
  --region us-west-2
```

The setup prompts for the new IAM service-account name, displays the proposal,
and requires `CREATE AWS SERVICE ACCOUNT`. It creates one service user and one
long-term key, writes that key directly into the protected AWS CLI credentials
file without displaying it, proves the new identity's permissions, and saves
only its local profile name under ignored `.workspace/`.

Terraform does not perform this handoff because an access key created by
Terraform would be retained in Terraform state, and Terraform cannot safely
change the credentials of its already-running provider midway through a run.
The setup helper finishes before Terraform begins. AWS recommends temporary
roles or IAM Identity Center instead of long-term keys where practical; see the
[first-run guide](docs/FIRST_RUN.md) for the tradeoff and exact recovery steps.

### Step 3: end root and prove automatic service-account selection

```bash
aws logout --profile aws-root-bootstrap
./scripts/workspace.sh preflight --region us-west-2
```

The printed principal must end in `:user/YOUR_SERVICE_ACCOUNT`, not `:root`.
Future helpers use the saved service profile when `--profile` is omitted. An
explicit profile still wins. If any AWS-facing command detects root, it fails;
only a deliberate per-command `--run-as-root` override permits it.

### Step 4: copy and edit the small settings file

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Open `terraform/terraform.tfvars` in a text editor. At minimum, choose a short
lowercase `project_name`, enter at least one monitored `budget_alert_emails`
address, confirm `aws_region`, and review the allowed inbound network ranges.
This real settings file is intentionally excluded from Git.

The cost budgets monitor the whole AWS account, not only resources carrying this
project's tags. They notify; they do not stop or delete resources. Also verify
that **Receive AWS Free Tier alerts** is enabled under Billing and Cost
Management → Billing preferences so AWS can send its service-specific 85%
Free Tier usage warnings.

### Step 5: prove the login and inspect permissions

```bash
./scripts/workspace.sh preflight --region us-west-2
```

The check is read-only. It identifies the account and caller, tests common read
operations, and asks IAM's policy simulator whether the caller appears able to
create and delete every resource in this build. Policy simulation cannot see
every organization-level restriction; [the permissions guide](docs/PERMISSIONS.md)
explains that limitation and lists the actions.

### Step 6: create a protected Terraform state bucket

Terraform state is the inventory Terraform uses to remember what it owns. Losing
it is dangerous. Create its small, encrypted, versioned S3 bucket once:

```bash
./scripts/bootstrap_backend.sh \
  --region us-west-2 \
  --project demo \
  --environment dev
```

The script displays what it will do and requires an exact confirmation. The
state bucket is deliberately *not* deleted by the normal workspace teardown.

### Step 7: preview the exact AWS proposal

```bash
./scripts/workspace.sh plan --region us-west-2
```

Read the entire Terraform summary. A plus sign means "create," a tilde means
"change," and a minus sign means "delete." The saved proposal is
`terraform/workspace.tfplan`; it is not committed to Git.

### Step 8: create the resources only after approving cost

```bash
./scripts/workspace.sh apply --region us-west-2
```

The helper creates a fresh plan, displays it again, prints a large red cost
warning, and requires the exact phrase shown on screen. Terraform then applies
only that saved plan. When complete, the command prints the application URL.

### Step 9: attach an application

The application must contain a `Dockerfile`, a `.dockerignore`, and an HTTP
health endpoint. First inspect it without changing AWS:

```bash
./scripts/inspect_app.sh /absolute/path/to/application
```

Then build and push it. Pushing changes ECR and therefore requires confirmation:

```bash
./scripts/publish_app.sh /absolute/path/to/application \
  --region us-west-2
```

The script records the immutable image digest in a local ignored settings file.
Run `plan`, read the instance-replacement proposal, and run `apply`. Full rules
and examples are in [the application integration guide](docs/APP_INTEGRATION.md).

### Step 10: inspect or remove the workspace

```bash
# Show the URL and current Auto Scaling instances.
./scripts/workspace.sh status --region us-west-2

# Preview and then permanently remove the application workspace.
./scripts/workspace.sh destroy --region us-west-2
```

Destroy requires a separate exact phrase and uses a saved destroy plan. It
removes the VPC, instances, load balancer, application images, and runtime logs.
It also removes this workspace's three Terraform-managed budget definitions;
AWS's native Free Tier alerts remain an account preference. It keeps the separate
Terraform state bucket so past state versions remain recoverable. [The teardown
section](docs/TROUBLESHOOTING.md#safe-teardown) explains how to verify the
billable resources are gone.

For retiring an entire attached project, use the separate self-destruct sequence.
Its default review mode inventories account assets, prints a deletion-only saved
plan, and changes nothing. After independent review, execute mode can remove the
Terraform runtime and can optionally remove the exact versioned state backend
and verified first-run IAM service account. It never turns the broad inventory
into broad account deletion. Follow [the full self-destruct guide](docs/SELF_DESTRUCT.md)
before using it.

## Logs and retention

Every helper run records its complete terminal output beneath `logs/`:

- successful local runs: 14 days, at most 20 files;
- failed local runs: 90 days, at most 100 files;
- account inventories and deletion manifests: 365 days, at most 20 JSON files;
- routine CloudWatch logs: 14 days;
- bootstrap error logs: 90 days;
- ALB access logs in S3: 30 days.

Log rotation runs automatically at the start of every helper. It can also be
run manually with `./scripts/rotate_logs.sh`. Logs can contain account IDs,
resource names, and application output, so they are excluded from Git. The
helpers never deliberately log secret keys or session tokens.

## Reusable package

Run `./scripts/package.sh --version LABEL` to create a source-only `.tar.gz` and
matching SHA-256 file under ignored `dist/`. The packager uses a narrow allowlist
and excludes Git history, local identity markers, credentials, state, plans,
real variables, providers, logs, and unrelated workspace files. Follow the
[packaging guide](docs/PACKAGING.md) to verify, extract, and attach the kit to
another application repository.

## Git policy

This project is connected to
`https://github.com/cbieger/AWS-EnvBuilder.git`. Infrastructure changes should
be committed to a review branch and merged into `main` only after another
person reviews the pull request and records a `+1`. Before every commit, review:

```bash
git status --short
git diff --check
```

Commit source and documentation, but never commit state, plan files, real
variable files, backend settings, credentials, or runtime logs. The included
`.gitignore` blocks those common mistakes. Never use an unreviewed `git add .`
inside this shared workspace. The exact scope, exclusions, and review procedure
are in [the Git publication plan](docs/GIT_COMMIT_PLAN.md).
