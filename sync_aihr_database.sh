#!/bin/bash

# =================================================================
# Script Name: sync_aihr_database.sh
# Description: Dump MongoDB AiHR through SSH tunnel and restore to local/dev.
#
# How to run:
#   1. Restore to local MongoDB (fastest — pipeline mode, zero disk I/O):
#      ./sync_aihr_database.sh --db YKK
#
#   2. Restore to dev/office MongoDB (dir dump with --gzip):
#      ./sync_aihr_database.sh --db YKK --target dev
#
#   3. Force close the old tunnel and reconnect:
#      ./sync_aihr_database.sh --db YKK --target dev --reconnect
#
#   4. Use a different KeePassXC entry for dev:
#      DEV_DB_ENTRY_TITLE="Ten Entry" ./sync_aihr_database.sh --db YKK --target dev
#
#   5. Save a .tar.gz archive even when restoring to local:
#      ./sync_aihr_database.sh --db YKK --save-archive
#
#   6. Disable pipeline mode (use directory dump for local too):
#      ./sync_aihr_database.sh --db YKK --no-pipeline
#
# Performance notes (Apple M4 optimised):
#   - local target uses mongodump --archive | mongorestore --archive (pipe mode).
#     Data flows through RAM — no intermediate disk writes at all.
#   - dev/dir target uses mongodump --gzip, so compress happens inline during dump.
#     No separate tar|pigz pass needed; mongorestore --gzip reads .bson.gz directly.
#   - numParallelCollections: 10 for dir mode, 4 for pipeline mode (pipe is serial by nature).
#   - SSH tunnel uses ServerAliveInterval/TCPKeepAlive to avoid drops on large DBs.
#   - SSH -C (compression) is deliberately NOT used — BSON is already compact; SSH
#     compression would slow the tunnel down.
# =================================================================

set -u
set -o pipefail

readonly KP_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
readonly KP_DB_PATH="/Users/dangkhoa/KeePassXCDatebase.kdbx"
readonly SSH_ENTRY_TITLE="ServerAiHR"
readonly SOURCE_DB_ENTRY_TITLE="DB AiHR"

readonly DEFAULT_LOCAL_PORT=27019
readonly REMOTE_MONGO_HOST="localhost"
readonly REMOTE_MONGO_PORT=27017
readonly TMP_DIR="/Users/dangkhoa/Developer/Work/Jobtest/mongorestore/dump"

readonly LOCAL_MONGO_HOST="${LOCAL_MONGO_HOST:-127.0.0.1}"
readonly LOCAL_MONGO_PORT="${LOCAL_MONGO_PORT:-27017}"
readonly DEV_DB_ENTRY_TITLE="${DEV_DB_ENTRY_TITLE:-DB Office}"

DB_NAME=""
TARGET="local"
LOCAL_PORT="$DEFAULT_LOCAL_PORT"
RECONNECT=0
DROP_TARGET=1
TARGET_URI=""
FULL_PATH=""
DUMP_ARCHIVE=""
TUNNEL_PIDS=""
START_TIME=0
MASTER_PW=""
SSH_PASS=""
SOURCE_DB_PASS=""
TARGET_DB_PASS=""
SAVE_ARCHIVE=0
USE_PIPELINE=1   # enabled by default for local target

usage() {
    cat <<'EOF'
Usage:
  ./sync_aihr_database.sh --db <database> [--target local|dev] [options]

Examples:
  ./sync_aihr_database.sh --db YKK --target local
  ./sync_aihr_database.sh --db HRM_DEV --target dev --reconnect
  ./sync_aihr_database.sh --db YKK --target-uri "mongodb://user:pass@127.0.0.1:27018/YKK?authSource=admin"
  ./sync_aihr_database.sh --db YKK --save-archive
  ./sync_aihr_database.sh --db YKK --no-pipeline

Options:
  --db <name>          Database to dump/restore. Required.
  --target <name>      Restore target: local or dev. Default: local.
  --target-uri <uri>   MongoDB restore URI. Overrides --target config.
  --port <port>        Local SSH tunnel port. Default: 27019.
  --no-drop            Restore without dropping old collections first.
  --reconnect          Kill existing tunnel on --port, then reconnect.
  --save-archive       Save a .tar.gz archive even when using pipeline mode.
  --no-pipeline        Disable pipeline mode; use directory dump for local too.
  -h, --help           Show help.

Notes:
  local target (default): uses mongodump --archive | mongorestore --archive.
    Zero disk I/O — fastest possible. Add --save-archive to also keep a .tar.gz.
  dev target: dumps with --gzip to dir, then mongorestore --gzip. No separate pigz pass.
  Set DEV_DB_ENTRY_TITLE env var to override dev KeePass entry name.
EOF
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"
}

get_secret() {
    local entry_title=$1
    local attr=$2

    echo "$MASTER_PW" | "$KP_CLI" show "$KP_DB_PATH" "$entry_title" -a "$attr" 2>/dev/null
}

mongo_uri_with_db() {
    local base_uri=$1
    local db_name=$2

    if [[ "$base_uri" == */ ]]; then
        echo "${base_uri}${db_name}"
    else
        echo "${base_uri}/${db_name}"
    fi
}

tunnel_pids_on_port() {
    lsof -nP -tiTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || true
}

is_aihr_tunnel_pid() {
    local pid=$1
    local cmd

    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [[ "$cmd" == *"ssh "* && "$cmd" == *"-L ${LOCAL_PORT}:${REMOTE_MONGO_HOST}:${REMOTE_MONGO_PORT}"* ]]
}

kill_tunnel_pids() {
    local pids=$1
    local pid

    [ -z "$pids" ] && return 0

    for pid in $pids; do
        if is_aihr_tunnel_pid "$pid"; then
            log "Closing SSH tunnel PID $pid"
            kill "$pid" 2>/dev/null || true
        else
            fail "Port $LOCAL_PORT is used by another process PID $pid. Stop that process or choose another --port."
        fi
    done
}

cleanup() {
    local exit_code=$?
    local end_time elapsed

    unset MASTER_PW
    unset SSH_PASS
    unset SOURCE_DB_PASS
    unset TARGET_DB_PASS

    if [ -n "${FULL_PATH:-}" ] && [ -d "$FULL_PATH" ]; then
        rm -rf "$FULL_PATH"
        log "Removed temporary dump directory: $FULL_PATH"
    fi

    if [ -n "${TUNNEL_PIDS:-}" ]; then
        kill_tunnel_pids "$TUNNEL_PIDS" || true
    fi

    if [ "${START_TIME:-0}" -gt 0 ]; then
        end_time=$(date +%s)
        elapsed=$((end_time - START_TIME))
        log "Total runtime: ${elapsed}s"
    fi

    exit "$exit_code"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --db)
                DB_NAME="${2:-}"
                shift 2
                ;;
            --target)
                TARGET="${2:-}"
                shift 2
                ;;
            --target-uri)
                TARGET_URI="${2:-}"
                shift 2
                ;;
            --port)
                LOCAL_PORT="${2:-}"
                shift 2
                ;;
            --no-drop)
                DROP_TARGET=0
                shift
                ;;
            --reconnect)
                RECONNECT=1
                shift
                ;;
            --save-archive)
                SAVE_ARCHIVE=1
                shift
                ;;
            --no-pipeline)
                USE_PIPELINE=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Invalid option: $1"
                ;;
        esac
    done
}

validate_input() {
    [ -n "$DB_NAME" ] || { usage; fail "Missing --db <database>"; }
    [[ "$TARGET" == "local" || "$TARGET" == "dev" ]] || fail "--target must be local or dev"
    [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || fail "--port must be a number"
    [ -f "$KP_DB_PATH" ] || fail "KeePassXC database file not found: $KP_DB_PATH"

    require_command "$KP_CLI"
    require_command sshpass
    require_command ssh
    require_command lsof
    require_command ps
    require_command mongodump
    require_command mongorestore
    require_command tar

    # pigz only needed when saving an archive from pipeline mode
    if _needs_archive; then
        require_command pigz
    fi
}

# Returns true if we need to produce a .tar.gz archive
_needs_archive() {
    # Always archive when using dir mode (dev target or --no-pipeline)
    # Archive on local pipeline mode only when --save-archive is set
    if _use_pipeline_mode; then
        [ "$SAVE_ARCHIVE" -eq 1 ]
    else
        return 0   # dir mode always archives
    fi
}

# Returns true when pipeline (archive-stream) mode should be used
_use_pipeline_mode() {
    local effective_target="local"
    [ -n "$TARGET_URI" ] && effective_target="uri"
    [ "$TARGET" = "dev" ] && effective_target="dev"

    # Pipeline only works when target is local and --no-pipeline not set
    [[ "$effective_target" == "local" && "$USE_PIPELINE" -eq 1 ]]
}

open_tunnel() {
    local existing_pids

    existing_pids=$(tunnel_pids_on_port)
    if [ -n "$existing_pids" ] && [ "$RECONNECT" -eq 1 ]; then
        kill_tunnel_pids "$existing_pids"
        sleep 1
        existing_pids=""
    fi

    if [ -n "$existing_pids" ]; then
        for pid in $existing_pids; do
            is_aihr_tunnel_pid "$pid" || fail "Port $LOCAL_PORT is used by another process PID $pid."
        done

        log "SSH tunnel already exists on localhost:$LOCAL_PORT; reusing it."
        TUNNEL_PIDS="$existing_pids"
        return 0
    fi

    local ssh_host ssh_user ssh_port
    ssh_host=$(get_secret "$SSH_ENTRY_TITLE" "URL")
    ssh_user=$(get_secret "$SSH_ENTRY_TITLE" "UserName")
    SSH_PASS=$(get_secret "$SSH_ENTRY_TITLE" "Password")
    ssh_port=$(get_secret "$SSH_ENTRY_TITLE" "Port")
    ssh_port=${ssh_port:-22}

    [ -n "$ssh_host" ] || fail "Could not read URL from KeePass entry '$SSH_ENTRY_TITLE'"
    [ -n "$ssh_user" ] || fail "Could not read UserName from KeePass entry '$SSH_ENTRY_TITLE'"
    [ -n "$SSH_PASS" ] || fail "Could not read Password from KeePass entry '$SSH_ENTRY_TITLE'"

    log "Opening SSH tunnel localhost:$LOCAL_PORT -> $REMOTE_MONGO_HOST:$REMOTE_MONGO_PORT"
    sshpass -p "$SSH_PASS" ssh \
        -L "${LOCAL_PORT}:${REMOTE_MONGO_HOST}:${REMOTE_MONGO_PORT}" \
        "${ssh_user}@${ssh_host}" \
        -p "$ssh_port" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -fN

    [ $? -eq 0 ] || fail "Could not open SSH tunnel. Check VPN/server/credentials."

    sleep 1
    TUNNEL_PIDS=$(tunnel_pids_on_port)
    [ -n "$TUNNEL_PIDS" ] || fail "SSH tunnel started, but port $LOCAL_PORT is not listening."
}

# ─── Pipeline mode: mongodump --archive | mongorestore --archive ───────────────
# Zero disk I/O. Data flows through RAM from tunnel → mongodump → pipe → mongorestore.
# Fastest possible for local target.
dump_and_restore_pipeline() {
    local source_user drop_args=()

    source_user=$(get_secret "$SOURCE_DB_ENTRY_TITLE" "UserName")
    SOURCE_DB_PASS=$(get_secret "$SOURCE_DB_ENTRY_TITLE" "Password")

    [ -n "$source_user" ] || fail "Could not read UserName from KeePass entry '$SOURCE_DB_ENTRY_TITLE'"
    [ -n "$SOURCE_DB_PASS" ] || fail "Could not read Password from KeePass entry '$SOURCE_DB_ENTRY_TITLE'"

    [ "$DROP_TARGET" -eq 1 ] && drop_args=(--drop)

    log "Pipeline mode: mongodump --archive | mongorestore --archive (zero disk I/O)"
    log "Dumping '$DB_NAME' from AiHR and restoring to ${LOCAL_MONGO_HOST}:${LOCAL_MONGO_PORT} in one pass..."

    mongodump \
        --host 127.0.0.1 \
        --port "$LOCAL_PORT" \
        --db "$DB_NAME" \
        --username "$source_user" \
        --password "$SOURCE_DB_PASS" \
        --authenticationDatabase admin \
        --numParallelCollections 4 \
        --archive \
    | mongorestore \
        --host "$LOCAL_MONGO_HOST" \
        --port "$LOCAL_MONGO_PORT" \
        --nsInclude "${DB_NAME}.*" \
        "${drop_args[@]}" \
        --numParallelCollections 4 \
        --bypassDocumentValidation \
        --writeConcern='{w: 0}' \
        --archive

    [ ${PIPESTATUS[0]} -eq 0 ] || fail "mongodump (pipeline) failed."
    [ ${PIPESTATUS[1]} -eq 0 ] || fail "mongorestore (pipeline) failed."

    log "Pipeline restore OK."

    # Optionally also save an archive to disk (--save-archive flag)
    if [ "$SAVE_ARCHIVE" -eq 1 ]; then
        mkdir -p "$TMP_DIR"
        DUMP_ARCHIVE="${TMP_DIR}/dump_${DB_NAME}_$(date +%Y%m%d_%H%M%S).archive.gz"
        log "Saving archive to $DUMP_ARCHIVE (background)..."
        mongodump \
            --host 127.0.0.1 \
            --port "$LOCAL_PORT" \
            --db "$DB_NAME" \
            --username "$source_user" \
            --password "$SOURCE_DB_PASS" \
            --authenticationDatabase admin \
            --numParallelCollections 4 \
            --archive \
            --gzip \
            >"$DUMP_ARCHIVE"
        [ $? -eq 0 ] || fail "Archive dump failed."
        log "Archive OK: $(du -sh "$DUMP_ARCHIVE" | cut -f1)"
    fi
}

# ─── Dir mode: mongodump --gzip → dir, then mongorestore --gzip ───────────────
# Used for dev/target-uri targets, or when --no-pipeline is passed.
# --gzip compresses inline during dump — no separate pigz pass needed.
dump_source_db() {
    local source_user

    source_user=$(get_secret "$SOURCE_DB_ENTRY_TITLE" "UserName")
    SOURCE_DB_PASS=$(get_secret "$SOURCE_DB_ENTRY_TITLE" "Password")

    [ -n "$source_user" ] || fail "Could not read UserName from KeePass entry '$SOURCE_DB_ENTRY_TITLE'"
    [ -n "$SOURCE_DB_PASS" ] || fail "Could not read Password from KeePass entry '$SOURCE_DB_ENTRY_TITLE'"

    mkdir -p "$TMP_DIR"
    FULL_PATH="$TMP_DIR/dump_${DB_NAME}_$(date +%Y%m%d_%H%M%S)"

    log "Dir mode: mongodump --gzip (inline compression, 10 parallel collections)..."
    mongodump \
        --host 127.0.0.1 \
        --port "$LOCAL_PORT" \
        --db "$DB_NAME" \
        --username "$source_user" \
        --password "$SOURCE_DB_PASS" \
        --authenticationDatabase admin \
        --numParallelCollections 10 \
        --gzip \
        --out "$FULL_PATH"

    [ $? -eq 0 ] || fail "Dump database '$DB_NAME' failed."
    log "Dump OK: $(du -sh "$FULL_PATH" | cut -f1)"

    # Create a single .tar.gz for archival (pigz -p 8 to leave cores for restore)
    DUMP_ARCHIVE="${FULL_PATH}.tar.gz"
    log "Archiving (tar | pigz -p 8) -> $DUMP_ARCHIVE"
    tar -cf - -C "$TMP_DIR" "$(basename "$FULL_PATH")" | pigz -p 8 >"$DUMP_ARCHIVE"
    [ $? -eq 0 ] || fail "Archive (tar | pigz) failed."
    log "Archive OK: $(du -sh "$DUMP_ARCHIVE" | cut -f1)"
}

restore_to_local() {
    local drop_args=()

    [ "$DROP_TARGET" -eq 1 ] && drop_args=(--drop)

    log "Restoring '$DB_NAME' to local ${LOCAL_MONGO_HOST}:${LOCAL_MONGO_PORT} (--gzip, 10 parallel)..."
    mongorestore \
        --host "$LOCAL_MONGO_HOST" \
        --port "$LOCAL_MONGO_PORT" \
        --nsInclude "${DB_NAME}.*" \
        "${drop_args[@]}" \
        --numParallelCollections 10 \
        --bypassDocumentValidation \
        --gzip \
        "${FULL_PATH}/${DB_NAME}"
}

restore_to_dev() {
    local drop_args=()
    local dev_uri

    [ "$DROP_TARGET" -eq 1 ] && drop_args=(--drop)

    dev_uri=$(get_secret "$DEV_DB_ENTRY_TITLE" "Password")
    [ -n "$dev_uri" ] || fail "Could not read MongoDB URI from Password field of KeePass entry '$DEV_DB_ENTRY_TITLE'"

    log "Restoring '$DB_NAME' to dev from KeePass entry '$DEV_DB_ENTRY_TITLE' (--gzip, 8 parallel)..."
    mongorestore \
        --uri "$(mongo_uri_with_db "$dev_uri" "$DB_NAME")" \
        --nsInclude "${DB_NAME}.*" \
        "${drop_args[@]}" \
        --numParallelCollections 8 \
        --bypassDocumentValidation \
        --writeConcern='{w: 0}' \
        --gzip \
        "${FULL_PATH}/${DB_NAME}"
}

restore_to_uri() {
    local drop_args=()

    [ "$DROP_TARGET" -eq 1 ] && drop_args=(--drop)

    log "Restoring '$DB_NAME' to target URI (--gzip, 8 parallel)..."
    mongorestore \
        --uri "$TARGET_URI" \
        --nsInclude "${DB_NAME}.*" \
        "${drop_args[@]}" \
        --numParallelCollections 8 \
        --bypassDocumentValidation \
        --writeConcern='{w: 0}' \
        --gzip \
        "${FULL_PATH}/${DB_NAME}"
}

restore_target_db() {
    if [ -n "$TARGET_URI" ]; then
        restore_to_uri
    elif [ "$TARGET" = "local" ]; then
        restore_to_local
    else
        restore_to_dev
    fi

    log "Restore OK."
}

main() {
    START_TIME=$(date +%s)

    parse_args "$@"
    validate_input

    trap cleanup EXIT INT TERM

    echo -n "KeePassXC Password: "
    read -rs MASTER_PW
    echo ""

    open_tunnel

    if _use_pipeline_mode; then
        # ── Fastest path: zero disk I/O ──
        dump_and_restore_pipeline
    else
        # ── Dir mode: dump --gzip → dir, then restore ──
        dump_source_db
        restore_target_db
    fi

    log "Done."
}

main "$@"
