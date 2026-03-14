FROM ghcr.io/openclaw/openclaw:latest

USER root

# Create data directories
RUN mkdir -p /data/.openclaw /data/workspace && \
    chown -R node:node /data

# Copy files
COPY openclaw.json /tmp/openclaw.json
COPY server.cjs /app/server.cjs

ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_GATEWAY_BIND=lan

EXPOSE 8080

CMD ["node", "/app/server.cjs"]
