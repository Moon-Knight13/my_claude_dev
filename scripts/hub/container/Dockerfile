# Lane 2 image (SP1a story 3.1; AD-18, AD-21, AD-23).
#
# Built only by `lane2 install`, hub-side, from the installed commit's tree —
# never from a workspace or a checkout. The base image and the Claude Code
# version come from scripts/hub/pin-manifest.json; install refuses to build
# without a pinned base digest and an exact Claude Code version >= 2.1.299.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION
# Exact version from the npm "latest" dist-tag, installed root-owned.
RUN npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force \
    && chown -R root:root /usr/local/lib/node_modules /usr/local/bin

# Managed settings rendered by lane2 install (auto-update off): the seed of the
# integration policy. Root-owned, read-only to the container user.
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chown -R root:root /etc/claude-code && chmod 0755 /etc/claude-code \
    && chmod 0644 /etc/claude-code/managed-settings.json
ENV DISABLE_AUTOUPDATER=1

# Non-root by default; the workspace is the only writable bind mount.
USER node
WORKDIR /workspace
ENTRYPOINT ["claude"]
