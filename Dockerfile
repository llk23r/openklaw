FROM ghcr.io/openclaw/openclaw:latest

USER root

COPY --chmod=755 entrypoint.sh /entrypoint.sh

ENV OPENCLAW_STATE_DIR=/data/.openclaw

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
