FROM runpod/comfyui:cuda13.0

# Small diagnostic tools are baked into the wrapper so fresh pods do not spend
# time installing them and troubleshooting commands are always available.
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      iproute2 lsof procps psmisc \
 && rm -rf /var/lib/apt/lists/*

COPY bootstrap.sh start-services.sh models.manifest custom-nodes.manifest /opt/runpod-setup/
COPY workflows/ /opt/runpod-setup/workflows/
COPY docker-entrypoint.sh /runpod-custom-entrypoint.sh
RUN chmod +x /runpod-custom-entrypoint.sh /opt/runpod-setup/*.sh

ENTRYPOINT ["/runpod-custom-entrypoint.sh"]
