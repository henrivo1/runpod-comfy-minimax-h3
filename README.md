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
- Immutable GHCR `sha-<full-git-commit>` images only.

See `SETUP-GUIDE.md` for deployment settings.
