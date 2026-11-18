variable "project" {
  description = "Project tag value and name prefix for every resource. Must match the prefix the deploy role is scoped to."
  type        = string
  default     = "aidlc-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Two /24 public subnets are carved from it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "operator_cidr" {
  description = "The single operator address allowed to reach the service, as a /32. Supplied from the OPERATOR_CIDR repository secret; never committed."
  type        = string
  # No default, on purpose: there is no safe value to fall back to.

  validation {
    condition = (
      can(cidrhost(var.operator_cidr, 0)) &&
      endswith(var.operator_cidr, "/32") &&
      var.operator_cidr != "0.0.0.0/32"
    )
    error_message = "operator_cidr must be a single IPv4 address as a /32, for example 203.0.113.10/32. Wider ranges, including 0.0.0.0/0, are rejected."
  }
}

variable "image_tag" {
  description = "Tag of the image in the project ECR repository to run. The deploy workflow uses the git commit SHA."
  type        = string

  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty."
  }
}

variable "permissions_boundary_name" {
  description = "Name of the hand-made IAM policy used as the permissions boundary for roles this module creates. The ARN is built from the caller's account at plan time."
  type        = string
  default     = "aidlc-demo-task-boundary"

  validation {
    condition     = length(trimspace(var.permissions_boundary_name)) > 0
    error_message = "permissions_boundary_name must not be empty."
  }
}
