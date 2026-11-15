locals {
  key_path       = trimsuffix(var.ssh_public_key_path, ".pub")
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  ingress_rules = {
    ssh   = { port = 22, cidr = var.admin_cidr, description = "SSH from admin IP only" }
    http  = { port = 80, cidr = "0.0.0.0/0", description = "HTTP redirect and Lets Encrypt" }
    https = { port = 443, cidr = "0.0.0.0/0", description = "HTTPS" }
  }

  egress_ports = {
    http  = 80
    https = 443
  }

  status_alarms = {
    system   = { metric = "StatusCheckFailed_System", periods = 2, action = "recover" }
    instance = { metric = "StatusCheckFailed_Instance", periods = 3, action = "reboot" }
  }
}

# ---------- Network ----------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "server" {
  name_prefix = "${var.project}-sg-"
  description = "Web server: SSH from admin IP only, HTTP/HTTPS public"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "in" {
  for_each = local.ingress_rules

  security_group_id = aws_security_group.server.id
  description       = each.value.description
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "out" {
  for_each = local.egress_ports

  security_group_id = aws_security_group.server.id
  description       = "Outbound ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"
}

# ---------- Backup bucket ----------

resource "aws_s3_bucket" "backups" {
  bucket_prefix = "${var.project}-backups-"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "backups_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.backups_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# ---------- Server identity (IAM) ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "backups" {
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "ReadWriteBackups"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_role" "server" {
  name_prefix        = "${var.project}-role-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "backups" {
  name   = "s3-backups"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.backups.json
}

resource "aws_iam_instance_profile" "server" {
  name_prefix = "${var.project}-profile-"
  role        = aws_iam_role.server.name
}

# ---------- Server ----------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.server.name

  user_data = <<-EOT
    #cloud-config
    users:
      - name: ${var.admin_user}
        groups: [sudo]
        shell: /bin/bash
        lock_passwd: true
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys:
          - ${local.ssh_public_key}

    ssh_pwauth: false
    disable_root: true
    package_update: true
    package_upgrade: true
  EOT

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${var.project}-server" }
}

resource "aws_eip" "server" {
  domain     = "vpc"
  instance   = aws_instance.server.id
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.project}-eip" }
}

# ---------- Alerts and budget ----------

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "status" {
  for_each = local.status_alarms

  alarm_name          = "${var.project}-${each.key}-status-failed"
  namespace           = "AWS/EC2"
  metric_name         = each.value.metric
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = each.value.periods
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.server.id }
  alarm_actions = [
    "arn:aws:automate:${var.region}:ec2:${each.value.action}",
    aws_sns_topic.alerts.arn,
  ]
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project}-cpu-high"
  alarm_description   = "CPU above 80% for 15 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.server.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ---------- Handoff to Ansible ----------

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  file_permission = "0600"
  content         = <<-EOT
    [server]
    ${aws_eip.server.public_ip} ansible_user=${var.admin_user} ansible_ssh_private_key_file=${local.key_path}
  EOT
}

resource "local_file" "ansible_tf_vars" {
  filename        = "${path.module}/../ansible/group_vars/all/terraform.yml"
  file_permission = "0600"
  content         = <<-EOT
    ---
    backup_bucket: "${aws_s3_bucket.backups.bucket}"
    aws_region: "${var.region}"
    admin_user: "${var.admin_user}"
  EOT
}
