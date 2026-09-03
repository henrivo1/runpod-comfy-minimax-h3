#!/usr/bin/env bash
# Build the official SageAttention source for RTX 50-series (SM120) inside the
# exact Python environment used by ComfyUI. Safe to re-run.
set -Eeuo pipefail

COMFY_PYTHON="${COMFY_PYTHON:-$(command -v python3)}"
SAGEATTN_SOURCE_REF="${SAGEATTN_SOURCE_REF:-d1a57a546c3d395b1ffcbeecc66d81db76f3b4b5}"
SAGEATTN_STATE_DIR="${SAGEATTN_STATE_DIR:-/workspace/.runpod-node-deps}"
SAGEATTN_STATE_FILE="$SAGEATTN_STATE_DIR/sageattention-sm120.state"
SAGEATTN_BUILD_LOG="${SAGEATTN_BUILD_LOG:-/workspace/sageattention-build.log}"

info() { printf '  -> %s\n' "$*"; }
die()  { printf '  [ERROR] %s\n' "$*" >&2; exit 1; }

[[ -x "$COMFY_PYTHON" ]] || die "ComfyUI Python is not executable: $COMFY_PYTHON"
command -v nvcc >/dev/null 2>&1 || die "nvcc is required to compile SageAttention."

runtime="$($COMFY_PYTHON - <<'PY'
import torch
major, minor = torch.cuda.get_device_capability(0)
print(f"{torch.__version__}|{torch.version.cuda}|{major}.{minor}")
PY
)"
IFS='|' read -r torch_version torch_cuda compute_capability <<< "$runtime"

[[ "$compute_capability" == "12.0" ]] || \
    die "This image targets RTX 5090/SM120; detected compute capability $compute_capability."
[[ "$torch_cuda" == 13.* ]] || \
    die "This CUDA 13 image requires a cu130 PyTorch runtime; detected CUDA $torch_cuda."

expected_state="$torch_version|$torch_cuda|$compute_capability|$SAGEATTN_SOURCE_REF"
mkdir -p "$SAGEATTN_STATE_DIR"

if [[ -f "$SAGEATTN_STATE_FILE" ]] && \
   [[ "$(cat "$SAGEATTN_STATE_FILE" 2>/dev/null || true)" == "$expected_state" ]] && \
   "$COMFY_PYTHON" -c 'import sageattention' >/dev/null 2>&1; then
    info "SageAttention SM120 build already matches Torch $torch_version / CUDA $torch_cuda."
    exit 0
fi

cuda_home="$($COMFY_PYTHON -c 'from torch.utils.cpp_extension import CUDA_HOME; print(CUDA_HOME or "")')"
if [[ -z "$cuda_home" ]]; then
    nvcc_path="$(readlink -f "$(command -v nvcc)")"
    cuda_home="$(dirname "$(dirname "$nvcc_path")")"
fi
[[ -x "$cuda_home/bin/nvcc" ]] || die "Could not locate nvcc under CUDA_HOME=$cuda_home"

# Torch's CUDAContextLight header imports all four of these CUDA development
# headers. Runtime-only CUDA images can contain nvcc and the shared libraries
# while still omitting the headers, which otherwise fails only after a long
# SageAttention compile.
for header in cusparse.h cublas_v2.h cublasLt.h cusolverDn.h; do
    [[ -f "$cuda_home/include/$header" ]] || \
        die "Missing CUDA development header $cuda_home/include/$header. Rebuild the image with the CUDA 13 cuSPARSE, cuBLAS, and cuSOLVER development packages."
done

pip_args=(--disable-pip-version-check --no-input)
if "$COMFY_PYTHON" -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    pip_args+=(--break-system-packages)
fi

info "Compiling SageAttention for SM120 with Torch $torch_version / CUDA $torch_cuda."
info "Full compiler output will be saved to $SAGEATTN_BUILD_LOG."
"$COMFY_PYTHON" -m pip install "${pip_args[@]}" --upgrade-strategy only-if-needed \
    ninja packaging setuptools wheel

mkdir -p "$(dirname "$SAGEATTN_BUILD_LOG")"
CUDA_HOME="$cuda_home" \
TORCH_CUDA_ARCH_LIST="12.0" \
MAX_JOBS="${MAX_JOBS:-1}" \
EXT_PARALLEL="${EXT_PARALLEL:-1}" \
NVCC_APPEND_FLAGS="${NVCC_APPEND_FLAGS:---threads=1}" \
"$COMFY_PYTHON" -m pip install "${pip_args[@]}" \
    --no-cache-dir --no-build-isolation --no-deps --force-reinstall \
    "git+https://github.com/thu-ml/SageAttention.git@$SAGEATTN_SOURCE_REF" \
    2>&1 | tee "$SAGEATTN_BUILD_LOG"

"$COMFY_PYTHON" - <<'PY'
import torch
from sageattention import sageattn

q = torch.randn((1, 8, 1024, 128), device="cuda", dtype=torch.float16)
out = sageattn(q, q, q, tensor_layout="HND", is_causal=False)
torch.cuda.synchronize()
if out.shape != q.shape or not torch.isfinite(out).all().item():
    raise RuntimeError(f"SageAttention smoke test failed: shape={tuple(out.shape)}")
print("SageAttention SM120 smoke test passed:", tuple(out.shape))
PY

printf '%s\n' "$expected_state" > "$SAGEATTN_STATE_FILE"
info "SageAttention SM120 installation complete."
