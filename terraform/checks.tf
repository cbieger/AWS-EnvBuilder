# Cross-variable checks make logically impossible scaling settings fail during
# planning, before AWS receives any write request.
check "instance_capacity_is_ordered" {
  assert {
    condition = (
      var.minimum_instances <= var.desired_instances &&
      var.desired_instances <= var.maximum_instances
    )
    error_message = "Instance counts must satisfy minimum_instances <= desired_instances <= maximum_instances."
  }
}

check "region_has_enough_availability_zones" {
  assert {
    condition     = length(data.aws_availability_zones.available.names) >= var.availability_zone_count
    error_message = "The selected region does not expose enough usable Availability Zones."
  }
}

check "errors_outlive_routine_logs" {
  assert {
    condition     = var.error_log_retention_days > var.routine_log_retention_days
    error_message = "Error logs must be retained longer than routine logs."
  }
}
