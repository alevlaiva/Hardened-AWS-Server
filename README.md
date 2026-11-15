# Hardened AWS Server

A small, security-focused Linux server on AWS, built entirely as code. Terraform creates the cloud infrastructure and Ansible (in progress) configures and hardens the server. No secrets, IP addresses or account IDs are stored in the repository.

This is a learning and portfolio project for a junior sysadmin / cloud role.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Terraform: network, server, IAM, backup bucket, alarms, budget | Done |
| 2 | Ansible: SSH hardening, firewall, fail2ban, automatic updates, Nginx + HTTPS | In progress |
| 3 | Prometheus + Grafana monitoring, S3 backups, tested restore | Planned |
| 4 | CI security checks, runbook | Planned |

## Architecture

```
Internet
   |
   |  80/443 from anywhere, 22 from the admin IP only
   v
[ Security group ]
   |
[ EC2: Ubuntu 24.04, encrypted gp3 disk, IMDSv2 ] -- Elastic IP
   |      \
   |       \-- IAM role (SSM access, write/read-only access to the backup bucket)
   |
[ S3 backup bucket: private, encrypted, versioned, 30-day lifecycle ]

CloudWatch alarms -> SNS -> email        AWS Budget -> email
```

## What Terraform creates

- **Network:** dedicated VPC, public subnet, internet gateway, route table, locked-down default security group, and a security group for the server.
- **Server:** Ubuntu 24.04 EC2 instance with an Elastic IP, encrypted root volume, IMDSv2 enforced, and a first-boot cloud-init script that creates a non-root admin user.
- **Identity:** IAM role and instance profile, so no AWS access keys are stored on the server.
- **Backups:** S3 bucket with public access blocked, encryption, versioning, lifecycle expiry and an HTTPS-only policy.
- **Alerting:** CloudWatch alarms (host failure, OS failure, high CPU) with automatic recovery or reboot, SNS email notifications, and a monthly cost budget.
- **Ansible handoff:** generates the Ansible inventory and variables from Terraform outputs, so nothing is copied by hand.

## Security decisions

| Decision | Why |
|---|---|
| SSH allowed only from one admin IP (`/32`, validated) | Removes SSH from the public attack surface |
| Key-only SSH, root login and password login disabled | Stops brute-force password attacks |
| IAM role instead of access keys | No long-lived credentials on the server |
| Backup role can write and read, but not delete | A compromised server cannot wipe its own backups |
| IMDSv2 required, hop limit 1 | Blocks metadata credential theft |
| Encrypted disk and bucket, HTTPS-only bucket policy | Data protected at rest and in transit |
| Restricted outbound rules (HTTP, HTTPS only) | Limits what a compromised server can reach |
| `cpu_credits = "standard"` | Prevents surprise burst charges |
| Budget alerts | Early warning on unexpected spend |
| Secrets and state in `.gitignore` | `*.tfvars`, `*.tfstate`, keys and generated Ansible files never reach Git |

## Prerequisites

- An AWS account and an IAM user with MFA (do not use the root user)
- Terraform 1.6 or newer
- AWS CLI configured with a profile
- Ansible (for phase 2)
- An SSH key pair (`ssh-keygen -t ed25519 -f ~/.ssh/aws_cv`)

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set your IP (/32) and alert email
terraform init
terraform plan
terraform apply
```

Connect to the server with the command printed in the `ssh_command` output.

Tear everything down with `terraform destroy`. The backup bucket is protected with `force_destroy = false`, so it must be emptied before it can be deleted.

## Cost

A `t3.micro` instance plus an Elastic IP costs roughly a few cents per hour. Stop or destroy the resources when you are not using them. A budget alert is created by Terraform.

## What I would change for production

- Remote Terraform state (S3 with locking) instead of local state
- Terraform modules and separate dev / prod environments
- Plan and apply through a CI/CD pipeline with review
- Private subnets, with access through Session Manager only
- Secrets in AWS Secrets Manager, centralised logging
- Immutable images instead of configuring long-lived servers
