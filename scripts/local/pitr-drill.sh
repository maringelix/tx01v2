#!/usr/bin/env bash
# Physical PostgreSQL recovery proof for the throwaway local lab. A base backup and archived WAL
# recover a deliberately deleted row at a named restore point; a damaged base backup is rejected.
# This script never changes the app's tables and leaves the primary database running.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

[[ $# == 4 ]] || die "usage: pitr-drill.sh POSTGRES_IMAGE DOCKER_NETWORK BASEBACKUP_VOLUME WAL_VOLUME"
image=$1 network=$2 base_volume=$3 wal_volume=$4
source_db=tx01v2-local-db
recovery_db=tx01v2-local-pitr-recovery
recovery_volume=tx01v2-local-pitr-recovery

cleanup() {
  local rc=$?
  docker rm -f "$recovery_db" >/dev/null 2>&1 || true
  docker volume rm "$recovery_volume" >/dev/null 2>&1 || true
  docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
    -c 'DROP TABLE IF EXISTS lab_pitr_probe' >/dev/null 2>&1 || true
  exit "$rc"
}
docker inspect "$source_db" --format '{{.State.Running}}' | grep -qx true || die "PITR: local PostgreSQL is not running"
docker volume inspect "$base_volume" "$wal_volume" >/dev/null
if docker volume inspect "$recovery_volume" >/dev/null 2>&1 || docker container inspect "$recovery_db" >/dev/null 2>&1; then
  die "PITR: stale recovery resource exists; inspect and remove it before retrying"
fi
trap cleanup EXIT

docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
  -c 'CREATE TABLE IF NOT EXISTS lab_pitr_probe (id text PRIMARY KEY, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()); TRUNCATE lab_pitr_probe; INSERT INTO lab_pitr_probe (id) VALUES ('"'"'baseline'"'"');' >/dev/null

# pg_basebackup writes a physical copy plus a manifest. -X stream makes the base independently
# consistent; WAL archived after it carries the chosen restore point and the next transaction.
docker exec -u postgres "$source_db" sh -ec \
  'rm -rf /db-backups/r9-base && pg_basebackup -h /var/run/postgresql -U dx01v2 -D /db-backups/r9-base -Fp -Xs -c fast && pg_verifybackup /db-backups/r9-base'

docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
  -c "INSERT INTO lab_pitr_probe (id) VALUES ('keep'); SELECT pg_create_restore_point('tx01v2_r9_keep');" >/dev/null
segment="$(docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 -Atc 'SELECT pg_walfile_name(pg_current_wal_lsn())')"
docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 -Atc 'SELECT pg_switch_wal()' >/dev/null

archived=0
for _ in $(seq 1 30); do
  if docker exec "$source_db" test -s "/wal-archive/$segment"; then
    archived=1
    break
  fi
  sleep 2
done
((archived == 1)) || die "PITR: WAL segment $segment was not archived"

# Model a bad write and an operator deleting the target row after the chosen point. Recovery must
# return 'keep' and discard 'lost'. The pre-restore database demonstrably no longer has 'keep'.
docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
  -c "INSERT INTO lab_pitr_probe (id) VALUES ('lost'); DELETE FROM lab_pitr_probe WHERE id = 'keep';" >/dev/null
before="$(docker exec -u postgres "$source_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 -Atc "SELECT string_agg(id, ',' ORDER BY id) FROM lab_pitr_probe")"
[[ "$before" == "baseline,lost" ]] || die "PITR: expected the damaged source to hold baseline,lost, got $before"

docker volume create --label tx01v2.lab=local --name "$recovery_volume" >/dev/null
docker run --rm --user root -v "$base_volume:/base:ro" -v "$recovery_volume:/recovery" "$image" \
  sh -ec 'cp -a /base/r9-base/. /recovery/; printf damaged >> /recovery/PG_VERSION'
if verification_log="$(docker run --rm --user postgres -v "$recovery_volume:/recovery:ro" "$image" \
  pg_verifybackup /recovery 2>&1)"; then
  die "PITR: pg_verifybackup accepted a corrupted base backup"
fi
[[ "$verification_log" == *PG_VERSION* ]] || die "PITR: backup verification failed for an unexpected reason: $verification_log"
log "PASS PITR: pg_verifybackup rejected the corrupted physical backup"

docker volume rm "$recovery_volume" >/dev/null
docker volume create --label tx01v2.lab=local --name "$recovery_volume" >/dev/null
docker run --rm --user root -v "$base_volume:/base:ro" -v "$recovery_volume:/recovery" "$image" sh -ec '
  cp -a /base/r9-base/. /recovery/
  printf "\nrestore_command = '\''cp /wal-archive/%%f %%p'\''\nrecovery_target_name = '\''tx01v2_r9_keep'\''\nrecovery_target_action = '\''promote'\''\n" >> /recovery/postgresql.auto.conf
  touch /recovery/recovery.signal
  chown -R postgres:postgres /recovery
  chmod 700 /recovery
'

started_at="$(date +%s)"
docker run -d --name "$recovery_db" --label tx01v2.lab=local --network "$network" \
  -v "$recovery_volume:/var/lib/postgresql/data" -v "$wal_volume:/wal-archive:ro" \
  "$image" postgres -c archive_mode=off >/dev/null

promoted=0
for _ in $(seq 1 60); do
  if docker exec -u postgres "$recovery_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
    -Atc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | grep -qx t; then
    promoted=1
    break
  fi
  sleep 2
done
((promoted == 1)) || { docker logs "$recovery_db" >&2; die "PITR: recovered PostgreSQL did not promote"; }

restored="$(docker exec -u postgres "$recovery_db" psql -U dx01v2 -X -v ON_ERROR_STOP=1 -d dx01v2 \
  -Atc "SELECT string_agg(id, ',' ORDER BY id) FROM lab_pitr_probe")"
[[ "$restored" == "baseline,keep" ]] || die "PITR: expected baseline,keep after recovery, got $restored"
recovery_seconds="$(($(date +%s) - started_at))"
((recovery_seconds <= 180)) || die "PITR: recovery took ${recovery_seconds}s, above the local 180s target"
log "PASS PITR: physical base backup + archived WAL recovered baseline,keep; discarded lost; recovery ${recovery_seconds}s"
