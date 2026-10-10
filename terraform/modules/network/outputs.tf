output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (tagged kubernetes.io/role/elb=1 for internet-facing ALBs)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes, pods, RDS; tagged kubernetes.io/role/internal-elb=1)."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs (one unless nat_gateway_per_az = true)."
  value       = aws_nat_gateway.this[*].id
}

output "flow_logs_log_group_name" {
  description = "CloudWatch log group receiving the VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
