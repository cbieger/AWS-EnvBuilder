#!/usr/bin/env python3
"""Print a transparent conservative low-traffic estimate for the default build.

The arithmetic is deliberately plain and dependency-free. Rates are documented
in docs/COSTS.md and can change; this is a guardrail, not an AWS invoice quote.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class EstimateInputs:
    """Small set of cost drivers represented by the default Terraform values."""

    instances: int = 1
    instance_hourly: float = 0.0104
    public_ipv4_addresses: int = 3
    public_ipv4_hourly: float = 0.005
    alb_hourly: float = 0.0225
    assumed_alb_lcu: float = 1.0
    alb_lcu_hourly: float = 0.008
    root_volume_gib_per_instance: int = 8
    gp3_gib_monthly: float = 0.08


def calculate(inputs: EstimateInputs) -> dict[str, float]:
    """Return component hourly rates and totals using a 730-hour month."""

    compute = inputs.instances * inputs.instance_hourly
    ipv4 = inputs.public_ipv4_addresses * inputs.public_ipv4_hourly
    load_balancer = inputs.alb_hourly + (
        inputs.assumed_alb_lcu * inputs.alb_lcu_hourly
    )
    storage = (
        inputs.instances
        * inputs.root_volume_gib_per_instance
        * inputs.gp3_gib_monthly
        / 730
    )
    total_hourly = compute + ipv4 + load_balancer + storage
    return {
        "EC2 compute": compute,
        "Public IPv4": ipv4,
        "ALB plus assumed LCU": load_balancer,
        "gp3 root disks": storage,
        "hourly": total_hourly,
        "daily": total_hourly * 24,
        "monthly": total_hourly * 730,
    }


def positive_integer(value: str) -> int:
    """Argparse converter that rejects zero or negative instance counts."""

    parsed = int(value)
    if parsed < 1 or parsed > 4:
        raise argparse.ArgumentTypeError("instances must be between 1 and 4")
    return parsed


def main() -> int:
    """Parse the only common override and display every assumption."""

    parser = argparse.ArgumentParser(
        description="Estimate the documented us-west-2 low-traffic workspace cost."
    )
    parser.add_argument(
        "--instances",
        type=positive_integer,
        default=1,
        help="continuously running EC2 instances (default: 1)",
    )
    args = parser.parse_args()

    # An ALB normally has two public addresses; add one for each running EC2.
    inputs = EstimateInputs(
        instances=args.instances,
        public_ipv4_addresses=2 + args.instances,
    )
    values = calculate(inputs)

    print("Conservative low-traffic estimate for us-west-2 (USD, before tax):")
    print(f"  EC2 compute:              ${values['EC2 compute']:.4f}/hour")
    print(f"  Public IPv4 addresses:    ${values['Public IPv4']:.4f}/hour")
    print(f"  ALB plus assumed 1 LCU:   ${values['ALB plus assumed LCU']:.4f}/hour")
    print(f"  Encrypted gp3 root disks: ${values['gp3 root disks']:.4f}/hour")
    print(f"  Estimated total:          ${values['hourly']:.4f}/hour")
    print(f"                            ${values['daily']:.2f}/day")
    print(f"                            ${values['monthly']:.2f}/730-hour month")
    print()
    print("Not included: tax, internet transfer, unusual log/ECR/S3 volume, CPU")
    print("credit overage, more than the selected instance count, or regional price")
    print("differences. Credits may pay the invoice, but do not make resources free.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
