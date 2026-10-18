# Images of the emulated services, pinned by digest (multi-arch index; verified 2026-10-12). Bump them
# in docs/MAINTENANCE.md (local lab section); the kind node image lives in kind-config.yaml.
locals {
  images = {
    # Emulates ECR: CNCF Distribution 3.1.2 (registry:3 at the time of pinning).
    registry = "registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8"
    # Emulates RDS for PostgreSQL 17: the same image and digest the dx01v2 harness and compose use.
    postgres = "postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"
    # Emulates S3: Versity S3 Gateway v1.8.0 (Apache-2.0) with the posix backend.
    s3 = "versity/versitygw:v1.8.0@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499"
    # Emulates GitHub for GitOps: Soft Serve v0.12.3 (MIT), SSH push and anonymous read-only HTTP.
    git = "ghcr.io/charmbracelet/soft-serve:v0.12.3@sha256:e8a12ff7f112558a6cd461ca192fe237d9deb2ec081ace944d2b5a61138a0db9"
    # Emulates the cloud load balancer: cloud-provider-kind v0.12.0 serves Services of type LoadBalancer.
    lb = "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.12.0@sha256:1b97632e5dfec8f83c7e970cf18cedb9e6b707e272011d712cabf6ab59d323c9"
  }
}
