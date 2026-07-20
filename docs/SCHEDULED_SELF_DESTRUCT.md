# Scheduled self-destruct: literal operator guide

This optional feature deletes the **Terraform-managed runtime workspace** at an
operator-approved deadline even when the operator's computer is off. It does not
delete the separately bootstrapped S3 state bucket or the first-run IAM service
account. Those retained recovery assets can be reviewed later with the manual
[ownership-safe self-destruct](SELF_DESTRUCT.md).

<p><font color="red" size="6"><strong>SCHEDULED SELF-DESTRUCT IS NOT FREE AND IS
IRREVERSIBLE AFTER TERRAFORM EXECUTION BEGINS. A DEDICATED TWO-WAY AWS SMS NUMBER
CAN REQUIRE REGISTRATION, MONTHLY RENTAL, AND PER-MESSAGE FEES. CODEBUILD AND THE
SUPPORTING AWS SERVICES CAN ALSO COST MONEY.</strong></font></p>

## The five rules to understand first

1. Scheduling is optional. The first `plan` or `apply` asks whether to enable it.
2. The deadline must be at least 13 hours away. That leaves time to apply the
   infrastructure, confirm email, and send every required notice.
3. AWS sends notices 12 hours, 2 hours, 1 hour, 15 minutes, and 5 minutes before
   the deadline. A one-minute scheduler means delivery can be roughly one minute
   after a milestone. AWS/carrier/email delays are also possible.
4. **Email is a duplicate notification channel, not a reply channel.** To cancel,
   reply with the single word `CANCEL` to a warning **SMS** from the enrolled cell
   phone. Capitalization and surrounding spaces are ignored; extra words,
   punctuation, a different phone, or a reply to the email do not cancel.
5. Cancellation is accepted until the CodeBuild job atomically changes the state
   from `TRIGGERED` to `EXECUTING`. Deletion cannot be rolled back after Terraform
   execution begins. Restore/redeploy is the recovery path after that boundary.

## Why an AWS two-way number is required

Sending an ordinary one-way SMS does not provide an authenticated reply path.
AWS End User Messaging SMS supports two-way replies only on an eligible dedicated
origination number with two-way messaging enabled. Sender IDs do not support
two-way replies. The number's inbound messages must already be routed to an SNS
topic in the same AWS account and Region.

This implementation accepts only an **account-owned U.S. toll-free number with
carrier-managed opt-outs**. AWS lists `CANCEL` as a required opt-out keyword for
many long/short-code programs, where it can be handled as an opt-out instead of
reaching the cancellation Lambda. AWS documents that U.S. toll-free numbers use
`STOP` as their only carrier-managed opt-out keyword, leaving the user-required
`CANCEL` reply available to the two-way SNS route. The validator rejects shared,
non-U.S., non-toll-free, or self-managed-opt-out numbers rather than pretending
their cancellation behavior is reliable. See
[required opt-out keywords](https://docs.aws.amazon.com/sms-voice/latest/userguide/keywords-required.html).

This repository deliberately does **not** purchase or register a number. Country,
business identity, campaign, use-case, and recurring-cost decisions belong to the
account owner. Use AWS's official instructions:

- [Request a phone number](https://docs.aws.amazon.com/sms-voice/latest/userguide/phone-numbers-request.html)
- [Set up two-way SMS messaging](https://docs.aws.amazon.com/sms-voice/latest/userguide/two-way-sms.html)
- [Understand the inbound SMS payload](https://docs.aws.amazon.com/sms-voice/latest/userguide/two-way-sms-payload.html)
- [AWS End User Messaging pricing](https://aws.amazon.com/end-user-messaging/pricing/)

Before scheduling, record these two values from AWS:

- the account-owned U.S. toll-free AWS origination number in E.164 form, such as
  `+13125550999`; and
- the complete inbound SNS topic ARN selected in that number's **Two-way SMS**
  configuration, such as
  `arn:aws:sns:us-west-2:123456789012:sms-replies`.

Do not use the operator's personal cell number as the origination number. The
operator cell is the destination; the AWS-owned/rented number is the sender.

## What happens during setup

Run the ordinary preview command from the repository's top folder:

```bash
./scripts/workspace.sh plan --region us-west-2
```

If first-run setup saved a service profile, it is selected automatically. Add
`--profile YOUR_PROFILE` only when intentionally overriding it.

The helper asks:

1. whether scheduling should be enabled;
2. whether to use a duration or a specific local wall-clock time;
3. the number of hours/minutes, or `YYYY-MM-DD HH:MM`;
4. the operator cell number in E.164 format;
5. the operator email address;
6. the dedicated AWS two-way origination number; and
7. the SNS topic ARN receiving replies to that AWS number.

The operator must also confirm that they control the cell number and consent to
the transactional alert sequence. `STOP` is the carrier opt-out keyword for a
U.S. toll-free number: it stops future SMS delivery but **does not cancel the
Terraform teardown**. The operator must use `CANCEL` to cancel teardown. Email
continues as the duplicate channel if the operator separately uses `STOP`.

For a duration, `13 hours and 30 minutes` means 13 hours and 30 minutes from the
moment the question is answered. For a wall-clock deadline, the helper detects an
IANA local timezone such as `America/Chicago`, displays both the local and UTC
result, and requests confirmation. Ambiguous or nonexistent daylight-saving
times are rejected; choose another minute. AWS stores and compares the UTC epoch.

The helper then performs read-only/no-send checks:

- the SNS topic account and Region match the authenticated account/Region;
- the AWS number is account-owned, `ACTIVE`, U.S. `TOLL_FREE`, SMS-capable,
  two-way enabled, and uses carrier-managed opt-outs;
- the number's `TwoWayChannelArn` is the exact supplied SNS topic; and
- AWS accepts a `SendTextMessage --dry-run` from that number to the operator cell.

No validation text is delivered or billed by that dry run. A failed check blocks
the Terraform proposal.

## Review the proposal and apply

The plan includes these schedule-only resources when enabled:

- an EventBridge Scheduler rule that calls a controller once per minute;
- a 128 MiB Lambda controller and a 90-day CloudWatch log group;
- one on-demand DynamoDB table holding the schedule state and sent milestones;
- an SNS topic and pending email subscription;
- a Lambda subscription to the existing two-way SMS reply topic;
- a small CodeBuild project and 90-day log group for deletion-only Terraform;
- short-lived IAM roles/policies for Scheduler, Lambda, and CodeBuild.

Read every create/update/delete line. Then apply only if the account, Region,
deadline, resources, and cost are correct:

```bash
./scripts/workspace.sh apply --region us-west-2
```

The helper shows a fresh saved plan and requires this exact phrase:

```text
I ACCEPT ESTIMATED AWS CHARGES
```

Only after that approval does it upload two content-addressed source ZIP files to
the versioned Terraform state bucket and apply the saved plan. The ZIPs contain
reviewed Terraform/controller/build-helper source only. They exclude contacts,
backend settings, credentials, variables, plans, state, logs, and application
files. Old archive versions follow the state bucket's lifecycle retention.

## Confirm email before the schedule can arm

After apply, AWS SNS sends an email titled similar to **AWS Notification -
Subscription Confirmation**. Open it and choose **Confirm subscription**.

Until that happens, DynamoDB remains `PENDING`, no milestone notice is sent, and
the controller will not start deletion. Confirmation must be detected while more
than 12 hours remain. If it arrives too late, the schedule stays unarmed because
the complete notice sequence is no longer possible. Run a normal manual destroy
or create a freshly reviewed schedule instead; do not edit DynamoDB by hand.

The saved deadline is checked again on every later plan/apply. If fewer than 12
hours 15 minutes remain, the local helper blocks before Terraform planning. For
an un-applied schedule, remove only
`terraform/scheduled_destroy.auto.tfvars.json`, rerun `plan`, and choose a new
deadline. Never reset that file merely to evade an already armed AWS schedule;
inspect `schedule-status` and use the documented SMS cancellation instead.

After timely confirmation, AWS sends an `ARMED` SMS and email. From that moment,
the only normal state transition that stops the deadline is an authenticated
`CANCEL` SMS reply from the enrolled phone.

## Read status without changing it

```bash
./scripts/workspace.sh schedule-status --region us-west-2
```

Expected states:

| State | Plain meaning |
| --- | --- |
| `PENDING` | Waiting for timely email confirmation; deletion cannot start. |
| `ACTIVE` | Armed; milestone notices are sent and the deadline is enforced. |
| `TRIGGERING` | Lambda is starting CodeBuild; a simultaneous `CANCEL` may still win. |
| `TRIGGERED` | Build started but must still pass its final state gate. |
| `CANCELLED` | Exact authenticated SMS cancellation won; scheduled deletion ceases. |
| `EXECUTING` | Terraform deletion has begun; cancellation is no longer possible. |

The command reads only DynamoDB and Terraform output. It does not cancel, delay,
or re-arm anything.

## Cancel correctly

When a warning SMS arrives, use the same enrolled phone and reply:

```text
CANCEL
```

Do not send `cancel please`, `CANCEL!`, `STOP`, or an email reply. Do not initiate
a new message to a different number. The controller checks both the originating
operator number and the destination AWS number in the AWS two-way payload.

On success, DynamoDB changes to `CANCELLED`, and AWS attempts an SMS and email
acknowledgement. The state change is authoritative even if an acknowledgement is
delayed. Verify with `schedule-status`. A cancelled control plane remains present
and continues inexpensive state checks until a reviewed normal/manual Terraform
destroy removes it; it cannot start the scheduled teardown.

## What CodeBuild proves before deletion

At the deadline Lambda changes `ACTIVE` to `TRIGGERING` atomically, starts one
idempotent build, and records `TRIGGERED`. The build then:

1. proves the AWS account ID;
2. requires DynamoDB state `TRIGGERED`;
3. downloads Terraform 1.15.8 and verifies HashiCorp's published checksum file;
4. initializes the exact S3 backend bucket/key/Region;
5. creates a saved `terraform plan -destroy`;
6. rejects the plan if any action is `create` or `update`;
7. atomically changes `TRIGGERED` to `EXECUTING`; and
8. applies that exact saved deletion plan.

If a valid `CANCEL` wins before step 7, the build exits without applying. The
destroy removes its own Scheduler, Lambda, DynamoDB, SNS, CodeBuild, roles, logs,
and runtime resources. AWS documents that deleting a CodeBuild project does not
delete or stop its builds, so the already-running teardown can finish:
[delete a CodeBuild project](https://docs.aws.amazon.com/codebuild/latest/userguide/delete-project.html).

## Failure and recovery behavior

- **No email confirmation:** fail closed in `PENDING`; no teardown.
- **Confirmation after the 12-hour milestone:** fail closed in `PENDING`.
- **SMS/email send failure:** the controller retries an uncompleted milestone on
  later scheduler calls. SMS can duplicate if SMS succeeded but email failed.
- **Lambda/CodeBuild temporary failure:** Scheduler retries Lambda; Lambda returns
  `TRIGGERING` to `ACTIVE` when build start itself fails.
- **Invalid reply:** the schedule remains active and SMS explains the exact word.
- **Cancellation acknowledgement failure:** the `CANCELLED` database state still
  wins. Verify with `schedule-status`.
- **Terraform partial deletion:** inspect the 90-day CodeBuild error log, fix the
  first permission/dependency problem, then use the manual ownership-safe process.
  Never guess at console deletions.

AWS service outages, carrier filtering, mailbox filtering, account suspension,
quota failures, policy changes, and network failures can prevent notification or
deletion. Automation reduces forgotten resources; it is not a guarantee. Keep
the $0.01/$1/$5 budgets and AWS native Free Tier alerts enabled.

## Sensitive data and retention

The ignored file `terraform/scheduled_destroy.auto.tfvars.json` contains the
operator cell and email. It is mode `0600` when generated. Those values are also
necessarily stored in encrypted/versioned Terraform state, the SNS subscription,
and encrypted Lambda configuration. They are redacted as sensitive Terraform
inputs and omitted from source archives, inventory endpoints, and controller
logs. Anyone able to read Terraform state may still read them.

Local successful logs are kept 14 days/20 files; failures are kept 90 days/100
files. Lambda and CodeBuild logs are retained 90 days and intentionally record
states—not phone numbers, email addresses, or SMS bodies. S3 state/source versions
follow the protected backend's documented 365-day noncurrent-version retention.

## Cost checklist

This option is not guaranteed to fit any AWS Free Tier. At minimum review:

- dedicated number rental/registration and country/campaign fees;
- at least six outbound SMS deliveries (ARMED plus five milestones), plus any
  retries and cancellation acknowledgement;
- one Scheduler invocation per minute (about 43,800 in a 30.4-day month);
- Lambda duration, DynamoDB on-demand reads/writes, SNS email/API delivery,
  CloudWatch log ingestion/storage, S3 storage/requests; and
- one `BUILD_GENERAL1_SMALL` CodeBuild teardown, normally a few minutes.

The current EventBridge Scheduler free allowance is 14 million invocations per
month. CodeBuild currently includes 100 general1.small minutes per month and is
listed at US$0.005/minute after that allowance. AWS's US toll-free example lists
US$2/month for the number and about US$0.013 per outbound message, but country,
number type, registration, carrier, tax, and destination can change the amount.
See [COSTS.md](COSTS.md), [EventBridge pricing](https://aws.amazon.com/eventbridge/pricing/),
[CodeBuild pricing](https://aws.amazon.com/codebuild/pricing/), and
[End User Messaging pricing](https://aws.amazon.com/end-user-messaging/pricing/)
immediately before approval.
