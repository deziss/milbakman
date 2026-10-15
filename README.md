# milbakman

**Milvus backup, restore and migration on any storage.** milbakman is a small CLI around the official [milvus-backup](https://github.com/zilliztech/milvus-backup) tool. It handles:

- generating milvus-backup configs for any storage backend
- local backup archives and retention
- deploying a target Milvus
- verifying a restore
- copying object-storage data between providers, at any object size

Everything runs in Docker. You need only `bash`, `docker` (with compose v2), `curl` and `tar` on the host, plus `python3` (3.9+) if you use the S3 migration tool.

## What it supports

| | Storage |
|---|---|
| **Milvus data** (source and target, independently) | Local disk, MinIO, AWS S3, Google Cloud Storage (HMAC or native), Azure Blob, Aliyun OSS, Tencent COS, Huawei OBS |
| **Backup destination** | Any mounted filesystem (local disk, NFS, SMB/CIFS, USB, etc.) or any of the object stores above, with its own endpoint and credentials |
| **Auth** | `static` keys (+ session token), `iam` (instance role or MinIO IAM), `default` (SDK chain), `sharedKey` (Azure), `serviceAccount` (GCS JSON key) |

Because each side is configured on its own, a backup can run between any two of them. For example: on-prem MinIO, backed up to NFS, then restored into Milvus on AWS S3. milvus-backup streams the data between backends.

## Quick start

```bash
cp .env.example .env              # edit: Milvus hosts, storage, credentials
./milvus.sh status                # health of source, target and backup storage
./milvus.sh backup --cadence daily
./milvus.sh deploy-target --reset # optional: fresh target Milvus in Docker
./milvus.sh restore --backup <name> --drop
./milvus.sh verify --compare      # entity counts: source vs target
```

There is no local Milvus to try it on? `docker compose -f docker-compose.primary.yml up -d` starts a demo source stack (Milvus, etcd and MinIO). Then run `./milvus.sh seed` to load 1,000 benchmark vectors into it.

## Configuration

Every setting lives in `.env`, and [`.env.example`](.env.example) documents each one with an example per provider. Settings resolve **per side**:

```
SOURCE_<NAME>  or  TARGET_<NAME>  or  BACKUP_<NAME>   →   falls back to shared <NAME>
```

`<NAME>` is one of:

- `S3_PROVIDER`, `S3_ENDPOINT`, `S3_PORT`, `S3_USE_SSL`, `S3_REGION`, `S3_BUCKET`
- `STORAGE_AUTH`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_SESSION_TOKEN`, `IAM_ENDPOINT`
- `AZURE_ACCOUNT_NAME`, `AZURE_ACCOUNT_KEY`, `GCP_CREDENTIALS_FILE`
- `LOCAL_DATA_DIR`, `LOCAL_MILVUS_PATH` (the `local` provider)

`<SIDE>_S3_ROOT_PATH` is never shared. Run `./milvus.sh config [source|target] [--s3]` to print the exact milvus-backup config that will be used, with secrets masked.

A few common setups:

```bash
# Milvus standalone on local disk, backups to an NFS mount
SOURCE_S3_PROVIDER=local
SOURCE_LOCAL_DATA_DIR=/srv/milvus/volumes/milvus/data
BACKUP_STORAGE=local
BACKUP_STORAGE_DIR=/mnt/nfs/milvus-backups

# Milvus on MinIO, backups off-site in AWS S3 with an instance role
BACKUP_STORAGE=s3
BACKUP_S3_PROVIDER=aws
BACKUP_S3_REGION=eu-west-1
BACKUP_S3_BUCKET=milvus-offsite
BACKUP_STORAGE_AUTH=iam

# Restore into Milvus on Azure Blob
TARGET_S3_PROVIDER=azure
TARGET_AZURE_ACCOUNT_NAME=acct
TARGET_AZURE_ACCOUNT_KEY=...
TARGET_S3_BUCKET=milvus
```

Endpoint, port and SSL default sensibly per provider: MinIO uses `localhost:9000` without SSL, AWS uses `s3.amazonaws.com`, GCS uses `storage.googleapis.com` and Azure uses `core.windows.net`, all on 443 with SSL. Aliyun, Tencent and Huawei need `S3_ENDPOINT`. If a provider/auth combination is invalid, or a credential is missing, milbakman fails before anything runs.

## Commands

| Command | What it does |
|---|---|
| `backup [-c cadence] [-n name] [-d dir] [--s3\|--local] [--filter a,b]` | Back up the source. Local backups go to `BACKUP_STORAGE_DIR/<cadence>/` as `<name>.tar.gz` (or a directory if `BACKUP_COMPRESS=none`), with a `.manifest.json`. |
| `restore -b <name\|archive\|dir> [-t target\|source] [-s suffix] [--drop] [--filter a,b] [--s3]` | Restore into the target (or source). A name is looked up locally first, then in object storage. |
| `list [--local-only\|--s3-only]` | List local and object-storage backups. |
| `prune` | Apply `RETENTION_<CADENCE>`. This also runs after every local backup. |
| `status` | Milvus health, storage summary and a `milvus-backup check`. |
| `config [source\|target] [--s3\|--local]` | Print the generated config with secrets masked. |
| `deploy-target [--reset]` / `down-target [-v]` | Start or stop a target Milvus wired to `TARGET_*` storage. With `TARGET_S3_PROVIDER=local` it bind-mounts `TARGET_LOCAL_DATA_DIR`. |
| `verify --compare [--suffix S] [--collections a,b]` | Compare entity counts per collection between source and target. |
| `verify [--collection C --count N]` / `seed` | Check, or create, the seeded benchmark collection. |

### Large backups
- Compression uses `pigz` (parallel gzip) when installed.
- `BACKUP_COMPRESS=none` keeps backups as plain directories. That skips compression time and the temporary double disk usage, which is the right choice for very large backups.
- Restores extract next to the archive, on the same filesystem, not in `/tmp`. Set `RESTORE_TMP_DIR` to choose another location.
- Tune milvus-backup with `TRANSFER_CONCURRENCY`, `BACKUP_CONCURRENCY_*` and `RESTORE_CONCURRENCY_*`.

### Retention
After each local backup, the oldest backups in that cadence folder beyond `RETENTION_<CADENCE>` are deleted. Only backups that have a `.manifest.json`, meaning ones milbakman created, are counted or deleted. Backups made with `--dest` or `manual` are never pruned, and `0` keeps everything.

### Permissions
- milvus-backup runs as your uid:gid, so root-squashed NFS works.
- It runs as root only when it must write into a local-disk Milvus data dir, which the Milvus container owns. Override with `MILVUS_BACKUP_RUN_AS`.
- Generated configs, which hold credentials, are mode 600 in a private temp dir and are removed on exit.

## Migrating object storage (any object size)

`scripts/migrate_s3.sh` copies Milvus backups or raw Milvus data between any two S3-compatible endpoints. It uses only the Python standard library.

- **Streaming:** objects go from source to destination without being held in memory or written to disk.
- **Multipart upload:** used for objects of 64 MiB or more. Part size grows automatically to stay within 10,000 parts, so any object up to the S3 maximum of 5 TiB works.
- **Parallel:** `--workers` (default 8) copies objects in parallel, and the source is listed page by page, so millions of keys use constant memory.
- **Resumable:** objects already present with the same size are skipped, transient errors are retried with backoff, and failed multipart uploads are aborted. A failed run exits non-zero and lists what failed. Re-run the same command to finish.

```bash
# Source defaults to BACKUP_* / S3_* from .env; credentials via env stay out of `ps`
DST_ACCESS_KEY=AKIA... DST_SECRET_KEY=... ./scripts/migrate_s3.sh \
    --dst-endpoint s3.us-east-1.amazonaws.com --dst-bucket prod-milvus-backups

./scripts/migrate_s3.sh --help   # all flags, including --dry-run, --workers, --part-size-mib
```

Uploads interrupted by a hard kill can leave incomplete multipart parts behind. On AWS, add a lifecycle rule ("abort incomplete multipart uploads after N days") to clean them up.

Migrating a whole Milvus deployment between object stores doesn't need this tool. Back up from the old storage and restore into a target configured with the new storage (`TARGET_*`), and milvus-backup moves the data.

## Project layout

```
milvus.sh                           CLI entry point
templates/backup-config-generator.sh  storage resolution + milvus-backup config generation
scripts/migrate_s3.py / .sh         S3-to-S3 migration (multipart, parallel, resumable)
scripts/seed_benchmark.py           benchmark data for testing
scripts/verify_restore.py           restore verification (used by `verify`)
docker-compose.target.yml           target Milvus (+ .local.yml override for local-disk storage)
docker-compose.primary.yml          demo source stack (Milvus + etcd + MinIO)
Dockerfile.milvus-client            pymilvus image for verify/seed
```

## Limitations

- **Host networking:** containers use `--network host`. On Docker Desktop (macOS/Windows), enable host networking in its settings.
- **`deploy-target` on native GCS:** it cannot inject a GCS service-account JSON key into the target Milvus. Use provider `gcp` with HMAC keys, or `STORAGE_AUTH=default`. Backup and restore themselves support `serviceAccount`.
- **No TLS options:** Milvus gRPC TLS and etcd TLS aren't exposed yet. Set them in a custom milvus-backup config if you need them.
- **Version pairing:** tested with Milvus 2.4.x and milvus-backup v0.6.0.

## License

[GNU AGPL v3.0](LICENSE)
