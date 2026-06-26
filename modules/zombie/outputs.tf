output "idle_ec2_instance_id" {
  description = "ID of the idle EC2 instance"
  value       = aws_instance.idle_ec2.id
}

output "idle_ec2_instance_type" {
  description = "Instance type of the idle EC2"
  value       = aws_instance.idle_ec2.instance_type
}

output "unattached_ebs_volume_id" {
  description = "ID of the unattached EBS volume"
  value       = aws_ebs_volume.unattached.id
}

output "unattached_ebs_size_gb" {
  description = "Size of the unattached EBS volume in GB"
  value       = aws_ebs_volume.unattached.size
}

output "unassociated_eip_public_ip" {
  description = "Public IP of the unassociated Elastic IP"
  value       = aws_eip.unassociated.public_ip
}
