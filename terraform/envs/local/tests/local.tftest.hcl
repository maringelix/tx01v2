# Local lab root (terraform/envs/local): every run is a plan with mocked providers, so no container,
# network or kind cluster is created (the kind provisioner only runs on apply). The real apply is
# exercised by the harness stage e2e (scripts/local-lab.sh e2e).

mock_provider "docker" {}
mock_provider "tls" {}
mock_provider "random" {}

run "defaults_are_safe" {
  command = plan

  assert {
    condition     = var.subnet_cidr == "10.250.0.0/24" && var.registry_host_port == 5001 && var.docker_host == "unix:///var/run/docker.sock"
    error_message = "Defaults must be the private /24 10.250.0.0/24, registry port 5001 and the local Docker socket."
  }

  assert {
    condition     = docker_network.lab.name == "tx01v2-local" && one(docker_network.lab.ipam_config).ip_range == "10.250.0.128/25"
    error_message = "The lab network must keep the upper half of the subnet for Docker (kind node, load balancers)."
  }

  assert {
    condition = alltrue([
      for c in [docker_container.registry, docker_container.db, docker_container.s3, docker_container.git, docker_container.lb] :
      contains([for l in c.labels : "${l.label}=${l.value}"], "tx01v2.lab=local")
    ])
    error_message = "Every container must carry the label tx01v2.lab=local (scripts/leftovers-local.sh relies on it)."
  }

  assert {
    condition     = alltrue([for v in docker_volume.data : contains([for l in v.labels : "${l.label}=${l.value}"], "tx01v2.lab=local")])
    error_message = "Every data volume must carry the label tx01v2.lab=local."
  }

  assert {
    condition     = alltrue([for k, i in local.images : can(regex("@sha256:[0-9a-f]{64}$", i))])
    error_message = "Every image of the local lab must be pinned by digest."
  }
}

run "only_the_registry_is_published_and_only_on_loopback" {
  command = plan

  assert {
    condition     = [for p in docker_container.registry.ports : [p.internal, p.external, p.ip]] == [[5000, 5001, "127.0.0.1"]]
    error_message = "The registry must be published on 127.0.0.1:5001 only."
  }

  assert {
    condition     = length(docker_container.db.ports) == 0 && length(docker_container.s3.ports) == 0 && length(docker_container.git.ports) == 0 && length(docker_container.lb.ports) == 0
    error_message = "Database, object storage, git server and load balancer emulator must not publish ports on the host."
  }
}

run "database_is_tls_only_with_the_lab_ca" {
  command = plan

  assert {
    condition     = strcontains(local.pg_hba, "hostssl all  all  0.0.0.0/0     scram-sha-256") && strcontains(local.pg_hba, "host    all  all  0.0.0.0/0     reject")
    error_message = "pg_hba.conf must accept network clients only over TLS with SCRAM and reject everything else."
  }

  assert {
    condition     = strcontains(local.db_start, "ssl=on") && strcontains(local.db_start, "ssl_min_protocol_version=TLSv1.2")
    error_message = "PostgreSQL must start with TLS on (minimum TLS 1.2)."
  }

  assert {
    condition     = tls_cert_request.db.dns_names == tolist(["db.tx01v2.local"]) && tls_cert_request.db.ip_addresses == tolist(["10.250.0.11"])
    error_message = "The database certificate must name db.tx01v2.local and its static address (verify-full)."
  }

  assert {
    condition     = tls_self_signed_cert.ca.is_ca_certificate && tls_self_signed_cert.ca.validity_period_hours == 720
    error_message = "The lab CA must be a CA valid for 30 days."
  }

  assert {
    condition     = random_password.db_app.length == 40 && random_password.db_app.special == false && random_password.admin_token.length == 48
    error_message = "Generated credentials must follow the contract lengths (40 and 48 alphanumeric characters)."
  }
}

run "static_addresses" {
  command = plan

  assert {
    condition = [for c in [docker_container.registry, docker_container.db, docker_container.s3, docker_container.git] : one(c.networks_advanced).ipv4_address] == [
      "10.250.0.10", "10.250.0.11", "10.250.0.12", "10.250.0.13",
    ]
    error_message = "Registry, database, object storage and git server must keep their static addresses."
  }

  assert {
    condition     = contains(docker_container.lb.env, "KIND_EXPERIMENTAL_DOCKER_NETWORK=tx01v2-local")
    error_message = "cloud-provider-kind must create its load balancers on the lab network."
  }

  assert {
    condition     = contains(docker_container.git.env, "SOFT_SERVE_ANON_ACCESS=read-only")
    error_message = "The git server must allow anonymous reads only (pushes need the admin key)."
  }
}

run "another_subnet_moves_every_address" {
  command = plan

  variables {
    subnet_cidr        = "192.168.77.0/24"
    registry_host_port = 15001
  }

  assert {
    condition     = one(docker_container.db.networks_advanced).ipv4_address == "192.168.77.11" && one(docker_network.lab.ipam_config).ip_range == "192.168.77.128/25"
    error_message = "Addresses must be derived from subnet_cidr."
  }

  assert {
    condition     = output.registry_push == "localhost:15001" && output.registry == "registry.tx01v2.local"
    error_message = "registry_push must follow registry_host_port; the in-cluster name stays registry.tx01v2.local."
  }
}

run "refuses_a_public_subnet" {
  command = plan

  variables {
    subnet_cidr = "203.0.113.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "refuses_a_subnet_overlapping_kind" {
  command = plan

  variables {
    subnet_cidr = "10.96.0.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "refuses_a_non_24" {
  command = plan

  variables {
    subnet_cidr = "10.250.0.0/16"
  }

  expect_failures = [var.subnet_cidr]
}

run "refuses_a_remote_docker_daemon" {
  command = plan

  variables {
    docker_host = "tcp://198.51.100.20:2375"
  }

  expect_failures = [var.docker_host]
}

run "refuses_a_privileged_port" {
  command = plan

  variables {
    registry_host_port = 80
  }

  expect_failures = [var.registry_host_port]
}
