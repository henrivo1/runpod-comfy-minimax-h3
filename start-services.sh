#!/usr/bin/env bash
# MiniMax H3-only startup, persistent restart fast path, and ComfyUI supervisor.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/runpod-slim/ComfyUI}"
COMFY_VENV="${COMFY_VENV:-$COMFY_ROOT/.venv-cu128}"
ARGS_FILE="${ARGS_FILE:-/workspace/runpod-slim/comfyui_args.txt}"
STATE_DIR="${STATE_DIR:-$WORKSPACE/.runpod-minimax-h3}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/complete.state}"
WORKFLOW_NAME="MINIMAX_H3_ULTRA_TURBO_WORKFLOW-V2-5090.json"

FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-0}"
ENABLE_SERVICE_SUPERVISOR="${ENABLE_SERVICE_SUPERVISOR:-1}"
SUPERVISOR_INTERVAL="${SUPERVISOR_INTERVAL:-30}"
SUPERVISOR_FAILURE_THRESHOLD="${SUPERVISOR_FAILURE_THRESHOLD:-3}"

log()  { printf '\n============================================================\n%s\n============================================================\n' "$*"; }
info() { printf '  -> %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

port_busy() {
    local port="$1"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
        return 0
    fi
    curl -fsS --max-time 2 "http://127.0.0.1:${port}" >/dev/null 2>&1
}

wait_for_port() {
    local port="$1" name="$2" tries="${3:-60}" delay="${4:-2}" i
    for i in $(seq 1 "$tries"); do
        port_busy "$port" && { info "$name is ready on port $port."; return 0; }
        sleep "$delay"
    done
    warn "$name did not answer on port $port."
    return 1
}

detect_comfy_venv() {
    local candidate
    [[ -x "$COMFY_VENV/bin/python" ]] && return 0
    for candidate in "$COMFY_ROOT"/.venv* "$COMFY_ROOT"/venv; do
        if [[ -x "$candidate/bin/python" ]]; then
            COMFY_VENV="$candidate"
            return 0
        fi
    done
    return 1
}

wait_for_base() {
    log "Waiting for RunPod base services"
    local i
    for i in $(seq 1 150); do
        [[ -d "$COMFY_ROOT/models" && -d "$COMFY_ROOT/custom_nodes" ]] &&
            detect_comfy_venv && break
        sleep 2
    done
    [[ -x "$COMFY_VENV/bin/python" ]] || { warn "RunPod ComfyUI environment was not created."; return 1; }
    wait_for_port 8080 "FileBrowser" 60 2 || true
    wait_for_port 8888 "JupyterLab" 60 2 || true
    wait_for_port 8188 "Initial ComfyUI" 180 2 || true
}

setup_fingerprint() {
    {
        sha256sum "$SCRIPT_DIR/bootstrap.sh"
        sha256sum "$SCRIPT_DIR/models.manifest"
        sha256sum "$SCRIPT_DIR/custom-nodes.manifest"
        sha256sum "$SCRIPT_DIR/workflows/$WORKFLOW_NAME"
    } | sha256sum | awk '{print $1}'
}

mandatory_models_present() {
    local raw set_name subdir filename url optional remainder
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        [[ -z "${raw//[[:space:]]/}" || "$raw" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r set_name subdir filename url optional remainder <<< "$raw"
        subdir="$(trim "$subdir")"
        filename="$(trim "$filename")"
        optional="$(trim "${optional:-}")"
        [[ "$optional" == "optional" ]] && continue
        [[ -f "$COMFY_ROOT/models/$subdir/$filename" ]] || {
            warn "Mandatory model missing: models/$subdir/$filename"
            return 1
        }
    done < "$SCRIPT_DIR/models.manifest"
}

required_nodes_present() {
    local raw dir url remainder
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        [[ -z "${raw//[[:space:]]/}" || "$raw" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r dir url remainder <<< "$raw"
        dir="$(trim "$dir")"
        [[ -d "$COMFY_ROOT/custom_nodes/$dir" ]] || {
            warn "Required node missing: $dir"
            return 1
        }
    done < "$SCRIPT_DIR/custom-nodes.manifest"
}

install_complete() {
    detect_comfy_venv || return 1
    mandatory_models_present || return 1
    required_nodes_present || return 1
    [[ -f "$COMFY_ROOT/user/default/workflows/$WORKFLOW_NAME" ]]
}

fast_restart_eligible() {
    [[ "$FORCE_BOOTSTRAP" != "1" ]] || return 1
    install_complete || return 1
    local current
    current="$(setup_fingerprint)"

    if [[ ! -f "$STATE_FILE" ]]; then
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$current" > "$STATE_FILE"
        info "Adopted complete persistent MiniMax H3 installation."
        return 0
    fi

    [[ "$(cat "$STATE_FILE" 2>/dev/null || true)" == "$current" ]]
}

run_bootstrap() {
    log "Running full MiniMax H3 payload bootstrap"
    COMFY_ROOT="$COMFY_ROOT" COMFY_VENV="$COMFY_VENV" bash "$SCRIPT_DIR/bootstrap.sh"
}

write_state() {
    mkdir -p "$STATE_DIR"
    setup_fingerprint > "$STATE_FILE"
}

stop_initial_comfy() {
    local pids
    pids="$(pgrep -f 'python(3(\.[0-9]+)?)?[[:space:]]+main\.py.*--port[[:space:]=]+8188' || true)"
    if [[ -n "$pids" ]]; then
        info "Stopping the initial ComfyUI process so installed nodes can load."
        kill -TERM $pids 2>/dev/null || true
    fi
    for _ in $(seq 1 30); do
        port_busy 8188 || return 0
        sleep 1
    done
    warn "Port 8188 remained busy after stop request."
}

start_comfy() {
    local fixed_args="--listen 0.0.0.0 --port 8188 --enable-cors-header"
    if [[ -s "$ARGS_FILE" ]]; then
        local custom_args
        custom_args="$(grep -v '^[[:space:]]*#' "$ARGS_FILE" | tr '\n' ' ' || true)"
        [[ -z "${custom_args// }" ]] || fixed_args="$fixed_args $custom_args"
    fi

    log "Starting ComfyUI with MiniMax H3"
    (
        cd "$COMFY_ROOT"
        export PATH="$COMFY_VENV/bin:$PATH"
        # shellcheck disable=SC2086
        nohup "$COMFY_VENV/bin/python" main.py $fixed_args \
            > "$WORKSPACE/comfyui-custom.log" 2>&1 < /dev/null &
        echo $! > "$WORKSPACE/comfyui-custom.pid"
    )
    wait_for_port 8188 "ComfyUI" 180 2 || true
}

restart_comfy() {
    warn "ComfyUI is not listening; restarting automatically."
    stop_initial_comfy
    start_comfy || true
}

status() {
    log "Service status"
    printf '  8188  ComfyUI      %s\n' "$(port_busy 8188 && echo UP || echo down)"
    printf '  8080  FileBrowser  %s\n' "$(port_busy 8080 && echo UP || echo down)"
    printf '  8888  JupyterLab   %s\n' "$(port_busy 8888 && echo UP || echo down)"
    echo
    echo "Logs:"
    echo "  /workspace/start-services-boot.log"
    echo "  /workspace/comfyui-custom.log"
}

supervise() {
    [[ "$ENABLE_SERVICE_SUPERVISOR" == "1" ]] || return 0
    log "ComfyUI supervisor enabled"
    local misses=0
    trap 'info "Supervisor stopping."; exit 0' TERM INT

    while true; do
        sleep "$SUPERVISOR_INTERVAL"
        if port_busy 8188; then
            misses=0
        else
            misses=$((misses + 1))
            if (( misses >= SUPERVISOR_FAILURE_THRESHOLD )); then
                misses=0
                restart_comfy
            fi
        fi
    done
}

main() {
    mkdir -p "$STATE_DIR"
    exec 9> "$STATE_DIR/start.lock"
    if ! flock -n 9; then
        info "Another MiniMax H3 startup/supervisor is already running."
        exit 0
    fi

    wait_for_base

    if fast_restart_eligible; then
        log "Fast restart path"
        info "Reusing the complete persistent MiniMax H3 installation."
        wait_for_port 8188 "ComfyUI" 180 2 || restart_comfy
    else
        run_bootstrap
        stop_initial_comfy
        start_comfy
        write_state
    fi

    status
    supervise
}

main "$@"

