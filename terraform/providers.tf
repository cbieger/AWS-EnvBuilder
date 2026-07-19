# The AWS provider uses the normal AWS CLI credential chain. No access key or
# secret belongs in Terraform variables or state.
provider "aws" {
  region = var.aws_region

  # Provider-level tags are automatically applied wherever AWS supports them.
  default_tags {
    tags = local.common_tags
  }
}

# These read-only lookups make names and policies portable across AWS accounts
# and partitions without embedding an account ID.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Only currently available standard Availability Zones are candidates.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required", "opted-in"]
  }
}

# Use AWS's newest Amazon Linux 2023 x86-64 image at plan time. The owner filter
# prevents an unrelated account from supplying an image with a convincing name.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
