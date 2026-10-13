variable "docker_host" {
  description = "Docker daemon that runs the local lab. Linux, WSL 2 and the devcontainer use the default socket."
  type        = string
  default     = "unix:///var/run/docker.sock"

  validation {
    condition     = can(regex("^unix:///", var.docker_host))
    error_message = "The docker_host must be a local unix socket such as unix:///var/run/docker.sock (the lab never uses a remote daemon)."
  }
}

variable "subnet_cidr" {
  description = "Docker network of the local lab (kind node, registry, database, object storage, git server, load balancers). A private /24."
  type        = string
  default     = "10.250.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0)) && endswith(var.subnet_cidr, "/24") && can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.subnet_cidr))
    error_message = "The subnet_cidr must be a private (RFC 1918) /24, for example 10.250.0.0/24."
  }

  validation {
    condition     = !can(regex("^10\\.(9[6-9]|10[0-9]|11[01]|244)\\.", var.subnet_cidr))
    error_message = "The subnet_cidr must not overlap the kind Service (10.96.0.0/12) or Pod (10.244.0.0/16) ranges."
  }
}

variable "registry_host_port" {
  description = "Port of the image registry on 127.0.0.1 of the Docker host (push localhost:<port>/...; the kind node pulls the same name)."
  type        = number
  default     = 5001

  validation {
    condition     = var.registry_host_port >= 1024 && var.registry_host_port <= 65535 && floor(var.registry_host_port) == var.registry_host_port
    error_message = "The registry_host_port must be an unprivileged TCP port (1024-65535)."
  }
}
