FROM node:22-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git python3 procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
RUN mkdir -p /root/.openclaw /workspace

COPY entrypoint.sh /entrypoint.sh
COPY openclaw-configure.py /usr/local/bin/openclaw-configure
COPY install-openclaw.sh /usr/local/bin/install-openclaw
RUN chmod +x /entrypoint.sh /usr/local/bin/openclaw-configure /usr/local/bin/install-openclaw

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
