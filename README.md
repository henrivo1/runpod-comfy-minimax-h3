# RunPod ComfyUI + MiniMax H3

Standalone RTX 5090/CUDA 13 RunPod image for ComfyUI with the supplied MiniMax
H3 5090 workflow. It contains no Krea2 workflow/model manifest and never starts
AI Toolkit.

The image inherits `runpod/comfyui:cuda13.0`, retaining base-image FileBrowser
and JupyterLab. Its wrapper installs only MiniMax H3 nodes, models, LoRA, VAE,
preview, and workflow assets.

## Included automation

- Driver/CUDA/Blackwell preflight before large downloads.
- Parallel Hugging Face Xet transfers and mandatory/optional validation.
- Exact `MINIMAX_H3_ULTRA_TURBO_WORKFLOW-V2-5090.json` workflow.
- Restart fast path under `/workspace/.runpod-minimax-h3`.
- Automatic first-install ComfyUI restart.
- Continuous ComfyUI health supervision and recovery.
- Automatic SageAttention source build for CUDA 13 / RTX 5090 (`sm_120a`).
- Automatic detection of either RunPod's system Python or a ComfyUI venv.
- MiniMax H3 workflow patches set to the Blackwell-safe `auto` mode.
- Immutable GHCR `sha-<full-git-commit>` images only.

## SageAttention

The first bootstrap compiles the official SageAttention source specifically for
the pod's RTX 5090. The build is validated with a real CUDA kernel smoke test and
recorded under `/workspace/.runpod-node-deps`, so normal restarts use the fast
path. If the container is recreated and its system Python packages disappear,
the import check automatically triggers a rebuild.

Every `Patch Sage Attention KJ` node in the supplied MiniMax H3 workflow is
enabled with:

- `sage_attention: auto`
- `allow_compile: false`

Do not add ComfyUI's global `--use-sage-attention` launch flag and do not force
one of the named FP16/FP8 backends. H3 on Blackwell currently relies on the
automatic dispatcher, while disabling compilation avoids CUDA-graph reuse paths
that can produce incorrect output.

Build progress and any failure are written to
`/workspace/start-services-boot.log`. Advanced overrides include
`SAGEATTN_SOURCE_REF` and `MAX_JOBS`.

See `SETUP-GUIDE.md` for deployment settings.
