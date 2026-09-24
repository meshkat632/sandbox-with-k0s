output "name" {
  description = "Base name shared by the stack's resources."
  value       = local.name
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "region" {
  description = "AWS region the stack is deployed in."
  value       = var.region
}

output "public_ip" {
  description = "Elastic IP of the instance; also a SAN on the Kubernetes API certificate."
  value       = aws_eip.this.public_ip
}

output "ami_name" {
  description = "Ubuntu AMI the instance was launched from."
  value       = data.aws_ami.ubuntu.name
}

output "security_group_id" {
  description = "Security group guarding SSH and the Kubernetes API."
  value       = aws_security_group.this.id
}

output "kubeconfig_secret_name" {
  description = "Secrets Manager secret the instance publishes its admin kubeconfig to."
  value       = module.kubeconfig_secret.secret_name
}

output "ssh_command" {
  description = "SSH into the instance (add -i <private key>)."
  value       = "ssh ubuntu@${aws_eip.this.public_ip}"
}

output "ssm_command" {
  description = "Open a Session Manager shell on the instance, without SSH."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}

output "uploaded_files" {
  description = "Files from upload_dir mirrored to upload_destination on the instance."
  value       = [for f in local.upload_files : "${var.upload_destination}/${f}"]
}
