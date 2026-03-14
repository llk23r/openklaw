FROM ghcr.io/openclaw/openclaw:latest

USER root

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY templates/ /app/templates/

ENV OPENCLAW_STATE_DIR=/data/.openclaw

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
