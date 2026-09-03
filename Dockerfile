FROM runpod/comfyui:cuda13.0

# Build and diagnostic tools are baked into the wrapper so SageAttention can
# compile on the attached SM120 GPU and troubleshooting commands are available.
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      build-essential git iproute2 lsof procps psmisc python3-dev python3-pip \
      libcublas-dev-13-0 libcusolver-dev-13-0 libcusparse-dev-13-0 \
 && rm -rf /var/lib/apt/lists/*

COPY bootstrap.sh start-services.sh install-sageattention-sm120.sh models.manifest custom-nodes.manifest /opt/runpod-setup/
COPY workflows/ /opt/runpod-setup/workflows/
COPY docker-entrypoint.sh /runpod-custom-entrypoint.sh
RUN chmod +x /runpod-custom-entrypoint.sh /opt/runpod-setup/*.sh

ENTRYPOINT ["/runpod-custom-entrypoint.sh"]
