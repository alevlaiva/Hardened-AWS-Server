variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "cv-server"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 20
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (x.x.x.x/32)"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single IP like 203.0.113.10/32."
  }
}

variable "admin_user" {
  description = "Linux admin username created on the server"
  type        = string
  default     = "opsadmin"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/aws_cv.pub"
}

variable "alert_email" {
  description = "Email address for budget and CloudWatch alerts"
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget alert threshold in USD"
  type        = number
  default     = 10
}

variable "backup_retention_days" {
  description = "Days to keep backups in S3"
  type        = number
  default     = 30
}