# Cost and Free Tier guide

<p><font color="red" size="6"><strong>ASSUME THIS BUILD COSTS MONEY. DO NOT APPLY IT UNTIL THE AWS ACCOUNT OWNER APPROVES AN ESTIMATED US$1.40 PER DAY (ABOUT US$42 PER 30-DAY MONTH) FOR THE DEFAULT LOW-TRAFFIC US-WEST-2 CONFIGURATION.</strong></font></p>

That is an estimate, not a quote or cap. Region, traffic, logs, tax, public IPv4
count, CPU credit use, and Auto Scaling can make the invoice larger. The current
AWS prices shown here were reviewed on 2026-07-18 and must be rechecked before a
real deployment.

Run the transparent arithmetic at any time:

```bash
./scripts/workspace.sh cost
./scripts/cost_estimate.py --instances 2
```

## Default conservative estimate

The calculation assumes one `t3.micro` runs all month, an ALB spans two zones,
three public IPv4 addresses are billed (two for the ALB and one for EC2), eight
GiB of gp3 storage, and a conservative full ALB capacity unit for low traffic.

| Component | Assumption | Approximate hourly cost |
|---|---:|---:|
| EC2 | 1 × `t3.micro` Linux in us-west-2 | $0.0104 |
| Public IPv4 | 3 × $0.005 | $0.0150 |
| ALB base | 1 × $0.0225 | $0.0225 |
| ALB capacity | assumed 1 LCU × $0.008 | $0.0080 |
| gp3 disk | 8 GiB × $0.08/GiB-month ÷ 730 | $0.0009 |
| **Estimated total** | before variable usage and tax | **$0.0568/hour** |

That becomes approximately **$1.36/day** or **$41.45 per 730-hour month**.
Rounding the approval warning to **$1.40/day / $42/month** leaves a little room,
but is not a spending limit.

AWS pricing references:

- [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [Elastic Load Balancing pricing](https://aws.amazon.com/elasticloadbalancing/pricing/)
- [VPC public IPv4 pricing](https://aws.amazon.com/vpc/pricing/)
- [EBS pricing](https://aws.amazon.com/ebs/pricing/)
- [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/)
- [ECR pricing](https://aws.amazon.com/ecr/pricing/)
- [S3 pricing](https://aws.amazon.com/s3/pricing/)

## Costs not included in the table

- A second instance: approximately another EC2 hour, public IPv4 hour, and disk.
- T3 Unlimited surplus CPU credits during sustained high CPU.
- Internet data transfer beyond AWS's current allowances.
- CloudWatch log ingestion, queries, metrics, and retained volume.
- ECR image and S3 request-log storage beyond tiny development usage.
- S3 Terraform state requests and storage (normally pennies or less).
- DNS, TLS-related additions, databases, NAT Gateways, WAF, or services added later.
- Sales tax, VAT, or other account-specific charges.

## Can AWS Free Tier make it free?

Possibly, but the infrastructure is never *guaranteed* free.

For accounts opened on or after July 15, 2025, AWS says new customers receive
$100 in credits and may earn up to another $100. The free plan ends at six months
or when credits are depleted, whichever comes first; credit expiration rules may
differ. For older accounts, legacy rules depend on account age and monthly service
limits. The ALB and public IPv4 addresses can consume credits even when the EC2
instance type is marked Free Tier eligible.

Check the actual account, not a memory of the marketing page:

1. Sign in to the AWS Console.
2. Open **Billing and Cost Management**.
3. Open **Credits** and record the balance and expiration date.
4. Open **Free Tier** and inspect current usage.
5. Under **Billing preferences**, verify **Receive AWS Free Tier alerts** is
   enabled and that its destination email is monitored.
6. Confirm the three Terraform-managed account-wide budgets exist and use the
   monitored addresses configured in `budget_alert_emails`.

Official references:

- [AWS Free Tier announcement and credits](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/)
- [AWS Free Tier FAQ](https://aws.amazon.com/free/free-tier-faqs/)
- [EC2 Free Tier rules before and after July 15, 2025](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html)

## Automated account-wide cost alerts

Terraform creates three monthly AWS Budgets with limits of $0.01, $1, and $5.
Every budget sends both an actual-spend alert and a forecast-spend alert to each
address in `budget_alert_emails`. Credits and refunds are excluded from the
calculation so they cannot hide gross service charges. The budgets cover the
whole AWS account; they are not limited to this workspace's tags.

The $0.01 budget implements a practical near-zero-spend warning. It cannot prove
that every service-specific Free Tier allowance is exhausted. AWS's native Free
Tier alerts separately email at 85% of eligible service limits and must remain
enabled in Billing preferences.

AWS Budgets without automated actions are currently free. Alerts are not instant:
billing data may be delayed, and a forecast can require about five weeks of usage
history. These alerts never stop resources. Always investigate the Billing
console and use the guarded destroy command when charges are unexpected.
The normal destroy workflow removes these workspace-owned budgets after removing
the runtime. Keep AWS's native Free Tier alerts enabled, and manage a separate
account-level budget if alerts must continue when no workspace exists.

Official references:

- [Tracking AWS Free Tier usage](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/tracking-free-tier-usage.html)
- [Managing costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [AWS Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html)
- [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)

## Practical cost controls already included

- maximum instance count defaults to two and is limited to four by validation;
- no NAT Gateway;
- small `t3.micro` and 8 GiB gp3 defaults;
- routine logs expire before error logs;
- ALB request objects expire;
- ECR keeps only twenty tagged images and removes old untagged images;
- account-wide budgets alert near zero spend and at $1 and $5, using both actual
  and forecast spend;
- every apply repeats a large warning and exact approval phrase;
- destroy is documented and guarded.

Terraform cannot create a truly hard account spending cap. An AWS Budget is an
alert, not an emergency stop. The account owner remains responsible for Billing
Console review and prompt teardown.
