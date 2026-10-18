# Data continuity in the AWS lab (R9)

## Additional Velero PVC proof

Local CI runs `scripts/local/volume-restore-drill.sh`: a restricted Pod writes bytes to a kind
`local` volume, requires `PodVolumeBackup Completed`, deletes the original namespace/PVC/PV and
bytes, then restores. The check requires a new PVC UID, `PodVolumeRestore Completed` and identical
SHA256. A restored ConfigMap or empty PVC is insufficient. Heavy execution runs in GitHub Actions.

Filesystem backup needs root/hostPath for the local Velero node agent; the server stays non-root and
the app keeps Pod Security `restricted`. A random Kopia repository password is created before the
first local backup and preserved across reinstallations. Never publish it or Secret backups.
EKS uses FSB/data movement for portable copies; kind evidence does not certify managed recovery
or regional durability.

The exercise separates four failure domains: RDS HA, native database backups, Kubernetes object/
volume backup and application recovery. Velero cannot restore a managed RDS database. Nothing here
has run in an AWS v2 account. Terraform uses mocked providers; PostgreSQL exercises run only in
Docker/Actions.

## Database profiles

| `db_profile` | Primary database | Backup/PITR | Destination |
|---|---|---|---|
| `core`, default | Single-AZ RDS | One day by default | none |
| `ha` | Multi-AZ RDS | At least seven days | same region |
| `dr` | Multi-AZ RDS | At least seven days; snapshots and logs replicated | `dr_region`, different from primary |

Opt in using repository variable `LAB_DB_PROFILE`. `LAB_DR_REGION` selects the destination.
`LAB_DB_BACKUP_RETENTION_DAYS`, `LAB_DB_DELETION_PROTECTION`, `LAB_DB_SKIP_FINAL_SNAPSHOT` and
`LAB_DB_DELETE_AUTOMATED_BACKUPS` control retention/teardown. Keep the same inputs for plan, apply
and destroy. Code rejects DR with identical source/destination regions. Mocked Terraform tests
check all three profiles, destination KMS key, replication, minimum retention and invalid inputs.

Neither HA nor DR enables deletion protection by default: this temporary lab must remain
destroyable. If `LAB_DB_DELETION_PROTECTION=true`, first plan/apply `false` and confirm the change
before destroy. If you retain a final snapshot or automated backups after deletion, inventory and
remove them when no longer required; they remain billable outside the normal lab lifecycle.

## Local physical PITR exercise

`scripts/local-lab.sh e2e` calls `platform/local/check.sh`, which invokes
`scripts/local/pitr-drill.sh`. Using digest-pinned PostgreSQL 17 and lab-labeled volumes, it:

1. Writes `baseline`, takes a physical `pg_basebackup` and verifies `backup_manifest` using `pg_verifybackup`.
2. Writes `keep`, creates a WAL restore point and waits for the archived segment copy.
3. Writes `lost` and deletes `keep` at the source, proving the current state is damaged.
4. Corrupts a backup copy and requires `pg_verifybackup` to reject it.
5. Restores an isolated instance from backup plus WAL to the restore point, promotes it and requires
   `baseline,keep` without `lost`, measuring recovery duration with a local target of 180 seconds.

The probe deletes only its own table and temporary container/volume. Lab backup/WAL volumes are
deleted by `scripts/local-lab.sh down`; `scripts/leftovers-local.sh` reports survivors.
This measures data restoration, not AWS Multi-AZ failover duration.

## Managed restore and endpoint change

RDS PITR creates another database instance from native backups. Before any switch, verify region,
restorable interval, source ARN, KMS key, destination private network and sample records.
Keep one writer: stop primary writes, restore an isolated instance and validate the app against it
before changing the secret/endpoint used by deployment. If validation fails, retain the previous
endpoint and do not promote a divergent database.

After switching, record the last available commit and failure/recovery times to measure observed
RPO/RTO. Keep the old primary read-only until reconciliation. The dx01v2 R9 implementation provides
the app commands and gates.

## Regional runtime and recovery

DR provisions another VPC/EKS, private encrypted RDS read replica, ECR, WAF, regional ACM, SSM contract
and Velero in configurable `us-west-2`. The source remains Multi-AZ. Before an incident, install both
platforms, promote signed image digests to the secondary registry and verify the replica/current
secrets. Secrets Manager replicates existing values under regional KMS while retaining secret names;
DX overrides only `DB_HOST` with the RDS endpoint published by contract v7.

Both source and recovery S3 buckets are versioned. The replication role accesses one source bucket,
one destination and their regional keys; delete markers are not propagated. Secondary Velero reads
the recovery bucket and writes only its own backup bucket. BSL `primary-recovery` is ReadOnly.
Live replication copies new objects, not history predating configuration. Create a fresh backup,
wait for `ReplicationStatus COMPLETED` and verify the destination checksum before claiming recovery
is possible. Do not promise zero RPO.

Set `enable_state_dr=true` in bootstrap for a second versioned state copy protected against automatic
removal. Asynchronous replication does not create a second active backend. Recover the selected
version into a private directory, compare lineage/serial and fence the previous apply process
before migrating the backend. Never publish state or perform an unreviewed state push.

For the first cloud full installation, configure `LAB_VELERO_REPOSITORY_PASSWORD` as a GitHub
environment/repository Secret containing 64 random hex characters. Maintain private escrow outside
both regions. The same key is required for initial installation in both regions; a divergent key
is refused. Never rotate the Kopia key after repository creation. Velero permits root/hostPath only
for its node agent; the application stays restricted. FSB copies live files: quiesce applications
that require transactional consistency or use their native backup mechanisms. Managed PostgreSQL
continues to use separate RDS/PITR. Age-based lifecycle expiry applies only to `backups/`;
Kopia chunks depend on their own garbage collection.

Install `platform/install.sh --profile full --github-owner OWNER --target secondary` with
`AWS_REGION` set to the DR region. GitOps uses `gitops/aws-dr` and ExternalDNS starts with zero
replicas. Only after proven primary fencing, human RDS promotion and HTTPS/write smoke against the
secondary address should you repeat with `--activate-dns` or the workflow input. A second deploy
must not reactivate the primary writer.

Uninstall pauses its ExternalDNS and removes A/TXT only if the alias still points to an ALB owned by
that cluster. Another region's alias and concurrent changes are preserved. Destroy handles both
regional clusters before Terraform and inventories leftovers in both regions. For failback, reseed
from the current writer, verify lag/data, freeze writes and fence the secondary before changing the
route. Review Terraform topology after promotion; never blindly reapply replica configuration to
the new primary.

Velero age (>30 hours) and failed-restore alerts use configured Slack delivery. CloudWatch monitors
`ReplicaLag >60s` for five periods; connect the desired notification during the cloud exercise.
Missing telemetry does not establish recoverability. Record a recent isolated restore with checksums,
records and RPO/RTO. Recovery destinations use `force_destroy=false`: decide what to archive/delete
before teardown and preserve their KMS keys as well. A retained encrypted bucket is unusable if its
key is deleted. No managed operation in this round has run in AWS.

Sources: [RDS backups/PITR](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html),
[cross-region replication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReplicateBackups.html)
and [RDS pricing](https://aws.amazon.com/rds/pricing/).
