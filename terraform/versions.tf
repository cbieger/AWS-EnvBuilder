# Terraform itself and every provider are constrained so that future breaking
# releases cannot silently change this workspace during an ordinary init.
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }

  # Settings such as bucket name and region live in generated backend.hcl.
  # Keeping them outside source allows the same stub to serve many accounts.
  backend "s3" {}
}
