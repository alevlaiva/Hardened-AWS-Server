output "public_ip" {
  description = "Server public IP"
  value       = aws_eip.server.public_ip
}

output "instance_id" {
  value = aws_instance.server.id
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "ssh_command" {
  value = "ssh -i ${local.key_path} ${var.admin_user}@${aws_eip.server.public_ip}"
}
