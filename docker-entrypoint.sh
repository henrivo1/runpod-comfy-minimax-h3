#!/usr/bin/env bash
set -u

SETUP_DIR="/opt/runpod-setup"
BOOT_LOG="${BOOT_LOG:-/workspace/start-services-boot.log}"

mkdir -p /workspace

(
    set -Eeuo pipefail

    echo "============================================================"
    echo "RunPod custom bootstrap wrapper: $(date)"
    echo "============================================================"
    echo "Payload: ComfyUI + MiniMax H3"
    echo "Immutable setup files: $SETUP_DIR"

    # Give the official RunPod base process a moment to begin initialising.
    sleep 5

    echo "Starting custom RunPod services/bootstrap..."
    exec bash "$SETUP_DIR/start-services.sh"

) > "$BOOT_LOG" 2>&1 &

# Preserve all normal behaviour from runpod/comfyui:cuda13.0.
exec /start.sh
