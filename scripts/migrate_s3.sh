#!/usr/bin/env bash
# ==============================================================================
# S3-to-S3 object migration wrapper (any object size, any bucket size).
# Copies Milvus backups or raw Milvus data between any two S3-compatible
# endpoints: MinIO, AWS S3, Cloudflare R2, Ceph, Wasabi, GCS (HMAC), Aliyun
# OSS, Tencent COS... Source defaults come from the BACKUP_* settings in .env.
# ==============================================================================

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/.env"
fi
# shellcheck source=../templates/backup-config-generator.sh
source "${PROJECT_ROOT}/templates/backup-config-generator.sh"

BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
optval()      { [[ $# -ge 2 ]] || { log_error "Option $1 requires a value."; exit 1; }; printf '%s' "$2"; }

# Source defaults: the backup object storage from .env (flags/env override)
SRC_ENDPOINT="$(storage_endpoint BACKUP 2>/dev/null || true):$(storage_port BACKUP 2>/dev/null || echo 9000)"
SRC_USE_SSL="$(storage_use_ssl BACKUP 2>/dev/null || echo false)"
SRC_REGION="$(sv_conn BACKUP S3_REGION us-east-1)"
SRC_BUCKET="$(storage_bucket BACKUP)"
SRC_PREFIX="$(storage_root_path BACKUP)"
SRC_ACCESS_KEY="${SRC_ACCESS_KEY:-$(sv BACKUP S3_ACCESS_KEY)}"
SRC_SECRET_KEY="${SRC_SECRET_KEY:-$(sv BACKUP S3_SECRET_KEY)}"

DST_ENDPOINT=""
DST_USE_SSL="true"
DST_REGION="us-east-1"
DST_BUCKET=""
DST_PREFIX=""
DST_ACCESS_KEY="${DST_ACCESS_KEY:-}"
DST_SECRET_KEY="${DST_SECRET_KEY:-}"

EXTRA_ARGS=()

usage() {
    cat << USAGE_EOF
${BOLD}S3-to-S3 migration${NC} (streaming, multipart, parallel, resumable; Python 3.9+ stdlib only)

Usage: $(basename "$0") [OPTIONS]

${BOLD}Source (defaults from BACKUP_* / S3_* in .env):${NC}
  --src-endpoint <host:port>   (default: ${SRC_ENDPOINT})
  --src-bucket <bucket>        (default: ${SRC_BUCKET})
  --src-prefix <prefix>        (default: ${SRC_PREFIX})
  --src-access-key <key>       (or env SRC_ACCESS_KEY)
  --src-secret-key <secret>    (or env SRC_SECRET_KEY)
  --src-region <region>        (default: ${SRC_REGION})
  --src-ssl <true|false>       (default: ${SRC_USE_SSL})

${BOLD}Destination (required):${NC}
  --dst-endpoint <host:port>   e.g. s3.us-east-1.amazonaws.com
  --dst-bucket <bucket>
  --dst-prefix <prefix>        (default: same as source prefix)
  --dst-access-key <key>       (or env DST_ACCESS_KEY, keeps it out of ps output)
  --dst-secret-key <secret>    (or env DST_SECRET_KEY)
  --dst-region <region>        (default: us-east-1)
  --dst-ssl <true|false>       (default: true)

${BOLD}Tuning:${NC}
  --workers <n>                objects copied in parallel (default: 8)
  --multipart-threshold-mib <n> multipart upload at or above this size (default: 64)
  --part-size-mib <n>          minimum part size, auto-raised for huge objects (default: 64)
  --retries <n>                attempts per request (default: 3)
  --dry-run                    list what would be copied
  -h, --help

${BOLD}Example:${NC}
  DST_ACCESS_KEY=AKIA... DST_SECRET_KEY=... $(basename "$0") \\
      --dst-endpoint s3.us-east-1.amazonaws.com --dst-bucket prod-milvus-backups

USAGE_EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src-endpoint)   SRC_ENDPOINT="$(optval "$@")"; shift 2 ;;
        --src-bucket)     SRC_BUCKET="$(optval "$@")"; shift 2 ;;
        --src-prefix)     SRC_PREFIX="$(optval "$@")"; shift 2 ;;
        --src-access-key) SRC_ACCESS_KEY="$(optval "$@")"; shift 2 ;;
        --src-secret-key) SRC_SECRET_KEY="$(optval "$@")"; shift 2 ;;
        --src-region)     SRC_REGION="$(optval "$@")"; shift 2 ;;
        --src-ssl)        SRC_USE_SSL="$(optval "$@")"; shift 2 ;;

        --dst-endpoint)   DST_ENDPOINT="$(optval "$@")"; shift 2 ;;
        --dst-bucket)     DST_BUCKET="$(optval "$@")"; shift 2 ;;
        --dst-prefix)     DST_PREFIX="$(optval "$@")"; shift 2 ;;
        --dst-access-key) DST_ACCESS_KEY="$(optval "$@")"; shift 2 ;;
        --dst-secret-key) DST_SECRET_KEY="$(optval "$@")"; shift 2 ;;
        --dst-region)     DST_REGION="$(optval "$@")"; shift 2 ;;
        --dst-ssl)        DST_USE_SSL="$(optval "$@")"; shift 2 ;;

        --workers|--multipart-threshold-mib|--part-size-mib|--retries)
                          EXTRA_ARGS+=("$1" "$(optval "$@")"); shift 2 ;;
        --dry-run)        EXTRA_ARGS+=("--dry-run"); shift ;;
        -h|--help)        usage 0 ;;
        *) log_error "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "${DST_ENDPOINT}" || -z "${DST_BUCKET}" || -z "${DST_ACCESS_KEY}" || -z "${DST_SECRET_KEY}" ]]; then
    log_error "Missing destination settings: --dst-endpoint, --dst-bucket and access/secret key (flag or DST_* env)."
    usage 1
fi

PY_ARGS=(
    --src-endpoint "${SRC_ENDPOINT}" --src-bucket "${SRC_BUCKET}" --src-prefix "${SRC_PREFIX}"
    --src-region "${SRC_REGION}" --src-ssl "${SRC_USE_SSL}"
    --dst-endpoint "${DST_ENDPOINT}" --dst-bucket "${DST_BUCKET}" --dst-prefix "${DST_PREFIX:-${SRC_PREFIX}}"
    --dst-region "${DST_REGION}" --dst-ssl "${DST_USE_SSL}"
)

log_info "Migrating s3://${SRC_BUCKET}/${SRC_PREFIX} (${SRC_ENDPOINT}) -> s3://${DST_BUCKET}/${DST_PREFIX:-${SRC_PREFIX}} (${DST_ENDPOINT})"
# Credentials go through the environment, not argv, so they never show in ps
SRC_ACCESS_KEY="${SRC_ACCESS_KEY}" SRC_SECRET_KEY="${SRC_SECRET_KEY}" \
    DST_ACCESS_KEY="${DST_ACCESS_KEY}" DST_SECRET_KEY="${DST_SECRET_KEY}" \
    python3 "${PROJECT_ROOT}/scripts/migrate_s3.py" "${PY_ARGS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

log_success "S3 migration finished."
