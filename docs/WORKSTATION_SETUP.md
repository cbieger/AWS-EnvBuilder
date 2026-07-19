# Workstation setup and AWS login

This kit supports macOS and Linux. Windows users should run it inside a current
WSL2 Linux distribution; the scripts require Bash process substitution and
standard Unix file permissions.

## Programs and minimum versions

| Program | Minimum | Why it is needed |
|---|---:|---|
| AWS CLI | version 2, latest patch | login and AWS read/write API requests |
| Terraform | 1.10.0 | S3 native lock file and infrastructure planning |
| Python | 3.9.0 | dependency scanner, tests, and cost arithmetic |
| jq | 1.6 | safe JSON parsing in credential/permission checks |
| curl | current OS release | official AWS CLI release check |
| Docker | current supported release | needed only to build/push an application |
| ShellCheck | current | optional deeper shell analysis |

Run `./scripts/workspace.sh validate` for local code checks. Complete
[FIRST_RUN.md](FIRST_RUN.md) before using `preflight` in a new standalone AWS
account; after that handoff, `preflight` automatically selects the saved local
service profile.

## AWS CLI installation or update

Use only the [official AWS CLI v2 installation instructions](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
The preflight compares the installed version with the first version in AWS's
[official v2 changelog](https://github.com/aws/aws-cli/blob/v2/CHANGELOG.rst).
A strict plan/apply stops if it cannot prove the CLI is current.

### macOS

1. Download `AWSCLIV2.pkg` using the link on the official page.
2. Open it and complete the signed installer.
3. Close and reopen the terminal.
4. Run `which aws` and `aws --version`.

Do not download a similarly named installer from a search advertisement or
unofficial mirror.

### Linux

Follow the official x86-64 or ARM steps for the computer's architecture. Verify
the downloaded signature when possible. Updates use the official installer with
its documented `--update` option. Run `aws --version` after installation.

## Terraform installation

Use [HashiCorp's official Terraform installation guide](https://developer.hashicorp.com/terraform/install).
This repository constrains Terraform below 2.0 and the AWS provider below 7.0.
`terraform init -upgrade` selects the newest compatible provider and writes a
checksum lock file. Review and commit that lock file only after Git approval.

## Python, jq, Docker, and ShellCheck

- macOS: use a trusted package manager or the vendor's signed installer.
- Debian/Ubuntu: use the distribution packages for Python, jq, and ShellCheck;
  use Docker's official Engine instructions if the distribution package is old.
- Docker Desktop must be opened and its engine running before `publish_app.sh`.

No Python package installation is needed: the scanner and tests use only the
standard library. Application dependencies are installed inside the Docker build
defined by the application's own Dockerfile.

## Login choices

AWS recommends temporary credentials and roles when practical. This package's
requested standalone first-run path is documented in [FIRST_RUN.md](FIRST_RUN.md):
temporary AWS account-root browser credentials create one IAM service user, then
the package refuses root for ordinary commands. Do not substitute `sudo`; the
guard checks AWS STS identity, not the operating-system user.

The generated service profile uses one long-term access key. Treat the machine
and its AWS shared credentials file as privileged. In an organization, prefer
the short-lived choices below and have an administrator replace the generated
user with a deployment role.

### IAM Identity Center (recommended for an organization)

```bash
aws configure sso
aws sso login --profile YOUR_PROFILE_NAME
aws sts get-caller-identity --profile YOUR_PROFILE_NAME
```

The browser performs authentication. The final command should show the intended
account ID and a non-root assumed-role ARN.

### AWS CLI browser login

Some accounts and current AWS CLI releases support:

```bash
aws login --profile YOUR_PROFILE_NAME
aws sts get-caller-identity --profile YOUR_PROFILE_NAME
```

### Access keys (fallback only)

If an administrator explicitly provides an IAM access key:

```bash
aws configure --profile YOUR_PROFILE_NAME
```

Enter the values only at the hidden prompts. Never put them in:

- `terraform.tfvars`, `backend.hcl`, or any `.tf` file;
- environment files within the Docker build context;
- a script, source file, issue, email, or chat;
- a command line, because shell history and logs can preserve it.

Rotate a key immediately if it appears in any of those places. Never create or
use access keys for the AWS root user.

## How this package selects a profile

The first-run helper records the service account's **profile name only** in
ignored `.workspace/service-account-profile`. It never writes a key inside this
repository. Every AWS-facing helper uses this order:

1. an explicit `--profile NAME`, when supplied;
2. the saved local service-profile marker; then
3. the standard AWS default credential chain when no marker exists.

The selected identity is always checked with STS. An AWS root ARN fails unless
that exact command includes `--run-as-root`. The override does not persist and
does not bypass apply/destroy confirmation.

## What was detected when this kit was generated

On 2026-07-19, the final local review used AWS CLI 2.36.2, Terraform 1.11.4,
Python 3.14.6, and jq 1.7.1. Software and login state can change, so the runtime
preflight—not this historical note—is authoritative.
