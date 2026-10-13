# The local lab talks only to the Docker daemon of this machine: no cloud provider, no credentials.
provider "docker" {
  host = var.docker_host
}
