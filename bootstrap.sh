#!/usr/bin/env bash
# =============================================================================
# MiniMax H3-only RunPod payload bootstrap (CUDA 13 / RTX 5090)
#
# This script DOES NOT install or replace ComfyUI or its PyTorch/CUDA stack.
# The official RunPod image owns those. This adds:
#   - MiniMax H3 workflow model files
#   - required custom nodes + their Python dependencies
#   - workflow JSON files
# This repository is locked to MiniMax H3. It cannot enable Krea2 or AI Toolkit.
#
# Safe to re-run. Existing valid model files are skipped.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/runpod-slim/ComfyUI}"
COMFY_VENV="${COMFY_VENV:-$COMFY_ROOT/.venv-cu128}"
PIP_CONSTRAINT_FILE="${PIP_CONSTRAINT_FILE:-/opt/comfyui-runtime-constraints.txt}"

MODEL_SETS="minimax"
UPDATE_CUSTOM_NODES="${UPDATE_CUSTOM_NODES:-1}"
MIN_FREE_GB="${MIN_FREE_GB:-25}"
MODEL_DOWNLOAD_WORKERS="${MODEL_DOWNLOAD_WORKERS:-3}"
GIT_CLONE_ATTEMPTS="${GIT_CLONE_ATTEMPTS:-6}"

MANIFEST="${MANIFEST:-$SCRIPT_DIR/models.manifest}"
NODE_MANIFEST="${NODE_MANIFEST:-$SCRIPT_DIR/custom-nodes.manifest}"
WORKFLOW_SRC="${WORKFLOW_SRC:-$SCRIPT_DIR/workflows}"
TOOLS_ROOT="${TOOLS_ROOT:-$WORKSPACE/.runpod-tools}"
HF_VENV="$TOOLS_ROOT/hf-downloader"
HF_STAGE="${HF_STAGE:-$WORKSPACE/.hf-model-stage}"
NODE_STATE="${NODE_STATE:-$WORKSPACE/.runpod-node-deps}"

export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
export HF_XET_CACHE="${HF_XET_CACHE:-$WORKSPACE/.cache/huggingface/xet}"
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-600}"
export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
# RunPod 5090 hosts normally have ample system RAM. Set this to 0 as an
# environment variable if you deliberately want Hugging Face's normal mode.
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

mkdir -p "$WORKSPACE" "$TOOLS_ROOT" "$HF_HOME" "$HF_XET_CACHE" "$HF_STAGE" "$NODE_STATE"

log()  { printf '\n============================================================\n%s\n============================================================\n' "$*"; }
info() { printf '  -> %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }
die()  { printf '  [ERROR] %s\n' "$*" >&2; exit 1; }

format_seconds() {
    local total="${1:-0}"
    printf '%02dh:%02dm:%02ds' "$((total/3600))" "$(((total%3600)/60))" "$((total%60))"
}

stage_begin() {
    STAGE_NAME="$1"
    STAGE_STARTED="$(date +%s)"
    log "$STAGE_NAME"
}

stage_end() {
    local ended elapsed
    ended="$(date +%s)"
    elapsed="$((ended - STAGE_STARTED))"
    info "$STAGE_NAME completed in $(format_seconds "$elapsed")"
}

set_enabled() {
    local wanted="$1"
    [[ "$wanted" == "always" ]] && return 0
    [[ ",$MODEL_SETS," == *",$wanted,"* ]]
}

wait_for_comfy_base() {
    stage_begin "Waiting for the official RunPod ComfyUI base"
    local i
    for i in $(seq 1 120); do
        if [[ -d "$COMFY_ROOT/models" && -d "$COMFY_ROOT/custom_nodes" ]]; then
            if [[ -x "$COMFY_VENV/bin/python" ]]; then
                info "ComfyUI root: $COMFY_ROOT"
                info "ComfyUI Python: $COMFY_VENV/bin/python"
                stage_end
                return 0
            fi

            # Future-proofing in case RunPod renames its venv later.
            local candidate
            for candidate in "$COMFY_ROOT"/.venv* "$COMFY_ROOT"/venv; do
                if [[ -x "$candidate/bin/python" ]]; then
                    COMFY_VENV="$candidate"
                    info "Detected ComfyUI venv: $COMFY_VENV"
                    export COMFY_VENV
                    stage_end
                    return 0
                fi
            done
        fi
        sleep 2
    done
    die "Timed out waiting for $COMFY_ROOT and its RunPod-managed Python environment."
}

ensure_system_packages() {
    local packages=(git curl ca-certificates python3 python3-venv iproute2 lsof procps psmisc)
    local missing=()
    local p

    for p in "${packages[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if ((${#missing[@]} == 0)); then
        info "System prerequisites already present."
        return 0
    fi

    info "Installing missing system packages: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

configure_git_transport() {
    stage_begin "Configuring resilient GitHub transport"

    # GitHub's public smart-HTTP endpoint can intermittently return malformed
    # HTTP/2 responses that look like authentication failures. Force HTTP/1.1
    # for every custom-node clone/update performed by this pod.
    git config --global http.version HTTP/1.1
    info "Git HTTP transport forced to HTTP/1.1."
    stage_end
}

preflight_gpu_host() {
    stage_begin "Checking RunPod GPU host compatibility"

    command -v nvidia-smi >/dev/null 2>&1 || \
        die "nvidia-smi is unavailable. This pod does not appear to have a usable NVIDIA runtime."

    local gpu_name driver_version driver_major
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 | xargs || true)"
    driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | xargs || true)"
    driver_major="${driver_version%%.*}"

    info "GPU: ${gpu_name:-unknown}"
    info "NVIDIA driver: ${driver_version:-unknown}"

    if [[ -z "$driver_version" || ! "$driver_major" =~ ^[0-9]+$ ]]; then
        die "Could not determine the NVIDIA driver version."
    fi

    if echo "$gpu_name" | grep -Eiq 'RTX[[:space:]-]*(50|PRO.*6000)|Blackwell|B200|GB200|GB300'; then
        if (( driver_major < 580 )); then
            cat > "$WORKSPACE/RUNPOD-HOST-INCOMPATIBLE.txt" <<EOF
This RunPod host is incompatible with the CUDA 13 / Blackwell setup.

GPU: $gpu_name
NVIDIA driver: $driver_version
Required: NVIDIA driver 580 or newer

The bootstrap stopped before large model downloads.
Terminate this pod and redeploy with RunPod's CUDA 13 filter enabled.
EOF
            die "Blackwell GPU detected on NVIDIA driver $driver_version. Driver 580+ is required."
        fi
    fi

    stage_end
}

ensure_hf_downloader() {
    stage_begin "Preparing fast Hugging Face downloader"
    if [[ ! -x "$HF_VENV/bin/python" ]]; then
        python3 -m venv "$HF_VENV"
    fi
    "$HF_VENV/bin/python" -m pip install -q --disable-pip-version-check \
        --upgrade "huggingface_hub>=0.34,<2" "hf_xet>=1.1,<2"
    info "Hugging Face downloader ready (hf_xet enabled)."
    stage_end
}

download_models() {
    [[ -f "$MANIFEST" ]] || die "Model manifest not found: $MANIFEST"

    stage_begin "Downloading model payload: $MODEL_SETS"
    info "Parallel file downloads: $MODEL_DOWNLOAD_WORKERS"
    info "Xet high-performance mode: $HF_XET_HIGH_PERFORMANCE"

    COMFY_ROOT="$COMFY_ROOT" \
    MANIFEST="$MANIFEST" \
    MODEL_SETS="$MODEL_SETS" \
    MIN_FREE_GB="$MIN_FREE_GB" \
    MODEL_DOWNLOAD_WORKERS="$MODEL_DOWNLOAD_WORKERS" \
    HF_STAGE="$HF_STAGE" \
    HF_TOKEN="${HF_TOKEN:-}" \
    "$HF_VENV/bin/python" - <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import struct
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import unquote, urlparse

from huggingface_hub import get_hf_file_metadata, hf_hub_download, hf_hub_url

COMFY_ROOT = Path(os.environ["COMFY_ROOT"]).resolve()
MANIFEST = Path(os.environ["MANIFEST"]).resolve()
MODEL_SETS = {x.strip() for x in os.environ.get("MODEL_SETS", "").split(",") if x.strip()}
MIN_FREE_GB = float(os.environ.get("MIN_FREE_GB", "25"))
WORKERS = max(1, int(os.environ.get("MODEL_DOWNLOAD_WORKERS", "3")))
STAGE_ROOT = Path(os.environ["HF_STAGE"]).resolve()
TOKEN = os.environ.get("HF_TOKEN") or None

STAGE_ROOT.mkdir(parents=True, exist_ok=True)
print_lock = threading.Lock()

def say(msg: str):
    with print_lock:
        print(msg, flush=True)

def enabled(model_set: str) -> bool:
    return model_set == "always" or model_set in MODEL_SETS

def parse_hf_url(url: str):
    p = urlparse(url)
    if p.netloc.lower() != "huggingface.co":
        raise ValueError(f"Only huggingface.co URLs are supported: {url}")
    parts = [unquote(x) for x in p.path.strip("/").split("/")]
    if len(parts) < 5 or parts[2] != "resolve":
        raise ValueError(f"Expected a Hugging Face /resolve/ URL: {url}")
    return "/".join(parts[:2]), parts[3], "/".join(parts[4:])

def safetensors_complete(path: Path) -> bool:
    try:
        size = path.stat().st_size
        if size < 16:
            return False
        with path.open("rb") as f:
            raw = f.read(8)
            if len(raw) != 8:
                return False
            header_size = struct.unpack("<Q", raw)[0]
            if header_size <= 2 or header_size > 100 * 1024 * 1024:
                return False
            if 8 + header_size > size:
                return False
            header = json.loads(f.read(header_size))
        max_end = 0
        tensors = 0
        for name, meta in header.items():
            if name == "__metadata__":
                continue
            if not isinstance(meta, dict):
                return False
            offsets = meta.get("data_offsets")
            if not isinstance(offsets, list) or len(offsets) != 2:
                return False
            start, end = offsets
            if not isinstance(start, int) or not isinstance(end, int) or start < 0 or end < start:
                return False
            max_end = max(max_end, end)
            tensors += 1
        return tensors > 0 and (8 + header_size + max_end) == size
    except Exception:
        return False

def local_usable(path: Path, expected: int | None) -> bool:
    if not path.is_file():
        return False
    actual = path.stat().st_size
    if expected is not None and actual != expected:
        return False
    if path.suffix.lower() == ".safetensors":
        return safetensors_complete(path)
    return actual > 1024 * 1024

def fmt_size(n: int | None) -> str:
    if n is None:
        return "unknown size"
    v = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.2f} {unit}"
        v /= 1024
    return f"{v:.2f} TB"

def fmt_rate(nbytes: int, seconds: float) -> str:
    if seconds <= 0:
        return "n/a"
    return f"{nbytes / seconds / 1024 / 1024:.1f} MB/s"

def free_bytes(path: Path) -> int:
    path.mkdir(parents=True, exist_ok=True)
    return shutil.disk_usage(path).free

entries = []
for raw in MANIFEST.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    cols = [x.strip() for x in raw.split("|")]
    if len(cols) < 4:
        raise RuntimeError(f"Bad manifest row: {raw}")
    model_set, subdir, output_name, url = cols[:4]
    optional = len(cols) >= 5 and cols[4].lower() == "optional"
    if enabled(model_set):
        entries.append((model_set, subdir, output_name, url, optional))

say(f"Selected {len(entries)} model/LoRA files from {MANIFEST.name}")
say(f"Parallel workers: {WORKERS}")

# Metadata first so disk requirements are known before launching parallel transfers.
prepared = []
mandatory_bytes = 0
for index, (model_set, subdir, output_name, url, optional) in enumerate(entries, 1):
    target = COMFY_ROOT / "models" / subdir / output_name
    target.parent.mkdir(parents=True, exist_ok=True)
    repo_id, revision, filename = parse_hf_url(url)

    expected = None
    try:
        meta = get_hf_file_metadata(
            hf_hub_url(repo_id=repo_id, filename=filename, revision=revision),
            token=TOKEN,
        )
        expected = meta.size
    except Exception as e:
        say(f"[metadata {index}/{len(entries)}] warning for {output_name}: {e}")

    if local_usable(target, expected):
        say(f"[{index}/{len(entries)}] SKIP {output_name} ({fmt_size(target.stat().st_size)})")
        continue

    if target.exists():
        target.unlink()

    if expected is not None and not optional:
        mandatory_bytes += expected

    prepared.append((index, model_set, subdir, output_name, url, optional, repo_id, revision, filename, expected, target))

reserve = int(MIN_FREE_GB * 1024**3)
free = free_bytes(COMFY_ROOT)
if mandatory_bytes and free < mandatory_bytes + reserve:
    raise RuntimeError(
        f"Not enough disk space for selected downloads. "
        f"Free={fmt_size(free)}, required≈{fmt_size(mandatory_bytes)}, "
        f"reserve={MIN_FREE_GB:.0f} GB."
    )

say(f"Need to download {len(prepared)} file(s), approximately {fmt_size(mandatory_bytes)} mandatory data.")

def download_one(job):
    index, model_set, subdir, output_name, url, optional, repo_id, revision, filename, expected, target = job
    started = time.monotonic()
    stage = STAGE_ROOT / re.sub(r"[^A-Za-z0-9_.-]+", "--", repo_id)
    stage.mkdir(parents=True, exist_ok=True)

    say(f"[{index}/{len(entries)}] START {output_name} ({fmt_size(expected)})")
    downloaded = Path(
        hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            revision=revision,
            token=TOKEN,
            local_dir=stage,
        )
    )

    if not local_usable(downloaded, expected):
        raise RuntimeError(f"Downloaded file failed validation: {downloaded}")

    installing = target.with_name(target.name + ".installing")
    installing.unlink(missing_ok=True)
    shutil.move(str(downloaded), str(installing))
    os.replace(installing, target)

    if not local_usable(target, expected):
        target.unlink(missing_ok=True)
        raise RuntimeError(f"Final file failed validation: {target}")

    elapsed = time.monotonic() - started
    size = target.stat().st_size
    say(
        f"[{index}/{len(entries)}] DONE  {output_name} | "
        f"{fmt_size(size)} | {elapsed/60:.1f} min | {fmt_rate(size, elapsed)}"
    )
    return output_name, size, elapsed

failures = []
optional_failures = []
completed_bytes = 0
transfer_started = time.monotonic()

with ThreadPoolExecutor(max_workers=WORKERS) as pool:
    futures = {pool.submit(download_one, job): job for job in prepared}
    for fut in as_completed(futures):
        job = futures[fut]
        output_name = job[3]
        optional = job[5]
        try:
            _, size, elapsed = fut.result()
            completed_bytes += size
        except Exception as e:
            msg = f"{output_name}: {e}"
            if optional:
                optional_failures.append(msg)
                say(f"WARN optional download failed; setup will continue: {msg}")
            else:
                failures.append(msg)
                say(f"ERROR mandatory download failed: {msg}")

elapsed = time.monotonic() - transfer_started
if completed_bytes:
    say(
        f"Aggregate model transfer: {fmt_size(completed_bytes)} in {elapsed/60:.1f} min "
        f"({fmt_rate(completed_bytes, elapsed)} effective)"
    )

try:
    shutil.rmtree(STAGE_ROOT)
except OSError:
    pass

if optional_failures:
    say("")
    say("Optional LoRA/download warnings (setup is continuing):")
    for item in optional_failures:
        say(f" - {item}")

if failures:
    print("\nMandatory workflow downloads failed:", file=sys.stderr)
    for item in failures:
        print(f" - {item}", file=sys.stderr)
    raise SystemExit(1)

if optional_failures:
    say("All mandatory model files passed validation. Optional failures were ignored.")
else:
    say("All selected model files passed validation.")
PY

    stage_end
}

get_node() {
    local dir="$1"
    local url="$2"
    local target="$COMFY_ROOT/custom_nodes/$dir"
    local attempt=1
    local delay=2

    if [[ -d "$target/.git" ]]; then
        if [[ "$UPDATE_CUSTOM_NODES" == "1" ]]; then
            info "Updating $dir"
            git -C "$target" pull --ff-only >/dev/null 2>&1 || warn "Could not update $dir; keeping current checkout."
        else
            info "Keeping existing $dir"
        fi
        return 0
    fi

    if [[ -e "$target" ]]; then
        warn "$target exists but is not a Git checkout; replacing it."
        rm -rf "$target"
    fi

    info "Cloning $dir"
    while (( attempt <= GIT_CLONE_ATTEMPTS )); do
        # A failed clone can leave a non-empty partial directory which prevents
        # the next attempt, so always begin with a clean target.
        rm -rf "$target"
        info "Clone attempt $attempt/$GIT_CLONE_ATTEMPTS: $dir"

        # Never pause unattended startup at a username/password prompt. Git's
        # stderr intentionally remains visible in the boot log for diagnosis.
        if GIT_TERMINAL_PROMPT=0 git clone --depth=1 --filter=blob:none "$url" "$target"; then
            info "Cloned $dir successfully."
            return 0
        fi

        rm -rf "$target"
        if (( attempt < GIT_CLONE_ATTEMPTS )); then
            warn "Clone attempt $attempt failed for $dir; retrying in ${delay}s."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    die "Failed to clone $url after $GIT_CLONE_ATTEMPTS attempts."
}

install_custom_nodes() {
    stage_begin "Installing workflow custom nodes"
    mkdir -p "$COMFY_ROOT/custom_nodes"

    [[ -f "$NODE_MANIFEST" ]] || die "Custom-node manifest not found: $NODE_MANIFEST"
    local raw dir url remainder
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        [[ -z "${raw//[[:space:]]/}" || "$raw" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r dir url remainder <<< "$raw"
        dir="$(echo "$dir" | xargs)"
        url="$(echo "$url" | xargs)"
        [[ -n "$dir" && -n "$url" ]] || die "Bad custom-node row: $raw"
        get_node "$dir" "$url"
    done < "$NODE_MANIFEST"

    stage_end
}

install_node_requirements() {
    stage_begin "Installing custom-node Python requirements"
    local req node hash marker
    local pip_args=(--disable-pip-version-check --no-input --prefer-binary --upgrade-strategy only-if-needed)

    if [[ -f "$PIP_CONSTRAINT_FILE" ]]; then
        export PIP_CONSTRAINT="$PIP_CONSTRAINT_FILE"
        info "Protecting RunPod CUDA/Torch stack with $PIP_CONSTRAINT_FILE"
    else
        warn "RunPod pip constraint file not found. Continuing without it."
    fi

    local raw url remainder
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        [[ -z "${raw//[[:space:]]/}" || "$raw" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r node url remainder <<< "$raw"
        node="$(echo "$node" | xargs)"
        req="$COMFY_ROOT/custom_nodes/$node/requirements.txt"
        [[ -f "$req" ]] || continue

        # These two are maintained by the base image; do not reinstall their deps.
        case "$node" in
            ComfyUI-Manager|ComfyUI-KJNodes|Civicomfy|ComfyUI-RunpodDirect) continue ;;
        esac

        hash="$(sha256sum "$req" | awk '{print $1}')"
        marker="$NODE_STATE/${node}.requirements.sha256"
        if [[ -f "$marker" && "$(cat "$marker")" == "$hash" ]]; then
            info "Requirements unchanged: $node"
            continue
        fi

        info "pip requirements: $node"
        if "$COMFY_VENV/bin/python" -m pip install -q "${pip_args[@]}" -r "$req"; then
            printf '%s' "$hash" > "$marker"
        else
            die "Python requirements failed for $node ($req)"
        fi
    done < "$NODE_MANIFEST"

    # Small dependencies used by the supplied workflows/nodes.
    "$COMFY_VENV/bin/python" -m pip install -q "${pip_args[@]}" piexif lark librosa
    stage_end
}

install_workflows() {
    stage_begin "Installing ComfyUI workflows"
    local dest="$COMFY_ROOT/user/default/workflows"
    mkdir -p "$dest"

    if set_enabled minimax && [[ -f "$WORKFLOW_SRC/MINIMAX_H3_ULTRA_TURBO_WORKFLOW-V2-5090.json" ]]; then
        cp -f "$WORKFLOW_SRC/MINIMAX_H3_ULTRA_TURBO_WORKFLOW-V2-5090.json" "$dest/"
        info "Installed MiniMax H3 workflow."
    fi
    stage_end
}

verify_comfy_gpu() {
    stage_begin "Verifying ComfyUI GPU environment"
    "$COMFY_VENV/bin/python" - <<'PY'
import sys
import torch

print("Torch:", torch.__version__)
print("CUDA runtime reported by Torch:", torch.version.cuda)
available = torch.cuda.is_available()
print("CUDA available:", available)

if not available:
    print("ERROR: Torch cannot initialise CUDA on this RunPod host.", file=sys.stderr)
    raise SystemExit(1)

print("GPU:", torch.cuda.get_device_name(0))
major, minor = torch.cuda.get_device_capability(0)
print(f"Compute capability: sm_{major}{minor}")
PY
    stage_end
}

main() {
    TOTAL_STARTED="$(date +%s)"
    ensure_system_packages
    configure_git_transport
    preflight_gpu_host
    wait_for_comfy_base

    ensure_hf_downloader
    install_custom_nodes
    install_node_requirements
    download_models
    install_workflows
    verify_comfy_gpu

    local total_elapsed
    total_elapsed="$(( $(date +%s) - TOTAL_STARTED ))"
    log "Bootstrap complete"
    info "Total bootstrap time: $(format_seconds "$total_elapsed")"
}

main "$@"
