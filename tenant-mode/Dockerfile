FROM node:22-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    SCREEN_WIDTH=1920 \
    SCREEN_HEIGHT=1080

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git jq python3 procps tmux \
    xvfb x11vnc fluxbox chromium fonts-liberation \
    tini \
    && npm install -g openclaw@latest @openai/codex@latest \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /installer
COPY . /installer
RUN chmod +x /installer/install-native.sh /installer/scripts/tenant-entrypoint.sh /installer/scripts/tenant-expire.sh \
    && find /installer/bundled-skills/agile-codex/scripts -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/installer/scripts/tenant-entrypoint.sh"]
