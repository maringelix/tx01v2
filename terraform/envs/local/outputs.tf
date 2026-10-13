# Read by platform/local/install.sh and the dx01v2 local deploy (terraform output -raw <name>).
# Scalars only, so no JSON parser is needed. Sensitive values are never printed by the scripts.

output "cluster_name" {
  description = "kind cluster of the local lab."
  value       = terraform_data.cluster.output.name
}

output "docker_network" {
  description = "Docker network shared by the kind node and the emulated services."
  value       = docker_network.lab.name
}

output "subnet_cidr" {
  description = "Subnet of the Docker network (the local twin of the VPC CIDR)."
  value       = var.subnet_cidr
}

output "load_balancer_range" {
  description = "Addresses Docker hands out to the kind node and to the load balancers of cloud-provider-kind."
  value       = local.dynamic_range
}

output "registry" {
  description = "Registry name used by image references inside the cluster (the kind node resolves it)."
  value       = local.registry_name
}

output "registry_push" {
  description = "Registry name for docker push from this machine (localhost:<port>); same content as registry."
  value       = "localhost:${var.registry_host_port}"
}

output "registry_endpoint" {
  description = "Registry address inside the lab network (plain HTTP)."
  value       = "${local.ip.registry}:5000"
}

output "db_ip" {
  description = "Database address (TLS only): the local twin of the RDS endpoint."
  value       = local.ip.db
}

output "db_hostname" {
  description = "Name in the database certificate (verify-full also accepts the IP address)."
  value       = local.db.hostname
}

output "db_port" {
  description = "Database port."
  value       = local.db.port
}

output "db_name" {
  description = "Database of dx01v2."
  value       = local.db.name
}

output "db_username" {
  description = "Database user of dx01v2."
  value       = local.db.user
}

output "db_password" {
  description = "Password of the app database user (throwaway, this machine only)."
  value       = random_password.db_app.result
  sensitive   = true
}

output "admin_token" {
  description = "ADMIN_TOKEN of dx01v2 (48 alphanumeric characters, like the cloud contract)."
  value       = random_password.admin_token.result
  sensitive   = true
}

output "ca_cert_pem" {
  description = "Lab CA certificate (public): trusted for the database and the Gateway certificates."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "ca_private_key_pem" {
  description = "Lab CA key, loaded into the cert-manager ClusterIssuer lab-ca."
  value       = tls_private_key.ca.private_key_pem
  sensitive   = true
}

output "s3_endpoint" {
  description = "Object storage emulator (S3 API, path-style, plain HTTP inside the lab network)."
  value       = "http://${local.ip.s3}:${local.s3_port}"
}

output "s3_region" {
  description = "Region name the S3 clients sign with (the emulator accepts any)."
  value       = "us-east-1"
}

output "s3_bucket_velero" {
  description = "Bucket of the Velero backups."
  value       = local.buckets.velero
}

output "s3_bucket_db_backups" {
  description = "Bucket of the database dumps."
  value       = local.buckets.db_backups
}

output "s3_access_key" {
  description = "Access key of the object storage emulator."
  value       = random_password.s3_access_key.result
  sensitive   = true
}

output "s3_secret_key" {
  description = "Secret key of the object storage emulator."
  value       = random_password.s3_secret_key.result
  sensitive   = true
}

output "git_ssh_url" {
  description = "Git server of the GitOps flow, SSH (push with git_admin_private_key)."
  value       = "ssh://${local.ip.git}:${local.git_ports.ssh}"
}

output "git_http_url" {
  description = "Git server of the GitOps flow, anonymous read-only HTTP (Argo CD reads here)."
  value       = "http://${local.ip.git}:${local.git_ports.http}"
}

output "git_admin_private_key" {
  description = "OpenSSH private key of the git server admin (the dx01v2 deploy pushes with it)."
  value       = tls_private_key.git_admin.private_key_openssh
  sensitive   = true
}

output "grafana_admin_password" {
  description = "Grafana admin password (only reachable through kubectl port-forward)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}
