# Keep generated resource names short enough for AWS services with conservative
# name limits. Variable validation below keeps all components predictable.
locals {
  name = "${var.project_name}-${var.environment}"

  selected_availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    var.availability_zone_count
  )

  common_tags = merge(
    {
      Application = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "aws-stateless-development-workspace"
      State       = "stateless"
    },
    var.additional_tags
  )
}
