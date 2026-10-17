# Local lab: the AWS lab of tx01v2 emulated on the Docker daemon of this machine (docs/ARQUITETURA.md,
# "Lab local"). Nothing here talks to AWS. AWS service -> local emulation:
#   EKS -> kind cluster (Kubernetes 1.36)        ECR -> registry (Distribution 3)
#   RDS PostgreSQL 17 (TLS) -> postgres:17 (TLS only, lab CA)   S3 -> Versity S3 Gateway
#   ALB / NLB -> cloud-provider-kind (Services of type LoadBalancer)   GitHub -> Soft Serve (GitOps)
# Every container carries the label tx01v2.lab=local; scripts/leftovers-local.sh fails when one survives
# the destroy. The state is local and outside the repository; its secrets are throwaway values of this
# machine only (never reuse them anywhere).

locals {
  name   = "tx01v2-local"
  labels = { "tx01v2.lab" = "local" }

  ip = {
    gateway  = cidrhost(var.subnet_cidr, 1)
    registry = cidrhost(var.subnet_cidr, 10)
    db       = cidrhost(var.subnet_cidr, 11)
    s3       = cidrhost(var.subnet_cidr, 12)
    git      = cidrhost(var.subnet_cidr, 13)
  }
  # Docker hands out the addresses of the kind node and of the load balancers from the upper half.
  dynamic_range = cidrsubnet(var.subnet_cidr, 1, 1)

  db = { name = "dx01v2", user = "dx01v2", port = 5432, hostname = "db.tx01v2.local" }
  # Name of the registry inside the cluster (the local twin of the ECR URL). No port, so it can be a key
  # of Kubernetes ConfigMaps (Trivy Operator mirror); the kind node maps it to the registry container.
  registry_name = "registry.tx01v2.local"
  buckets       = { velero = "tx01v2-local-velero", db_backups = "tx01v2-local-db-backups" }
  s3_port       = 7070
  git_ports     = { ssh = 23231, http = 23232 }

  # TLS only from the network (the local twin of rds.force_ssl = 1). The unix socket inside the
  # container (docker exec for backups and pg_isready) needs no password.
  pg_hba = <<-EOT
    local   replication  all         trust
    local   all  all                trust
    hostssl all  all  0.0.0.0/0     scram-sha-256
    host    all  all  0.0.0.0/0     reject
  EOT
  # PostgreSQL refuses a key readable by others: copy it with the right owner before starting.
  db_start = join(" && ", [
    "install -d -o postgres -g postgres -m 0700 /run/pgtls",
    "install -d -o postgres -g postgres -m 0700 /wal-archive /db-backups",
    "install -o postgres -g postgres -m 0600 /etc/postgresql/tls/server.key /run/pgtls/server.key",
    "install -o postgres -g postgres -m 0644 /etc/postgresql/tls/server.crt /run/pgtls/server.crt",
    "exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/run/pgtls/server.crt -c ssl_key_file=/run/pgtls/server.key -c ssl_min_protocol_version=TLSv1.2 -c hba_file=/etc/postgresql/pg_hba.conf -c 'listen_addresses=*' -c archive_mode=on -c \"archive_command=(test ! -f /wal-archive/%f && cp %p /wal-archive/%f) || cmp -s %p /wal-archive/%f\"",
  ])
}

resource "docker_network" "lab" {
  name   = local.name
  driver = "bridge"

  ipam_config {
    subnet   = var.subnet_cidr
    gateway  = local.ip.gateway
    ip_range = local.dynamic_range
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_image" "this" {
  for_each = local.images

  name = each.value
  # Images stay in the local Docker cache for the next round (they are shared, not lab resources).
  keep_locally = true
}

# Named, labelled volumes for the data directories the images declare: anonymous volumes would carry
# no label and could survive the destroy unnoticed.
resource "docker_volume" "data" {
  for_each = toset(["registry", "db", "db-basebackups", "db-wal", "s3", "git"])

  name = "${local.name}-${each.key}"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# --- Lab CA and the database certificate (verify-full, like the RDS CA bundle in the cloud) ---

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 720
  early_renewal_hours   = 168
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name  = "tx01v2 local lab CA"
    organization = "tx01v2 local lab (throwaway)"
  }
}

resource "tls_private_key" "db" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "db" {
  private_key_pem = tls_private_key.db.private_key_pem
  dns_names       = [local.db.hostname]
  ip_addresses    = [local.ip.db]

  subject {
    common_name = local.db.hostname
  }
}

resource "tls_locally_signed_cert" "db" {
  cert_request_pem      = tls_cert_request.db.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 720
  early_renewal_hours   = 168
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# --- Throwaway credentials of this machine (they live only in the local state) ---

resource "random_password" "db_app" {
  length  = 40
  special = false
}

resource "random_password" "admin_token" {
  length  = 48
  special = false
}

resource "random_password" "s3_access_key" {
  length  = 20
  special = false
  lower   = false
}

resource "random_password" "s3_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "tls_private_key" "git_admin" {
  algorithm = "ED25519"
}

# --- Emulated services ---

resource "docker_container" "registry" {
  name  = "${local.name}-registry"
  image = docker_image.this["registry"].image_id
  env   = ["REGISTRY_STORAGE_DELETE_ENABLED=true"]

  # Push from the host as localhost:<port>/... (Docker allows plain HTTP for localhost); the kind node
  # pulls the same name through containerd (hosts.toml written by scripts/local/kind-cluster.sh).
  ports {
    internal = 5000
    external = var.registry_host_port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.data["registry"].name
    container_path = "/var/lib/registry"
  }

  networks_advanced {
    name         = docker_network.lab.id
    ipv4_address = local.ip.registry
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "db" {
  name       = "${local.name}-db"
  image      = docker_image.this["postgres"].image_id
  entrypoint = ["/bin/sh", "-c"]
  command    = [local.db_start]
  env = [
    "POSTGRES_DB=${local.db.name}",
    "POSTGRES_USER=${local.db.user}",
    "POSTGRES_PASSWORD=${random_password.db_app.result}",
  ]

  upload {
    file    = "/etc/postgresql/tls/server.crt"
    content = tls_locally_signed_cert.db.cert_pem
  }

  upload {
    file    = "/etc/postgresql/tls/server.key"
    content = tls_private_key.db.private_key_pem
  }

  upload {
    file    = "/etc/postgresql/pg_hba.conf"
    content = local.pg_hba
  }

  healthcheck {
    test     = ["CMD", "pg_isready", "-U", local.db.user, "-d", local.db.name]
    interval = "2s"
    timeout  = "3s"
    retries  = 60
  }
  wait         = true
  wait_timeout = 180

  volumes {
    volume_name    = docker_volume.data["db"].name
    container_path = "/var/lib/postgresql/data"
  }

  volumes {
    volume_name    = docker_volume.data["db-basebackups"].name
    container_path = "/db-backups"
  }

  volumes {
    volume_name    = docker_volume.data["db-wal"].name
    container_path = "/wal-archive"
  }

  networks_advanced {
    name         = docker_network.lab.id
    ipv4_address = local.ip.db
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "s3" {
  name       = "${local.name}-s3"
  image      = docker_image.this["s3"].image_id
  entrypoint = ["/bin/sh", "-c"]
  # posix backend: every top-level directory is a bucket.
  command = ["mkdir -p /data/${local.buckets.velero} /data/${local.buckets.db_backups} && exec versitygw --port :${local.s3_port} posix /data"]
  env = [
    "ROOT_ACCESS_KEY=${random_password.s3_access_key.result}",
    "ROOT_SECRET_KEY=${random_password.s3_secret_key.result}",
  ]

  volumes {
    volume_name    = docker_volume.data["s3"].name
    container_path = "/data"
  }

  networks_advanced {
    name         = docker_network.lab.id
    ipv4_address = local.ip.s3
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "git" {
  name  = "${local.name}-git"
  image = docker_image.this["git"].image_id
  env = [
    "SOFT_SERVE_INITIAL_ADMIN_KEYS=${trimspace(tls_private_key.git_admin.public_key_openssh)}",
    "SOFT_SERVE_ANON_ACCESS=read-only",
    "SOFT_SERVE_SSH_PUBLIC_URL=ssh://${local.ip.git}:${local.git_ports.ssh}",
    "SOFT_SERVE_HTTP_PUBLIC_URL=http://${local.ip.git}:${local.git_ports.http}",
  ]

  volumes {
    volume_name    = docker_volume.data["git"].name
    container_path = "/soft-serve"
  }

  networks_advanced {
    name         = docker_network.lab.id
    ipv4_address = local.ip.git
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# cloud-provider-kind drives Docker to start one Envoy container per Service of type LoadBalancer (the
# local twin of the AWS Load Balancer Controller creating ALBs). It needs the Docker socket, so it can
# start containers on this machine: the reason the lab runs only on a disposable machine or the CI.
resource "docker_container" "lb" {
  name    = "${local.name}-lb"
  image   = docker_image.this["lb"].image_id
  command = ["--gateway-channel", "disabled", "--enable-default-ingress=false"]
  env     = ["KIND_EXPERIMENTAL_DOCKER_NETWORK=${docker_network.lab.name}"]

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  networks_advanced {
    name = docker_network.lab.id
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# The kind cluster (the local twin of the EKS cluster). kind is a CLI, not a provider: the pinned
# binary from scripts/install-tools.sh creates and deletes it.
resource "terraform_data" "cluster" {
  input = {
    name = local.name
  }

  triggers_replace = [
    local.name,
    docker_network.lab.name,
    filesha256("${path.module}/kind-config.yaml"),
    filesha256("${path.module}/kind-config-small.yaml"),
    filesha256("${path.module}/kind-config-ha.yaml"),
    var.local_topology,
    var.registry_host_port,
    local.registry_name,
  ]

  provisioner "local-exec" {
    command = "bash ${path.module}/../../../scripts/local/kind-cluster.sh create"
    environment = {
      CLUSTER                          = local.name
      KIND_CONFIG                      = abspath("${path.module}/${var.local_topology == "ha" ? "kind-config-ha.yaml" : "kind-config.yaml"}")
      KIND_EXPERIMENTAL_DOCKER_NETWORK = docker_network.lab.name
      REGISTRY_HOSTS                   = "localhost:${var.registry_host_port} ${local.registry_name}"
      REGISTRY_ENDPOINT                = "http://${local.ip.registry}:5000"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name ${self.input.name}"
  }

  depends_on = [docker_container.registry]
}
