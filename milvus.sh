#!/usr/bin/env bash
# ==============================================================================
# milbakman - Milvus backup, restore & migration CLI (wraps milvus-backup)
#
# Milvus storage (source and target, independently): local disk, MinIO, AWS S3,
#   GCS (HMAC or native), Azure Blob, Aliyun OSS, Tencent COS, Huawei OBS.
# Backup storage: any mounted filesystem (local, NFS, SMB, USB...) or any of
#   the object stores above, with its own endpoint and credentials.
# ==============================================================================

set -Eeuo pipefail

MILBAKMAN_VERSION="1.0.0"
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Load .env and export it (set -a) so docker compose and child tools see it
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/.env"
    set +a
fi

# shellcheck source=templates/backup-config-generator.sh
source "${PROJECT_ROOT}/templates/backup-config-generator.sh"

BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()         { log_error "$*"; exit 1; }
# Value of an option ("$1" "$2" ...); fails cleanly when the value is missing
optval()      { [[ $# -ge 2 ]] || die "Option $1 requires a value."; printf '%s' "$2"; }

MILVUS_BACKUP_IMAGE="${MILVUS_BACKUP_IMAGE:-milvusdb/milvus-backup:v0.6.0}"
CLIENT_IMAGE="${CLIENT_IMAGE:-milvus-client:latest}"
CONTAINER_BACKUP_PATH="/var/lib/milvus-backup"
DEST_ROOT="$(abs_path "${BACKUP_STORAGE_DIR:-backups}")"

# Generated configs hold credentials: keep temp files private and remove
# everything in CLEANUP_PATHS on any exit, including failures.
umask 077
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/milbakman.XXXXXX")"
CLEANUP_PATHS=("${TMP_DIR}")
cleanup() { rm -rf -- "${CLEANUP_PATHS[@]}" 2>/dev/null || true; }
trap cleanup EXIT

usage() {
    cat << USAGE_EOF
${BOLD}milbakman ${MILBAKMAN_VERSION}${NC} - Milvus backup, restore & migration (any filesystem, any object store)

Usage: $(basename "$0") <COMMAND> [OPTIONS]

${BOLD}Commands:${NC}
  ${CYAN}backup${NC}         Back up the source Milvus
                 -c, --cadence <hourly|daily|weekly|monthly|manual>
                 -n, --name <name>            (letters, digits, _; default: milvus_<cadence>_<timestamp>)
                 -d, --dest <dir>             (any local/NFS/SMB path; default: BACKUP_STORAGE_DIR/<cadence>)
                 --s3 | --local               (override BACKUP_STORAGE)
                 --filter <coll1,coll2>

  ${CYAN}restore${NC}        Restore a backup into the target (or source) Milvus
                 -b, --backup <name|archive.tar.gz|directory>   (required)
                 -t, --target <target|source> (default: target)
                 -s, --suffix <suffix>        (e.g. _restored)
                 --drop                       (drop existing collections first)
                 --filter <coll1,coll2>
                 --s3                         (skip local lookup, restore from object storage)

  ${CYAN}list${NC}           List local and object-storage backups   [--local-only | --s3-only]
  ${CYAN}prune${NC}          Apply RETENTION_<CADENCE> to local backups (also runs after each backup)
  ${CYAN}status${NC}         Health of source, target and backup storage
  ${CYAN}config${NC}         Print the generated milvus-backup config, secrets masked
                 [source|target] [--s3|--local]
  ${CYAN}deploy-target${NC}  Start a fresh target Milvus in Docker on TARGET_* storage   [--reset]
  ${CYAN}down-target${NC}    Stop the target Milvus stack   [-v to remove its volumes]
  ${CYAN}verify${NC}         Check restored data
                 --compare [--suffix S] [--collections a,b]  (entity counts: source vs target)
                 or: --collection C --count N                (seeded benchmark check)
                 --host/--port (target), --source-host/--source-port
  ${CYAN}seed${NC}           Insert benchmark vectors   [--host H --port P --collection C --count N]

${BOLD}Examples:${NC}
  $(basename "$0") backup --cadence daily
  $(basename "$0") backup --s3 --name nightly_01
  $(basename "$0") deploy-target --reset
  $(basename "$0") restore --backup nightly_01 --drop
  $(basename "$0") verify --compare

USAGE_EOF
    exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
validate_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "Invalid backup name '$1': use letters, digits and '_' (must not start with a digit)."
}

validate_cadence() {
    case "$1" in
        hourly|daily|weekly|monthly|manual) ;;
        *) die "Invalid cadence '$1' (hourly, daily, weekly, monthly, manual)." ;;
    esac
}

validate_backup_storage() {
    case "$1" in
        local|s3) ;;
        *) die "BACKUP_STORAGE must be 'local' or 's3' (got '$1')." ;;
    esac
}

# Create (if needed) and print the absolute, symlink-resolved path of a directory
make_abs_dir() {
    mkdir -p -- "$1" || die "Cannot create directory: $1"
    (cd -- "$1" && pwd -P)
}

json_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

have() { command -v "$1" >/dev/null 2>&1; }

side_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Container user: the caller's uid:gid (works on root_squash NFS), except when
# milvus-backup must write into a local-disk Milvus data dir owned by root.
container_user() {
    local side="$1" data_mode="$2"
    if [[ -n "${MILVUS_BACKUP_RUN_AS:-}" ]]; then
        printf '%s' "${MILVUS_BACKUP_RUN_AS}"
    elif [[ "${data_mode}" == "rw" && "$(storage_provider "${side}")" == "local" ]]; then
        printf '0:0'
    else
        printf '%s:%s' "$(id -u)" "$(id -g)"
    fi
}

# Append docker -v flags for a side's storage (local data dir, GCP key file)
add_storage_mounts() {
    local side="$1" mode="$2" provider auth
    provider="$(storage_provider "${side}")" || return 1
    if [[ "${provider}" == "local" ]]; then
        local dir
        dir="$(storage_local_dir "${side}")" || return 1
        [[ -d "${dir}" ]] || { log_error "${side}_LOCAL_DATA_DIR does not exist: ${dir}"; return 1; }
        DOCKER_ARGS+=(-v "${dir}:${dir}:${mode}")
        return 0
    fi
    auth="$(storage_auth "${side}")" || return 1
    if [[ "${auth}" == "serviceAccount" ]]; then
        DOCKER_ARGS+=(-v "$(abs_path "$(sv "${side}" GCP_CREDENTIALS_FILE)"):$(gcp_container_path "${side}"):ro")
    fi
}

# backup_tool <source|target> <local|s3> <ro|rw> <host_backup_dir> <ro|rw> <milvus-backup args...>
#   arg 3: access to the Milvus data side, arg 4/5: local backup dir mount (local mode)
backup_tool() {
    local mode="$1" backup_storage="$2" data_mode="$3" host_backup_dir="$4" backup_dir_mode="$5"
    shift 5
    local side cfg user
    side="$(side_upper "${mode}")"
    cfg="${TMP_DIR}/backup.yaml"
    generate_config "${mode}" "${cfg}" "${backup_storage}" "${CONTAINER_BACKUP_PATH}" || exit 1
    user="$(container_user "${side}" "${data_mode}")" || exit 1

    DOCKER_ARGS=(run --rm --network host --user "${user}" -v "${cfg}:/app/backup.yaml:ro")
    add_storage_mounts "${side}" "${data_mode}" || exit 1
    if [[ "${backup_storage}" == "s3" ]]; then
        add_storage_mounts BACKUP ro || exit 1
    elif [[ -n "${host_backup_dir}" ]]; then
        DOCKER_ARGS+=(-v "${host_backup_dir}:${CONTAINER_BACKUP_PATH}:${backup_dir_mode}")
    fi
    DOCKER_ARGS+=(--entrypoint /app/milvus-backup "${MILVUS_BACKUP_IMAGE}" "$@" --config /app/backup.yaml)
    docker "${DOCKER_ARGS[@]}"
}

describe_storage() {
    local side="$1" provider
    provider="$(storage_provider "${side}")" || return 1
    if [[ "${provider}" == "local" ]]; then
        printf 'local:%s' "$(storage_local_dir "${side}")"
    else
        printf '%s://%s/%s' "${provider}" "$(storage_bucket "${side}")" "$(storage_root_path "${side}")"
    fi
}

# ------------------------------------------------------------------------------
# backup
# ------------------------------------------------------------------------------
cmd_backup() {
    local cadence="${DEFAULT_CADENCE:-daily}" backup_name="" custom_dest="" storage="${BACKUP_STORAGE:-local}" filter_colls=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--cadence) cadence="$(optval "$@")"; shift 2 ;;
            -n|--name)    backup_name="$(optval "$@")"; shift 2 ;;
            -d|--dest)    custom_dest="$(optval "$@")"; shift 2 ;;
            --s3)         storage="s3"; shift ;;
            --local)      storage="local"; shift ;;
            --filter)     filter_colls="$(optval "$@")"; shift 2 ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done

    validate_cadence "${cadence}"
    validate_backup_storage "${storage}"
    [[ -n "${backup_name}" ]] || backup_name="milvus_${cadence}_$(date +'%Y%m%d_%H%M%S')"
    validate_name "${backup_name}"

    local create_args=(create -n "${backup_name}")
    [[ -z "${filter_colls}" ]] || create_args+=(--filter "${filter_colls}")

    if [[ "${storage}" == "s3" ]]; then
        log_info "Backup '${backup_name}' -> $(describe_storage BACKUP)"
        backup_tool source s3 ro "" "" "${create_args[@]}" \
            || die "milvus-backup failed (exit $?); backup '${backup_name}' FAILED."
        log_success "Backup stored in object storage: ${backup_name}"
        return 0
    fi

    local target_dir
    if [[ -n "${custom_dest}" ]]; then
        target_dir="$(make_abs_dir "${custom_dest}")"
    else
        target_dir="$(make_abs_dir "${DEST_ROOT}/${cadence}")"
    fi
    if [[ -e "${target_dir}/${backup_name}" || -e "${target_dir}/${backup_name}.tar.gz" ]]; then
        die "A backup named '${backup_name}' already exists in ${target_dir}."
    fi

    log_info "Backup '${backup_name}' from $(describe_storage SOURCE) -> ${target_dir}"
    local rc=0
    backup_tool source local ro "${target_dir}" rw "${create_args[@]}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        rm -rf -- "${target_dir:?}/${backup_name:?}" 2>/dev/null \
            || log_warn "Could not remove partial backup ${target_dir}/${backup_name}"
        die "milvus-backup failed (exit ${rc}); backup '${backup_name}' FAILED."
    fi

    [[ -d "${target_dir}/${backup_name}" ]] \
        || die "milvus-backup exited without writing ${target_dir}/${backup_name}; backup FAILED."

    finalize_local_backup "${target_dir}" "${backup_name}" "${cadence}"

    # Retention applies only to the managed cadence folders, never to a custom --dest
    if [[ -z "${custom_dest}" ]]; then
        prune_local "${target_dir}" "${cadence}"
    fi
}

# Compress (optional) and write the manifest for a finished local backup
finalize_local_backup() {
    local dir="$1" name="$2" cadence="$3" format artifact
    case "${BACKUP_COMPRESS:-gzip}" in
        none)
            format="dir"
            artifact="${name}" ;;
        gzip)
            format="tar.gz"
            artifact="${name}.tar.gz"
            local partial="${dir}/.${artifact}.partial"
            CLEANUP_PATHS+=("${partial}")
            if have pigz; then
                log_info "Packaging into ${artifact} (pigz)..."
                tar -C "${dir}" -cf - "${name}" | pigz > "${partial}"
            else
                log_info "Packaging into ${artifact} (gzip; install pigz for parallel compression)..."
                tar -C "${dir}" -czf "${partial}" "${name}"
            fi
            mv -- "${partial}" "${dir}/${artifact}"
            rm -rf -- "${dir:?}/${name:?}" ;;
        *) die "BACKUP_COMPRESS must be 'gzip' or 'none' (got '${BACKUP_COMPRESS}')." ;;
    esac

    local size
    size="$(du -sh "${dir}/${artifact}" | awk '{print $1}')"
    cat > "${dir}/${name}.manifest.json" << MANIFEST_EOF
{
  "backup_name": "$(json_escape "${name}")",
  "cadence": "$(json_escape "${cadence}")",
  "created_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "format": "${format}",
  "artifact": "$(json_escape "${artifact}")",
  "size": "$(json_escape "${size}")",
  "source_milvus": "$(json_escape "${SOURCE_MILVUS_HOST:-localhost}:${SOURCE_MILVUS_PORT:-19530}")",
  "source_storage": "$(json_escape "$(describe_storage SOURCE)")",
  "tool": "milbakman ${MILBAKMAN_VERSION}"
}
MANIFEST_EOF
    log_success "Local backup completed: ${dir}/${artifact} (${size})"
}

# Keep the newest RETENTION_<CADENCE> backups in a cadence folder. Only backups
# with a .manifest.json (created by this tool) are counted or deleted.
prune_local() {
    local dir="$1" cadence="$2" keep
    case "${cadence}" in
        hourly)  keep="${RETENTION_HOURLY:-24}" ;;
        daily)   keep="${RETENTION_DAILY:-7}" ;;
        weekly)  keep="${RETENTION_WEEKLY:-4}" ;;
        monthly) keep="${RETENTION_MONTHLY:-12}" ;;
        *) return 0 ;;
    esac
    if ! [[ "${keep}" =~ ^[0-9]+$ ]]; then
        log_warn "Retention for '${cadence}' is not a number ('${keep}'); skipping prune."
        return 0
    fi
    [[ "${keep}" -gt 0 ]] || return 0

    local manifests=() newest=() m i base
    shopt -s nullglob
    manifests=("${dir}"/*.manifest.json)
    shopt -u nullglob
    [[ "${#manifests[@]}" -gt "${keep}" ]] || return 0

    # Names are validated ([A-Za-z0-9_]), so parsing ls output is safe here
    while IFS= read -r m; do
        newest+=("${m}")
    done < <(ls -1t -- "${manifests[@]}")

    for (( i = keep; i < ${#newest[@]}; i++ )); do
        base="${newest[i]%.manifest.json}"
        log_info "Retention (${cadence}, keep ${keep}): removing $(basename "${base}")"
        rm -rf -- "${base}.tar.gz" "${base}" "${newest[i]}" \
            || log_warn "Could not fully remove ${base} (permissions?)"
    done
}

cmd_prune() {
    local cadence
    for cadence in hourly daily weekly monthly; do
        if [[ -d "${DEST_ROOT}/${cadence}" ]]; then
            prune_local "${DEST_ROOT}/${cadence}" "${cadence}"
        fi
    done
    log_success "Local retention applied under ${DEST_ROOT}."
}

# ------------------------------------------------------------------------------
# restore
# ------------------------------------------------------------------------------
# Extract next to the archive (same filesystem, room for big backups) unless
# RESTORE_TMP_DIR is set; fall back to the private temp dir if not writable.
make_restore_dir() {
    local parent="${RESTORE_TMP_DIR:-$1}"
    RESTORE_EXTRACT_DIR="$(mktemp -d "${parent}/.restore-XXXXXX" 2>/dev/null)" || {
        log_warn "${parent} is not writable; extracting under ${TMP_DIR} instead."
        RESTORE_EXTRACT_DIR="$(mktemp -d "${TMP_DIR}/restore-XXXXXX")"
    }
    CLEANUP_PATHS+=("${RESTORE_EXTRACT_DIR}")
}

# Sets FOUND_BACKUP_DIR (directory to mount) and FOUND_BACKUP_NAME, or leaves them empty
resolve_local_backup() {
    local input="$1" archive="" dir=""
    FOUND_BACKUP_DIR=""
    FOUND_BACKUP_NAME=""

    if [[ -f "${input}" && "${input}" == *.tar.gz ]]; then
        archive="${input}"
    elif [[ -d "${input}" ]]; then
        dir="${input}"
    else
        local name
        name="$(basename -- "${input}" .tar.gz)"
        validate_name "${name}"
        if [[ -d "${DEST_ROOT}" ]]; then
            archive="$(find "${DEST_ROOT}" -mindepth 1 -maxdepth 2 -type f -name "${name}.tar.gz" 2>/dev/null | head -n 1 || true)"
            if [[ -z "${archive}" ]]; then
                dir="$(find "${DEST_ROOT}" -mindepth 1 -maxdepth 2 -type d -name "${name}" 2>/dev/null | head -n 1 || true)"
            fi
        fi
    fi

    if [[ -n "${archive}" ]]; then
        make_restore_dir "$(cd -- "$(dirname -- "${archive}")" && pwd -P)"
        log_info "Extracting $(basename -- "${archive}") into ${RESTORE_EXTRACT_DIR}..."
        if have pigz; then
            pigz -dc -- "${archive}" | tar -C "${RESTORE_EXTRACT_DIR}" -xf -
        else
            tar -C "${RESTORE_EXTRACT_DIR}" -xzf "${archive}"
        fi
        local entries=("${RESTORE_EXTRACT_DIR}"/*)
        if [[ "${#entries[@]}" -ne 1 || ! -d "${entries[0]}" ]]; then
            die "Archive ${archive} must contain exactly one backup directory."
        fi
        FOUND_BACKUP_DIR="${RESTORE_EXTRACT_DIR}"
        FOUND_BACKUP_NAME="$(basename -- "${entries[0]}")"
    elif [[ -n "${dir}" ]]; then
        FOUND_BACKUP_DIR="$(cd -- "$(dirname -- "${dir}")" && pwd -P)"
        FOUND_BACKUP_NAME="$(basename -- "${dir}")"
    fi
}

cmd_restore() {
    local backup_input="" target_mode="target" suffix="" drop=false filter_colls="" force_s3=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--backup) backup_input="$(optval "$@")"; shift 2 ;;
            -t|--target) target_mode="$(optval "$@")"; shift 2 ;;
            -s|--suffix) suffix="$(optval "$@")"; shift 2 ;;
            --drop)      drop=true; shift ;;
            --filter)    filter_colls="$(optval "$@")"; shift 2 ;;
            --s3)        force_s3=true; shift ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done

    [[ -n "${backup_input}" ]] || { log_error "Missing required argument: -b / --backup"; usage 1; }
    case "${target_mode}" in
        target|source) ;;
        *) die "--target must be 'target' or 'source' (got '${target_mode}')." ;;
    esac

    local restore_args=(--rebuild_index)
    [[ -z "${suffix}" ]] || restore_args+=(-s "${suffix}")
    [[ "${drop}" != "true" ]] || restore_args+=(--drop_exist_collection)
    [[ -z "${filter_colls}" ]] || restore_args+=(--filter "${filter_colls}")

    local side
    side="$(side_upper "${target_mode}")"

    if [[ "${force_s3}" == "false" ]]; then
        resolve_local_backup "${backup_input}"
        if [[ -n "${FOUND_BACKUP_NAME}" ]]; then
            validate_name "${FOUND_BACKUP_NAME}"
            log_info "Restore '${FOUND_BACKUP_NAME}' from ${FOUND_BACKUP_DIR} -> ${target_mode} ($(describe_storage "${side}"))"
            backup_tool "${target_mode}" local rw "${FOUND_BACKUP_DIR}" ro restore -n "${FOUND_BACKUP_NAME}" "${restore_args[@]}" \
                || die "milvus-backup failed (exit $?); restore of '${FOUND_BACKUP_NAME}' FAILED."
            log_success "Backup '${FOUND_BACKUP_NAME}' restored into ${target_mode} Milvus."
            return 0
        fi
        log_warn "No local backup '${backup_input}' found under ${DEST_ROOT}; trying object storage."
    fi

    local backup_name
    backup_name="$(basename -- "${backup_input}" .tar.gz)"
    validate_name "${backup_name}"
    log_info "Restore '${backup_name}' from $(describe_storage BACKUP) -> ${target_mode} ($(describe_storage "${side}"))"
    backup_tool "${target_mode}" s3 rw "" "" restore -n "${backup_name}" "${restore_args[@]}" \
        || die "milvus-backup failed (exit $?); restore of '${backup_name}' FAILED."
    log_success "Backup '${backup_name}' restored into ${target_mode} Milvus."
}

# ------------------------------------------------------------------------------
# list / status / config
# ------------------------------------------------------------------------------
cmd_list() {
    local show_local=true show_s3=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-only) show_s3=false; shift ;;
            --s3-only)    show_local=false; shift ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done

    if [[ "${show_local}" == "true" ]]; then
        printf "\n${BOLD}=== Local backups (%s) ===${NC}\n" "${DEST_ROOT}"
        printf "%-10s %-40s %-10s %-20s\n" "CADENCE" "BACKUP" "SIZE" "MODIFIED"
        printf '%s\n' "--------------------------------------------------------------------------------"
        local found=0 f
        if [[ -d "${DEST_ROOT}" ]]; then
            while IFS= read -r f; do
                [[ -n "${f}" ]] || continue
                # An extracted directory next to its own archive is not a separate backup
                if [[ -d "${f}" && -e "${f}.tar.gz" ]]; then
                    continue
                fi
                printf "%-10s %-40s %-10s %-20s\n" \
                    "$(basename -- "$(dirname -- "${f}")")" \
                    "$(basename -- "${f}")" \
                    "$(du -sh "${f}" 2>/dev/null | awk '{print $1}')" \
                    "$(date -r "${f}" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
                found=$((found + 1))
            done < <(find "${DEST_ROOT}" -mindepth 2 -maxdepth 2 ! -name '.*' \( -type f -name '*.tar.gz' -o -type d \) 2>/dev/null | sort -r)
        fi
        [[ "${found}" -gt 0 ]] || printf "  (none)\n"
    fi

    if [[ "${show_s3}" == "true" ]]; then
        printf "\n${BOLD}=== Object-storage backups (%s) ===${NC}\n" "$(describe_storage BACKUP 2>/dev/null || echo 'not configured')"
        backup_tool source s3 ro "" "" list || log_warn "Could not list object-storage backups."
    fi
    printf "\n"
}

cmd_status() {
    printf "\n${BOLD}=== Milvus ===${NC}\n"
    if curl -sf "http://${SOURCE_MILVUS_HOST:-localhost}:${SOURCE_MILVUS_MGMT_PORT:-9091}/healthz" >/dev/null 2>&1; then
        printf "  Source %s:%s  ${GREEN}[HEALTHY]${NC}\n" "${SOURCE_MILVUS_HOST:-localhost}" "${SOURCE_MILVUS_PORT:-19530}"
    else
        printf "  Source %s:%s  ${RED}[DOWN / UNREACHABLE]${NC}\n" "${SOURCE_MILVUS_HOST:-localhost}" "${SOURCE_MILVUS_PORT:-19530}"
    fi
    if curl -sf "http://${TARGET_MILVUS_HOST:-localhost}:${TARGET_MILVUS_MGMT_PORT:-9092}/healthz" >/dev/null 2>&1; then
        printf "  Target %s:%s  ${GREEN}[HEALTHY]${NC}\n" "${TARGET_MILVUS_HOST:-localhost}" "${TARGET_MILVUS_PORT:-19540}"
    else
        printf "  Target %s:%s  ${YELLOW}[STOPPED / NOT RUNNING]${NC}\n" "${TARGET_MILVUS_HOST:-localhost}" "${TARGET_MILVUS_PORT:-19540}"
    fi

    printf "\n${BOLD}=== Storage ===${NC}\n"
    printf "  Source storage: %s\n" "$(describe_storage SOURCE 2>&1)"
    printf "  Target storage: %s\n" "$(describe_storage TARGET 2>&1)"
    local storage="${BACKUP_STORAGE:-local}"
    validate_backup_storage "${storage}"
    if [[ "${storage}" == "s3" ]]; then
        printf "  Backup storage: %s\n" "$(describe_storage BACKUP 2>&1)"
        if (backup_tool source s3 ro "" "" check) >/dev/null 2>&1; then
            printf "  milvus-backup check: ${GREEN}[OK]${NC}\n"
        else
            printf "  milvus-backup check: ${RED}[FAILED]${NC}  (run: $(basename "$0") config --s3)\n"
        fi
    else
        local dir
        dir="$(make_abs_dir "${DEST_ROOT}")"
        printf "  Backup storage: local:%s (%s free)\n" "${dir}" "$(df -h "${dir}" | awk 'NR==2 {print $4}')"
        if (backup_tool source local ro "${dir}" ro check) >/dev/null 2>&1; then
            printf "  milvus-backup check: ${GREEN}[OK]${NC}\n"
        else
            printf "  milvus-backup check: ${RED}[FAILED]${NC}  (run: $(basename "$0") config)\n"
        fi
    fi

    printf "\n${BOLD}=== Docker containers ===${NC}\n"
    docker ps --filter "name=milvus" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    printf "\n"
}

cmd_config() {
    local mode="source" storage="${BACKUP_STORAGE:-local}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            source|target) mode="$1"; shift ;;
            --s3)    storage="s3"; shift ;;
            --local) storage="local"; shift ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done
    validate_backup_storage "${storage}"
    generate_config "${mode}" "${TMP_DIR}/backup.yaml" "${storage}" "${CONTAINER_BACKUP_PATH}" || exit 1
    mask_config "${TMP_DIR}/backup.yaml"
}

# ------------------------------------------------------------------------------
# deploy-target / down-target
# ------------------------------------------------------------------------------
# milvus-backup provider -> Milvus minio.cloudProvider
milvus_cloud_provider() {
    case "$1" in
        minio|s3|aws|hwc) printf 'aws' ;;
        *) printf '%s' "$1" ;;
    esac
}

# target_compose_files [lenient]  (lenient: for down-target, a missing data dir is fine)
target_compose_files() {
    TARGET_COMPOSE=(-f "${PROJECT_ROOT}/docker-compose.target.yml")
    if [[ "$(storage_provider TARGET)" == "local" ]]; then
        TARGET_COMPOSE+=(-f "${PROJECT_ROOT}/docker-compose.target.local.yml")
        export TARGET_LOCAL_DATA_DIR_ABS
        if [[ "${1:-}" == "lenient" ]]; then
            TARGET_LOCAL_DATA_DIR_ABS="$(storage_local_dir TARGET 2>/dev/null || printf '/nonexistent')"
        else
            TARGET_LOCAL_DATA_DIR_ABS="$(storage_local_dir TARGET)" || exit 1
        fi
    fi
}

cmd_deploy_target() {
    local reset=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reset) reset=true; shift ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done

    local provider
    provider="$(storage_provider TARGET)" || exit 1
    target_compose_files

    if [[ "${provider}" == "local" ]]; then
        TARGET_LOCAL_DATA_DIR_ABS="$(make_abs_dir "${TARGET_LOCAL_DATA_DIR_ABS}")"
        # Must match the localPath milvus-backup is given for the target
        export TARGET_LOCAL_MILVUS_PATH
        TARGET_LOCAL_MILVUS_PATH="$(sv TARGET LOCAL_MILVUS_PATH /var/lib/milvus/data)"
        log_info "Target Milvus storage: local disk ${TARGET_LOCAL_DATA_DIR_ABS}"
        if [[ "${reset}" == "true" ]]; then
            log_warn "--reset does not wipe ${TARGET_LOCAL_DATA_DIR_ABS}; empty it yourself for a clean target."
        fi
    else
        local auth endpoint
        auth="$(storage_auth TARGET)" || exit 1
        if [[ "${auth}" == "serviceAccount" ]]; then
            die "deploy-target cannot inject a GCP service-account key into Milvus; use provider 'gcp' (HMAC keys) or STORAGE_AUTH=default for the target."
        fi
        endpoint="$(storage_endpoint TARGET)" || exit 1
        if [[ "${endpoint}" == "localhost" || "${endpoint}" == "127.0.0.1" ]]; then
            endpoint="host.docker.internal"
        fi
        export TARGET_MINIO_ADDRESS TARGET_MINIO_CLOUD_PROVIDER TARGET_MINIO_USE_SSL TARGET_MINIO_REGION \
               TARGET_MINIO_BUCKET TARGET_MINIO_ROOT_PATH TARGET_MINIO_USE_IAM TARGET_MINIO_IAM_ENDPOINT \
               TARGET_MINIO_ACCESS_KEY TARGET_MINIO_SECRET_KEY
        TARGET_MINIO_ADDRESS="${endpoint}:$(storage_port TARGET)"
        TARGET_MINIO_CLOUD_PROVIDER="$(milvus_cloud_provider "${provider}")"
        TARGET_MINIO_USE_SSL="$(storage_use_ssl TARGET)"
        TARGET_MINIO_REGION="$(sv_conn TARGET S3_REGION us-east-1)"
        TARGET_MINIO_BUCKET="$(storage_bucket TARGET)"
        TARGET_MINIO_ROOT_PATH="$(storage_root_path TARGET)"
        TARGET_MINIO_USE_IAM="false"
        TARGET_MINIO_IAM_ENDPOINT="$(sv TARGET IAM_ENDPOINT)"
        TARGET_MINIO_ACCESS_KEY=""
        TARGET_MINIO_SECRET_KEY=""
        case "${auth}" in
            static)
                TARGET_MINIO_ACCESS_KEY="$(sv TARGET S3_ACCESS_KEY)"
                TARGET_MINIO_SECRET_KEY="$(sv TARGET S3_SECRET_KEY)" ;;
            sharedKey)
                TARGET_MINIO_ACCESS_KEY="$(sv TARGET AZURE_ACCOUNT_NAME)"
                TARGET_MINIO_SECRET_KEY="$(sv TARGET AZURE_ACCOUNT_KEY)" ;;
            iam|default)
                TARGET_MINIO_USE_IAM="true" ;;
        esac
        log_info "Target Milvus storage: $(describe_storage TARGET) at ${TARGET_MINIO_ADDRESS}"
    fi

    if [[ "${reset}" == "true" ]]; then
        log_warn "Removing previous target Milvus containers and volumes..."
        docker compose "${TARGET_COMPOSE[@]}" down -v >/dev/null 2>&1 || true
    fi
    docker compose "${TARGET_COMPOSE[@]}" up -d

    local port="${TARGET_MILVUS_MGMT_PORT:-9092}" count=0
    log_info "Waiting for target Milvus (gRPC ${TARGET_MILVUS_PORT:-19540}) to become healthy..."
    while [[ ${count} -lt 90 ]]; do
        if curl -sf "http://localhost:${port}/healthz" >/dev/null 2>&1; then
            log_success "Target Milvus is healthy on port ${TARGET_MILVUS_PORT:-19540}."
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done
    die "Timed out waiting for target Milvus; see: docker logs milvus-target"
}

cmd_down_target() {
    target_compose_files lenient
    log_info "Stopping target Milvus stack..."
    docker compose "${TARGET_COMPOSE[@]}" down "$@"
    log_success "Target Milvus stack stopped."
}

# ------------------------------------------------------------------------------
# verify / seed (pymilvus client container)
# ------------------------------------------------------------------------------
ensure_client_image() {
    if ! docker image inspect "${CLIENT_IMAGE}" >/dev/null 2>&1; then
        log_info "Building ${CLIENT_IMAGE} (one-time)..."
        docker build -q -t "${CLIENT_IMAGE}" -f "${PROJECT_ROOT}/Dockerfile.milvus-client" "${PROJECT_ROOT}" >/dev/null
    fi
}

# Credentials go through the environment, not argv
run_client() {
    ensure_client_image
    docker run --rm --network host -e MILVUS_USER -e MILVUS_PASSWORD "${CLIENT_IMAGE}" "$@"
}

cmd_verify() {
    local host="${TARGET_MILVUS_HOST:-localhost}" port="${TARGET_MILVUS_PORT:-19540}"
    local src_host="${SOURCE_MILVUS_HOST:-localhost}" src_port="${SOURCE_MILVUS_PORT:-19530}"
    local coll="benchmark_vectors" count=1000 compare=false suffix="" collections=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)        host="$(optval "$@")"; shift 2 ;;
            --port)        port="$(optval "$@")"; shift 2 ;;
            --source-host) src_host="$(optval "$@")"; shift 2 ;;
            --source-port) src_port="$(optval "$@")"; shift 2 ;;
            --collection)  coll="$(optval "$@")"; shift 2 ;;
            --count)       count="$(optval "$@")"; shift 2 ;;
            --compare)     compare=true; shift ;;
            --suffix)      suffix="$(optval "$@")"; shift 2 ;;
            --collections) collections="$(optval "$@")"; shift 2 ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done

    if [[ "${compare}" == "true" ]]; then
        log_info "Comparing entity counts: source ${src_host}:${src_port} vs target ${host}:${port}"
        local args=(--compare --source-host "${src_host}" --source-port "${src_port}" --host "${host}" --port "${port}")
        [[ -z "${suffix}" ]] || args+=(--suffix "${suffix}")
        [[ -z "${collections}" ]] || args+=(--collections "${collections}")
        run_client /app/scripts/verify_restore.py "${args[@]}"
    else
        log_info "Verifying benchmark collection '${coll}' on ${host}:${port}"
        run_client /app/scripts/verify_restore.py --host "${host}" --port "${port}" \
            --collection "${coll}" --expected-count "${count}"
    fi
}

cmd_seed() {
    local host="${SOURCE_MILVUS_HOST:-localhost}" port="${SOURCE_MILVUS_PORT:-19530}" coll="benchmark_vectors" count=1000
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)       host="$(optval "$@")"; shift 2 ;;
            --port)       port="$(optval "$@")"; shift 2 ;;
            --collection) coll="$(optval "$@")"; shift 2 ;;
            --count)      count="$(optval "$@")"; shift 2 ;;
            *) log_error "Unknown option: $1"; usage 1 ;;
        esac
    done
    run_client /app/scripts/seed_benchmark.py --host "${host}" --port "${port}" --collection "${coll}" --count "${count}"
}

# ------------------------------------------------------------------------------
# Dispatcher
# ------------------------------------------------------------------------------
COMMAND="${1:-help}"
shift || true

case "${COMMAND}" in
    backup)         cmd_backup "$@" ;;
    restore)        cmd_restore "$@" ;;
    list)           cmd_list "$@" ;;
    prune)          cmd_prune ;;
    status)         cmd_status ;;
    config)         cmd_config "$@" ;;
    deploy-target)  cmd_deploy_target "$@" ;;
    down-target)    cmd_down_target "$@" ;;
    verify)         cmd_verify "$@" ;;
    seed)           cmd_seed "$@" ;;
    version|--version) printf 'milbakman %s\n' "${MILBAKMAN_VERSION}" ;;
    help|-h|--help) usage 0 ;;
    *)              log_error "Unknown command: ${COMMAND}"; usage 1 ;;
esac
