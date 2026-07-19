# AWS Stateless Development Workspace

This repository is a reusable, deliberately cautious starter kit for running a
containerized web application on replaceable Amazon EC2 instances. Terraform
creates the AWS resources. Small Bash and Python helpers check the operator's
computer, credentials, permissions, application files, projected cost, logs,
and approval before Terraform is allowed to change AWS.

No AWS resource is created merely by downloading this repository or running
the local `validate` command.

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
8. Encrypted root disks, required IMDSv2, security groups, and least-purpose
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
./scripts/workspace.sh COMMAND [--profile PROFILE_NAME] [--region AWS_REGION]
```

- `COMMAND` is one action from the table below.
- `--profile` selects the named AWS CLI login. It is optional only when the
  default AWS credential chain is intentionally configured.
- `--region` selects the AWS Region. If omitted, it defaults to `us-west-2`.
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
./scripts/bootstrap_backend.sh [--profile PROFILE_NAME] [--region AWS_REGION] [--project PROJECT_NAME] [--environment ENVIRONMENT_NAME]
./scripts/inspect_app.sh APPLICATION_DIRECTORY [--json]
./scripts/publish_app.sh APPLICATION_DIRECTORY [--profile PROFILE_NAME] [--region AWS_REGION] [--tag IMAGE_TAG]
./scripts/cost_estimate.py [--instances INSTANCE_COUNT]
./scripts/rotate_logs.sh
```

Examples with actual values:

```bash
# One-time protected state storage setup. This changes AWS after confirmation.
./scripts/bootstrap_backend.sh \
  --profile company-dev \
  --region us-west-2 \
  --project customer-demo \
  --environment dev

# Inspect an app directory without changing AWS. Add --json for machine output.
./scripts/inspect_app.sh /Users/your-name/projects/customer-app --json

# Build and push an approved app image after the infrastructure exists.
./scripts/publish_app.sh /Users/your-name/projects/customer-app \
  --profile company-dev \
  --region us-west-2 \
  --tag release-2026-07-19

# Recalculate the estimate for two continuously running instances.
./scripts/cost_estimate.py --instances 2

# Apply the documented local log age/count limits immediately.
./scripts/rotate_logs.sh
```

All helpers return exit code `0` when they finish successfully and a nonzero
code when they block or fail. Complete output is copied into `logs/`; error-run
logs are retained longer than successful-run logs. There is deliberately no
general `--yes` switch. Billable or destructive operations require the exact
confirmation phrase displayed at runtime.

## The safe path from zero to a running workspace

The examples below assume macOS or Linux, a terminal opened in this repository,
and an AWS account whose owner has provided an IAM user or role. Do **not** use
the AWS account root user for daily deployment work.

### Step 1: validate the downloaded code without contacting AWS

Run:

```bash
./scripts/workspace.sh validate
```

This checks formatting, shell syntax, Python tests, and Terraform structure. It
does not create, update, or delete AWS resources. If a required program is
missing, follow [the workstation setup guide](docs/WORKSTATION_SETUP.md).

### Step 2: sign in to AWS safely

This computer currently needs an AWS login. Prefer a short-lived browser login:

```bash
aws configure sso
aws sso login --profile YOUR_PROFILE_NAME
```

If the account supports the newer AWS CLI login flow, this may instead work:

```bash
aws login
```

Never paste a secret access key into this repository, a Terraform file, a chat,
or a shell command that will be logged. If the organization only provides
access keys, run `aws configure --profile YOUR_PROFILE_NAME` interactively and
store the values only in the AWS CLI's protected credential store.

### Step 3: copy and edit the small settings file

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Open `terraform/terraform.tfvars` in a text editor. At minimum, choose a short
lowercase `project_name`, confirm `aws_region`, and review the allowed inbound
network ranges. This real settings file is intentionally excluded from Git.

### Step 4: prove the login and inspect permissions

Replace `YOUR_PROFILE_NAME` below with the profile created in Step 2:

```bash
./scripts/workspace.sh preflight --profile YOUR_PROFILE_NAME --region us-west-2
```

The check is read-only. It identifies the account and caller, tests common read
operations, and asks IAM's policy simulator whether the caller appears able to
create and delete every resource in this build. Policy simulation cannot see
every organization-level restriction; [the permissions guide](docs/PERMISSIONS.md)
explains that limitation and lists the actions.

### Step 5: create a protected Terraform state bucket

Terraform state is the inventory Terraform uses to remember what it owns. Losing
it is dangerous. Create its small, encrypted, versioned S3 bucket once:

```bash
./scripts/bootstrap_backend.sh \
  --profile YOUR_PROFILE_NAME \
  --region us-west-2 \
  --project demo \
  --environment dev
```

The script displays what it will do and requires an exact confirmation. The
state bucket is deliberately *not* deleted by the normal workspace teardown.

### Step 6: preview the exact AWS proposal

```bash
./scripts/workspace.sh plan --profile YOUR_PROFILE_NAME --region us-west-2
```

Read the entire Terraform summary. A plus sign means "create," a tilde means
"change," and a minus sign means "delete." The saved proposal is
`terraform/workspace.tfplan`; it is not committed to Git.

### Step 7: create the resources only after approving cost

```bash
./scripts/workspace.sh apply --profile YOUR_PROFILE_NAME --region us-west-2
```

The helper creates a fresh plan, displays it again, prints a large red cost
warning, and requires the exact phrase shown on screen. Terraform then applies
only that saved plan. When complete, the command prints the application URL.

### Step 8: attach an application

The application must contain a `Dockerfile`, a `.dockerignore`, and an HTTP
health endpoint. First inspect it without changing AWS:

```bash
./scripts/inspect_app.sh /absolute/path/to/application
```

Then build and push it. Pushing changes ECR and therefore requires confirmation:

```bash
./scripts/publish_app.sh /absolute/path/to/application \
  --profile YOUR_PROFILE_NAME \
  --region us-west-2
```

The script records the immutable image digest in a local ignored settings file.
Run `plan`, read the instance-replacement proposal, and run `apply`. Full rules
and examples are in [the application integration guide](docs/APP_INTEGRATION.md).

### Step 9: inspect or remove the workspace

```bash
# Show the URL and current Auto Scaling instances.
./scripts/workspace.sh status --profile YOUR_PROFILE_NAME --region us-west-2

# Preview and then permanently remove the application workspace.
./scripts/workspace.sh destroy --profile YOUR_PROFILE_NAME --region us-west-2
```

Destroy requires a separate exact phrase and uses a saved destroy plan. It
removes the VPC, instances, load balancer, application images, and runtime logs.
It keeps the separate Terraform state bucket so past state versions remain
recoverable. [The teardown section](docs/TROUBLESHOOTING.md#safe-teardown) explains
how to verify the billable resources are gone.

## Logs and retention

Every helper run records its complete terminal output beneath `logs/`:

- successful local runs: 14 days, at most 20 files;
- failed local runs: 90 days, at most 100 files;
- routine CloudWatch logs: 14 days;
- bootstrap error logs: 90 days;
- ALB access logs in S3: 30 days.

Log rotation runs automatically at the start of every helper. It can also be
run manually with `./scripts/rotate_logs.sh`. Logs can contain account IDs,
resource names, and application output, so they are excluded from Git. The
helpers never deliberately log secret keys or session tokens.

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
