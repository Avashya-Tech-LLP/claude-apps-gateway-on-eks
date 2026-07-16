FROM node:22-alpine AS builder

ARG CLAUDE_VERSION=2.1.195
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}
RUN claude --version

FROM node:22-alpine

ARG CLAUDE_VERSION=2.1.195
LABEL org.opencontainers.image.title="claude-gateway" \
      org.opencontainers.image.version="${CLAUDE_VERSION}"

# Copy only the installed npm global from builder
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /usr/local/bin/claude /usr/local/bin/claude

# node:22-alpine already has a 'node' user at uid/gid 1000
RUN mkdir -p /data && chown node:node /data

USER node

EXPOSE 8080

ENTRYPOINT ["claude", "gateway", "--config", "/etc/gateway/gateway.yaml"]
