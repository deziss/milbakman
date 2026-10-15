#!/usr/bin/env bash
# ==============================================================================
# milvus-backup configuration generator and storage helpers.
#
# Sourced by milvus.sh (functions only), or run directly:
#   backup-config-generator.sh <source|target> <output.yaml> [local|s3] [container_backup_path]
#
# Storage settings resolve per side: <SIDE>_<NAME> overrides the shared <NAME>.
#   SIDE = SOURCE | TARGET | BACKUP
#   NAME = S3_PROVIDER S3_ENDPOINT S3_PORT S3_USE_SSL S3_REGION S3_BUCKET
#          STORAGE_AUTH S3_ACCESS_KEY S3_SECRET_KEY S3_SESSION_TOKEN IAM_ENDPOINT
#          AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY GCP_CREDENTIALS_FILE
#          LOCAL_DATA_DIR LOCAL_MILVUS_PATH                (provider "local" only)
# <SIDE>_S3_ROOT_PATH is never shared: each side keeps its own prefix.
#
# Providers: local minio s3 aws gcp gcpnative azure aliyun tencent hwc
# Auth:      static iam default sharedKey (azure) serviceAccount (gcpnative)
# Written for bash 3.2+ (macOS) as well as Linux.
# ==============================================================================

STORAGE_PROVIDERS="local minio s3 aws gcp gcpnative azure aliyun tencent hwc"
CONTAINER_GCP_DIR="/run/milbakman"

storage_error() { printf '[ERROR] %s\n' "$*" >&2; }

# sv SIDE NAME [default] -> <SIDE>_<NAME>, else <NAME>, else default
sv() {
    local side_var="${1}_${2}" base_var="${2}"
    if [[ -n "${!side_var:-}" ]]; then
        printf '%s' "${!side_var}"
    elif [[ -n "${!base_var:-}" ]]; then
        printf '%s' "${!base_var}"
    else
        printf '%s' "${3:-}"
    fi
}

# Like sv, but a side whose provider differs from the shared S3_PROVIDER does not
# inherit the shared endpoint/port/SSL/region (they belong to another provider)
sv_conn() {
    local side_var="${1}_${2}"
    if [[ -n "${!side_var:-}" ]]; then
        printf '%s' "${!side_var}"
    elif [[ "$(side_lower "$(sv "$1" S3_PROVIDER minio)")" != "$(side_lower "${S3_PROVIDER:-minio}")" ]]; then
        printf '%s' "${3:-}"
    else
        sv "$1" "$2" "${3:-}"
    fi
}

# Relative paths resolve against the project root (or CWD when run standalone)
abs_path() {
    if [[ "$1" == /* ]]; then
        printf '%s' "$1"
    else
        printf '%s' "${PROJECT_ROOT:-${PWD}}/${1#./}"
    fi
}

side_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Double-quoted YAML scalar
yaml_q() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

storage_provider() {
    local p
    p="$(side_lower "$(sv "$1" S3_PROVIDER minio)")"
    case " ${STORAGE_PROVIDERS} " in
        *" ${p} "*) printf '%s' "${p}" ;;
        *) storage_error "$1: unknown storage provider '${p}' (valid: ${STORAGE_PROVIDERS})"; return 1 ;;
    esac
}

storage_endpoint() {
    local provider
    provider="$(storage_provider "$1")" || return 1
    local def=""
    case "${provider}" in
        minio)         def="localhost" ;;
        aws|s3)        def="s3.amazonaws.com" ;;
        gcp|gcpnative) def="storage.googleapis.com" ;;
        azure)         def="core.windows.net" ;;
    esac
    local ep
    ep="$(sv_conn "$1" S3_ENDPOINT "${def}")"
    if [[ -z "${ep}" ]]; then
        storage_error "$1: S3_ENDPOINT is required for provider '${provider}'"
        return 1
    fi
    printf '%s' "${ep}"
}

storage_port() {
    local provider def=443
    provider="$(storage_provider "$1")" || return 1
    [[ "${provider}" == "minio" ]] && def=9000
    local port
    port="$(sv_conn "$1" S3_PORT "${def}")"
    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
        storage_error "$1: S3_PORT must be a number (got '${port}')"
        return 1
    fi
    printf '%s' "${port}"
}

storage_use_ssl() {
    local provider def=true
    provider="$(storage_provider "$1")" || return 1
    [[ "${provider}" == "minio" ]] && def=false
    local v
    v="$(side_lower "$(sv_conn "$1" S3_USE_SSL "${def}")")"
    case "${v}" in
        true|false) printf '%s' "${v}" ;;
        *) storage_error "$1: S3_USE_SSL must be true or false (got '${v}')"; return 1 ;;
    esac
}

storage_bucket() { sv "$1" S3_BUCKET a-bucket; }

storage_root_path() {
    local var="${1}_S3_ROOT_PATH" def
    case "$1" in
        SOURCE) def="files" ;;
        TARGET) def="target-files" ;;
        BACKUP) def="milvus-backups" ;;
    esac
    printf '%s' "${!var:-${def}}"
}

gcp_container_path() { printf '%s/%s-gcp-credentials.json' "${CONTAINER_GCP_DIR}" "$(side_lower "$1")"; }

# Resolves and validates the auth type for a side ("none" for provider local)
storage_auth() {
    local side="$1" provider auth
    provider="$(storage_provider "${side}")" || return 1
    if [[ "${provider}" == "local" ]]; then
        printf 'none'
        return 0
    fi

    auth="$(sv "${side}" STORAGE_AUTH)"
    if [[ -z "${auth}" ]]; then
        case "${provider}" in
            azure) auth="sharedKey" ;;
            gcpnative)
                if [[ -n "$(sv "${side}" GCP_CREDENTIALS_FILE)" ]]; then auth="serviceAccount"; else auth="default"; fi ;;
            *) auth="static" ;;
        esac
    fi

    case "${provider}:${auth}" in
        azure:sharedKey|azure:iam|azure:default) ;;
        gcpnative:serviceAccount|gcpnative:iam|gcpnative:default) ;;
        azure:*|gcpnative:*)
            storage_error "${side}: provider '${provider}' does not support auth '${auth}'"
            return 1 ;;
        *:static|*:iam|*:default) ;;
        *:sharedKey) storage_error "${side}: auth 'sharedKey' is only valid for provider azure"; return 1 ;;
        *:serviceAccount) storage_error "${side}: auth 'serviceAccount' is only valid for provider gcpnative"; return 1 ;;
        *) storage_error "${side}: unknown auth '${auth}' (valid: static iam default sharedKey serviceAccount)"; return 1 ;;
    esac

    if [[ "${provider}" == "azure" && -z "$(sv "${side}" AZURE_ACCOUNT_NAME)" ]]; then
        storage_error "${side}: AZURE_ACCOUNT_NAME is required for provider azure"
        return 1
    fi
    case "${auth}" in
        static)
            if [[ -z "$(sv "${side}" S3_ACCESS_KEY)" || -z "$(sv "${side}" S3_SECRET_KEY)" ]]; then
                storage_error "${side}: S3_ACCESS_KEY and S3_SECRET_KEY are required for auth 'static'"
                return 1
            fi ;;
        sharedKey)
            if [[ -z "$(sv "${side}" AZURE_ACCOUNT_KEY)" ]]; then
                storage_error "${side}: AZURE_ACCOUNT_KEY is required for auth 'sharedKey'"
                return 1
            fi ;;
        serviceAccount)
            local creds
            creds="$(sv "${side}" GCP_CREDENTIALS_FILE)"
            if [[ -z "${creds}" || ! -r "$(abs_path "${creds}")" ]]; then
                storage_error "${side}: GCP_CREDENTIALS_FILE '${creds}' is missing or unreadable (auth 'serviceAccount')"
                return 1
            fi ;;
    esac
    printf '%s' "${auth}"
}

# Host directory of a local-provider Milvus storage root
storage_local_dir() {
    local d
    d="$(sv "$1" LOCAL_DATA_DIR)"
    if [[ -z "${d}" ]]; then
        storage_error "$1: ${1}_LOCAL_DATA_DIR is required when the provider is 'local'"
        return 1
    fi
    abs_path "${d}"
}

# emit_storage_block SIDE -> YAML body of a storage map (4-space indent)
emit_storage_block() {
    local side="$1" provider auth
    provider="$(storage_provider "${side}")" || return 1
    auth="$(storage_auth "${side}")" || return 1

    printf '    provider: %s\n' "$(yaml_q "${provider}")"
    if [[ "${provider}" == "local" ]]; then
        local dir
        dir="$(storage_local_dir "${side}")" || return 1
        printf '    rootPath: %s\n' "$(yaml_q "${dir}")"
        printf '    localPath: %s\n' "$(yaml_q "$(sv "${side}" LOCAL_MILVUS_PATH /var/lib/milvus/data)")"
        return 0
    fi

    local endpoint port use_ssl
    endpoint="$(storage_endpoint "${side}")" || return 1
    port="$(storage_port "${side}")" || return 1
    use_ssl="$(storage_use_ssl "${side}")" || return 1

    printf '    address: %s\n' "$(yaml_q "${endpoint}")"
    printf '    port: %s\n' "${port}"
    printf '    region: %s\n' "$(yaml_q "$(sv_conn "${side}" S3_REGION us-east-1)")"
    printf '    useSSL: %s\n' "${use_ssl}"
    if [[ "${provider}" == "azure" ]]; then
        printf '    accountName: %s\n' "$(yaml_q "$(sv "${side}" AZURE_ACCOUNT_NAME)")"
    fi
    printf '    bucketName: %s\n' "$(yaml_q "$(storage_bucket "${side}")")"
    printf '    rootPath: %s\n' "$(yaml_q "$(storage_root_path "${side}")")"
    printf '    auth:\n'
    printf '      type: %s\n' "${auth}"
    case "${auth}" in
        static)
            printf '      accessKeyID: %s\n' "$(yaml_q "$(sv "${side}" S3_ACCESS_KEY)")"
            printf '      secretAccessKey: %s\n' "$(yaml_q "$(sv "${side}" S3_SECRET_KEY)")"
            local token
            token="$(sv "${side}" S3_SESSION_TOKEN)"
            if [[ -n "${token}" ]]; then
                printf '      sessionToken: %s\n' "$(yaml_q "${token}")"
            fi ;;
        iam)
            local iam_ep
            iam_ep="$(sv "${side}" IAM_ENDPOINT)"
            if [[ -n "${iam_ep}" ]]; then
                printf '      endpoint: %s\n' "$(yaml_q "${iam_ep}")"
            fi ;;
        sharedKey)
            printf '      accountKey: %s\n' "$(yaml_q "$(sv "${side}" AZURE_ACCOUNT_KEY)")" ;;
        serviceAccount)
            printf '      credentialsFile: %s\n' "$(yaml_q "$(gcp_container_path "${side}")")" ;;
    esac
}

# generate_config <source|target> <output> <local|s3> [container_backup_path]
generate_config() {
    local mode="$1" output="$2" backup_storage="${3:-local}" local_backup_path="${4:-/var/lib/milvus-backup}"
    local side host port mgmt etcd
    if [[ "${mode}" == "target" ]]; then
        side="TARGET"
        host="${TARGET_MILVUS_HOST:-localhost}"
        port="${TARGET_MILVUS_PORT:-19540}"
        mgmt="${TARGET_MILVUS_MGMT_PORT:-9092}"
        etcd="${TARGET_MILVUS_ETCD:-127.0.0.1:2389}"
    else
        side="SOURCE"
        host="${SOURCE_MILVUS_HOST:-localhost}"
        port="${SOURCE_MILVUS_PORT:-19530}"
        mgmt="${SOURCE_MILVUS_MGMT_PORT:-9091}"
        etcd="${SOURCE_MILVUS_ETCD:-127.0.0.1:2379}"
    fi

    local milvus_storage backup_block
    milvus_storage="$(emit_storage_block "${side}")" || return 1

    if [[ "${backup_storage}" == "s3" ]]; then
        local backup_provider
        backup_provider="$(storage_provider BACKUP)" || return 1
        if [[ "${backup_provider}" == "local" ]]; then
            storage_error "S3 backup storage needs an object-storage provider; set BACKUP_S3_PROVIDER (shared S3_PROVIDER is 'local')"
            return 1
        fi
        backup_block="$(emit_storage_block BACKUP)" || return 1
    else
        backup_block="$(printf '    provider: "local"\n    rootPath: %s' "$(yaml_q "${local_backup_path}")")"
    fi

    (
        umask 077
        cat > "${output}" << YAML_EOF
configVersion: v2

log:
  level: ${MILVUS_BACKUP_LOG_LEVEL:-info}
  console: true
  file:
    path: "/tmp/backup.log"

server:
  debugMode: false

milvus:
  user: $(yaml_q "${MILVUS_USER:-root}")
  password: $(yaml_q "${MILVUS_PASSWORD:-Milvus}")
  grpc:
    address: $(yaml_q "${host}")
    port: ${port}
  management:
    endpoint: $(yaml_q "http://${host}:${mgmt}")
  etcd:
    endpoints:
      - $(yaml_q "${etcd}")
    rootPath: $(yaml_q "${MILVUS_ETCD_ROOT_PATH:-by-dev}")
  storage:
${milvus_storage}

backup:
  storage:
${backup_block}
  concurrency:
    collections: ${BACKUP_CONCURRENCY_COLLECTIONS:-4}
    segments: ${BACKUP_CONCURRENCY_SEGMENTS:-1024}
  pauseGC: true

restore:
  concurrency:
    collections: ${RESTORE_CONCURRENCY_COLLECTIONS:-2}
    importJobs: ${RESTORE_CONCURRENCY_IMPORT_JOBS:-768}
  maxSegmentsPerImportJob: 256
  keepTempFiles: false

transfer:
  mode: auto
  concurrency: ${TRANSFER_CONCURRENCY:-128}
  multipartCopyThresholdMiB: 500
YAML_EOF
    )
    # Contains credentials: owner-only
    if [[ -f "${output}" ]]; then
        chmod 600 "${output}"
    fi
}

# Print a generated config with every secret masked
mask_config() {
    sed -E 's/^([[:space:]]*(password|accessKeyID|secretAccessKey|sessionToken|accountKey):).*/\1 "****"/' "$1"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    generate_config "${1:-source}" "${2:-/dev/stdout}" "${3:-local}" "${4:-/var/lib/milvus-backup}"
fi
