# Every operator-adjustable value is declared and explained here. Defaults favor
# a small development workspace, not a production workload.
variable "project_name" {
  description = "Short lowercase name used to identify this application in AWS."
  type        = string
  default     = "stub-app"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-24 lowercase letters, digits, or hyphens; start with a letter and end with a letter or digit."
  }
}

variable "environment" {
  description = "Lifecycle label such as dev, test, or demo."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}[a-z0-9]$", var.environment))
    error_message = "environment must be 3-12 lowercase letters, digits, or hyphens."
  }
}

variable "aws_region" {
  description = "AWS Region in which all runtime resources are created."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like us-west-2."
  }
}

variable "vpc_cidr" {
  description = "Private IPv4 range reserved for this workspace."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR, for example 10.40.0.0/16."
  }
}

variable "availability_zone_count" {
  description = "Number of Availability Zones. ALB requires at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "allowed_ipv4_cidrs" {
  description = "IPv4 networks allowed to call the public ALB. Replace the open default with office or VPN CIDRs whenever practical."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_ipv4_cidrs) > 0 && alltrue([for cidr in var.allowed_ipv4_cidrs : can(cidrnetmask(cidr))])
    error_message = "allowed_ipv4_cidrs must contain one or more valid IPv4 CIDRs."
  }
}

variable "instance_type" {
  description = "EC2 size. t3.micro is deliberately small and x86-64 compatible."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[0-9][a-z]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like t3.micro."
  }
}

variable "minimum_instances" {
  description = "Smallest number of application instances kept running."
  type        = number
  default     = 1

  validation {
    condition     = var.minimum_instances >= 1 && var.minimum_instances <= 4
    error_message = "minimum_instances must be between 1 and 4."
  }
}

variable "desired_instances" {
  description = "Normal number of application instances immediately after deployment."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_instances >= 1 && var.desired_instances <= 4
    error_message = "desired_instances must be between 1 and 4."
  }
}

variable "maximum_instances" {
  description = "Hard upper bound used by automatic CPU scaling. Every extra running instance adds cost."
  type        = number
  default     = 2

  validation {
    condition     = var.maximum_instances >= 1 && var.maximum_instances <= 4
    error_message = "maximum_instances must be between 1 and 4 for this development module."
  }
}

variable "target_cpu_utilization" {
  description = "Auto Scaling adds or removes replaceable instances to approach this average CPU percentage."
  type        = number
  default     = 60

  validation {
    condition     = var.target_cpu_utilization >= 20 && var.target_cpu_utilization <= 90
    error_message = "target_cpu_utilization must be between 20 and 90."
  }
}

variable "use_spot_instances" {
  description = "Use interruptible Spot capacity. Cheaper, but AWS may terminate it with little warning."
  type        = bool
  default     = false
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 boot disk size for each disposable instance."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gib >= 8 && var.root_volume_size_gib <= 50
    error_message = "root_volume_size_gib must be between 8 and 50 GiB."
  }
}

variable "container_image" {
  description = "Public image tag or immutable private ECR image digest started on every instance. Never place credentials in this value."
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:stable-alpine"

  validation {
    condition     = length(var.container_image) <= 512 && can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]+$", var.container_image))
    error_message = "container_image must be a normal registry image reference without spaces, quotes, or shell characters."
  }
}

variable "container_port" {
  description = "TCP port on which the container listens."
  type        = number
  default     = 80

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "health_check_path" {
  description = "Unauthenticated HTTP path the ALB uses to decide whether an instance is healthy."
  type        = string
  default     = "/"

  validation {
    condition     = startswith(var.health_check_path, "/") && length(var.health_check_path) <= 128 && can(regex("^[A-Za-z0-9/_?&=.-]+$", var.health_check_path))
    error_message = "health_check_path must start with / and contain only URL path/query characters."
  }
}

variable "routine_log_retention_days" {
  description = "CloudWatch retention for routine application and bootstrap output."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.routine_log_retention_days)
    error_message = "routine_log_retention_days must be a CloudWatch-supported retention value."
  }
}

variable "error_log_retention_days" {
  description = "Longer CloudWatch retention for bootstrap errors."
  type        = number
  default     = 90

  validation {
    condition     = contains([30, 60, 90, 120, 150, 180, 365, 400, 545, 731], var.error_log_retention_days)
    error_message = "error_log_retention_days must be a supported value of at least 30 days."
  }
}

variable "alb_access_log_retention_days" {
  description = "Days before ALB request objects expire from the logging bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.alb_access_log_retention_days >= 1 && var.alb_access_log_retention_days <= 365
    error_message = "alb_access_log_retention_days must be between 1 and 365."
  }
}

variable "budget_alert_emails" {
  description = "One to ten email addresses that receive actual and forecast monthly cost alerts at approximately $0.01, $1, and $5."
  type        = list(string)

  validation {
    condition = (
      length(var.budget_alert_emails) >= 1 &&
      length(var.budget_alert_emails) <= 10 &&
      alltrue([
        for email in var.budget_alert_emails :
        can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email))
      ])
    )
    error_message = "budget_alert_emails must contain 1-10 ordinary email addresses. Never place passwords, tokens, or mail credentials here."
  }
}

variable "additional_tags" {
  description = "Optional non-secret business tags applied to supported resources."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key, value in var.additional_tags : length(key) <= 128 && length(value) <= 256])
    error_message = "Tag keys must be at most 128 characters and values at most 256 characters."
  }
}
