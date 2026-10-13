terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }

  # Local state outside the repository: scripts/local-lab.sh passes
  # -backend-config=path=<state dir>/terraform.tfstate (default ~/.local/state/tx01v2-local).
  backend "local" {}
}
