# Ownership-safe self-destruct procedure

<p><font color="red" size="6"><strong>SELF-DESTRUCT PERMANENTLY DELETES AWS RESOURCES. TERRAFORM RUNTIME DATA, CONTAINER IMAGES, LOGS, BUDGET DEFINITIONS, STATE HISTORY, AND AN IAM USER MAY BE IRRECOVERABLE. REVIEW MODE FIRST. NEVER GUESS AN ACCOUNT ID, PROJECT, ENVIRONMENT, PROFILE, OR CONFIRMATION PHRASE.</strong></font></p>

This guide is deliberately literal. The safe sequence is **review, stop, inspect,
obtain approval, then execute a new run**. Merely running the command without
`--execute` does not delete anything.

## What the command can and cannot inventory

AWS does not provide one universal API that lists every asset in every service,
Region, and account. The read-only inventory therefore combines:

- every tagged or previously tagged resource returned by the Resource Groups
  Tagging API in the selected Region;
- a second tag query for the exact `Application` and `Environment` values;
- native lists for EC2 compute/networking, Auto Scaling, Application Load
  Balancing, ECR, CloudWatch Logs, S3, IAM, and AWS Budgets; and
- the exact Terraform state inventory and saved destroy plan.

The tagging API does not return a resource that has never had tags. Assets in
other Regions, other accounts, or AWS services outside the native census may
therefore be absent. The script says this in both the terminal and retained JSON
report. An incomplete AWS read blocks deletion; it is never treated as an empty
asset list. See the [AWS `get-resources` command reference](https://docs.aws.amazon.com/cli/latest/reference/resourcegroupstaggingapi/get-resources.html).

## Deletion boundaries

The inventory is broad. Automatic deletion is intentionally narrow.

| Scope | Default | Proof required before the confirmation prompt |
| --- | --- | --- |
| Terraform-managed runtime resources | Proposed for deletion | Exact backend name/key/Region, readable state, and a saved plan containing only delete/read/no-op actions |
| Versioned Terraform state bucket | **KEEP** | Explicit `--delete-state-bucket`, deterministic bucket name, exact owner account, exact bootstrap tags, versioning enabled, and no MFA Delete or Object Lock |
| First-run IAM service account | **KEEP** | Explicit `--delete-service-account`, a working local service profile that proves the IAM-user identity, exact bootstrap tags and credential shape, a different cleanup identity, and IAM deletion permission simulation unless using the explicit root exception |
| Unrelated or ambiguous AWS assets | **NEVER AUTO-DELETE** | Listed for the operator only; there is no flag that turns account-wide inventory into account-wide deletion |

Deleting a versioned S3 bucket requires deletion of every object version and
delete marker, not merely the current object. The script processes those items
in bounded batches and stops on any reported deletion error. Read the
[S3 version listing](https://docs.aws.amazon.com/cli/latest/reference/s3api/list-object-versions.html),
[version deletion explanation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html),
and [`delete-objects` reference](https://docs.aws.amazon.com/cli/latest/reference/s3api/delete-objects.html).

The AWS CLI cannot delete an IAM user until its credentials, policies, and
memberships have been removed. AWS documents that cleanup as manual and
irreversible. This sequence will remove only the exact bootstrap shape it knows;
an unexpected console login, managed policy, group, MFA device, certificate,
SSH key, service credential, or inline policy blocks automatic deletion. See
[AWS's IAM user removal procedure](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_remove.html).

## Before review mode

Complete every item below:

1. Open a terminal in the repository folder containing `README.md`.
2. Confirm nobody else is running Terraform against this state.
3. Confirm `terraform/backend.hcl` belongs to the workspace being removed.
4. Confirm the ignored real Terraform settings are present and correct.
5. Know the exact 12-digit AWS account ID, Region, project, and environment.
6. Choose a cleanup AWS CLI profile. Routine runtime-only cleanup can use the
   service profile. Deleting that same IAM service account requires a different
   administrator or AWS-root cleanup profile.
7. Ensure any records, images, or logs requiring preservation have been exported
   under an approved retention procedure. This starter kit treats its runtime as
   disposable.
8. Run local validation:

   ```bash
   ./scripts/workspace.sh validate
   ```

9. Prove the selected AWS identity without changing AWS:

   ```bash
   aws sts get-caller-identity --profile cleanup-admin
   ```

The returned `Account` must be the intended account. Do not proceed when it is
merely familiar-looking.

## Phase 1: inventory and review only

Run this first, replacing all example values:

```bash
./scripts/self_destruct.sh \
  --review-only \
  --profile cleanup-admin \
  --region us-west-2 \
  --project stub-app \
  --environment dev
```

`--review-only` is also the default when neither mode is provided. Stating it
explicitly makes copied terminal history unambiguous.

This review run performs read calls, initializes the proven Terraform backend,
creates a saved destroy plan in a protected temporary directory, prints the
account inventory, prints the proposed deletion manifest, and exits. It does
not apply the plan and does not call an AWS delete operation.

To review optional state and service-account removal, add the intended flags to
the review command. Their ownership and permission checks will run, but nothing
will be deleted:

```bash
./scripts/self_destruct.sh \
  --review-only \
  --profile cleanup-admin \
  --region us-west-2 \
  --project stub-app \
  --environment dev \
  --delete-state-bucket \
  --delete-service-account \
  --service-account aws-envbuilder-automation \
  --service-profile aws-envbuilder-automation
```

Inspect all of the following before approving execution:

1. **Account and caller:** are the 12-digit account and ARN exactly correct?
2. **Ownership request:** are `Application`, `Environment`, and Region correct?
3. **Every inventory section:** does it show unknown assets, default resources,
   another team's resources, or anything requiring separate manual review?
4. **Terraform addresses:** is every proposed delete part of this workspace?
5. **Saved Terraform plan:** are there only deletions? The script blocks a create
   or update, but the operator must still judge whether each deletion is wanted.
6. **State action:** does the manifest say `KEEP` unless permanent removal of all
   state history was deliberately requested?
7. **Service-account action:** does it say `KEEP` unless the exact one-time
   bootstrap user is deliberately being retired?
8. **Retained reports:** open the `*-before.json` and
   `*-deletion-manifest.json` files named by the command under `logs/inventory/`.
9. **Independent approval:** have a second person compare the terminal output,
   JSON manifest, and Terraform plan. Record approval outside the local logs.

Inventory and manifests use file mode `0600`, are excluded from Git/packages,
and are rotated after 365 days or 20 JSON files. Copy them to approved audit
storage first if a longer retention requirement applies.

## Phase 2: execute runtime removal

Rerun from the beginning. Do not attempt to reuse the temporary plan from review
mode; a fresh plan and inventory catch changes that happened during review.

```bash
./scripts/self_destruct.sh \
  --execute \
  --expected-account 123456789012 \
  --profile cleanup-admin \
  --region us-west-2 \
  --project stub-app \
  --environment dev
```

This example removes Terraform-managed runtime resources and keeps both the
state bucket and bootstrap service account. The script will display the entire
proposal again and then require this shape of exact phrase:

```text
SELF DESTRUCT 123456789012 stub-app dev
```

Type the phrase only after the second review is still correct. Any mismatch
ends the run before Terraform apply or an AWS delete call. A saved Terraform
plan is applied exactly as displayed; HashiCorp documents this saved-plan mode
in the [`terraform apply` reference](https://developer.hashicorp.com/terraform/cli/commands/apply).

The order is fixed:

1. prove tools, login, Region, ordinary Terraform permissions, account, backend,
   and deletion-only saved plan;
2. inventory account/Region assets and validate each optional deletion scope;
3. print and retain the deletion manifest;
4. require the exact phrase;
5. apply the saved Terraform destroy plan;
6. prove Terraform state contains no remaining managed resources (read-only
   data-source records are harmless and may remain);
7. only then delete the selected state bucket;
8. only after that delete the selected bootstrap IAM user/local profile; and
9. create and print a post-delete inventory.

If a managed runtime object remains in state, the state bucket and service
account remain for recovery.

## Phase 2 alternative: full standalone-project cleanup

This removes runtime, state history, and the bootstrap IAM user. It does **not**
close the AWS account and does **not** delete unrelated account resources.

The service user cannot safely delete itself. Start a separate, short-lived
administrator or AWS-root session. AWS account root is refused unless the same
invocation contains `--run-as-root`; that flag does not bypass inventory,
ownership checks, the saved plan, or exact confirmation.

```bash
aws login --profile aws-root-cleanup
aws sts get-caller-identity --profile aws-root-cleanup

./scripts/self_destruct.sh \
  --execute \
  --expected-account 123456789012 \
  --profile aws-root-cleanup \
  --run-as-root \
  --region us-west-2 \
  --project stub-app \
  --environment dev \
  --delete-state-bucket \
  --delete-service-account \
  --service-account aws-envbuilder-automation \
  --service-profile aws-envbuilder-automation

aws logout --profile aws-root-cleanup
```

Here, “root” means the AWS account-root ARN—not `sudo`, the macOS root account,
or the Linux root account. Prefer a short-lived approved administrator role when
one is available. Root cannot be evaluated by IAM's simulator, so the script
prints that limitation under the explicit exception.

`--service-profile` identifies the exact local AWS credentials/config sections
to verify and remove after the IAM user is successfully deleted. If it is
omitted, the ignored first-run marker must supply it. `--service-account` is only
an additional name cross-check; a user name by itself is not ownership proof.
The marker is removed only when it names that same profile. Other local profiles
are not rewritten or removed.

## If anything fails

Do not delete random resources manually just to make a red error disappear.

- **Before confirmation:** no approved deletion has occurred. Fix the first
  error and repeat review mode.
- **Terraform apply failed:** keep the backend and service account, resolve the
  first dependency/permission error, then run a fresh review.
- **State bucket cleanup failed:** Terraform runtime may already be gone, but
  version history remains partially or fully available. Do not delete the IAM
  user until the bucket is reconciled if it is needed for access.
- **IAM user cleanup failed:** use the retained manifest and IAM user removal
  guide to reconcile only that exact user. Do not remove other users or roles.
- **Post-inventory is incomplete:** the command warns rather than deleting more.
  Repeat read-only inventory or inspect the named service consoles manually.

Failure transcripts remain under `logs/errors/` for 90 days/100 files. Account
inventories and manifests remain under `logs/inventory/` for 365 days/20 files.

## Final operator verification

Immediately after completion and again the next day:

1. Read the retained after-inventory and investigate ownership-tag survivors.
2. Check EC2 instances, Auto Scaling Groups, load balancers, EBS volumes, Elastic
   IP/public IPv4 usage, ECR, CloudWatch Logs, S3, AWS Budgets, and IAM.
3. Repeat equivalent checks in every other enabled Region; the command inventories
   only the selected Region plus global IAM/S3/Budgets views.
4. Review Billing and Cost Explorer. AWS billing data is delayed, so a zero
   immediate change does not prove charges have stopped.
5. Confirm the temporary cleanup/root session is logged out.
6. Preserve reports under the organization's retention rules.

This sequence is a project teardown, not an AWS-account closure utility. Any
asset that was inventoried but not proven to be owned by this Terraform state or
the two exact optional bootstrap scopes remains for deliberate manual handling.
