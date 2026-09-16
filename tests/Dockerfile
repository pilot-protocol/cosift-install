# Throwaway image for the cosift-install container test harness.
# Build context is tests/ :  docker build -f tests/Dockerfile tests/
FROM node:22-bookworm-slim

ARG CLAUDE_VERSION=2.1.273
ARG CODEX_VERSION=0.154.0
ARG OPENCODE_VERSION=1.18.31

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        procps \
        coreutils \
        diffutils \
        bash \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1001 --shell /bin/bash tester

RUN mkdir -p /opt/cosift-test/stubs
COPY fixtures/stubs/harness-stub.py /opt/cosift-test/stubs/harness-stub.py
RUN chmod 0755 /opt/cosift-test/stubs/harness-stub.py

# Each harness: try the real CLI, fall back to a loudly-named stub. The
# provenance file is what tests/run.sh reads to print its STUB banner.
RUN set -eu; \
    : > /opt/cosift-test/harness-provenance.env; \
    if npm i -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" >/dev/null 2>&1 \
       && command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then \
        echo "CLAUDE_PROVENANCE=real" >> /opt/cosift-test/harness-provenance.env; \
        echo "CLAUDE_VERSION=${CLAUDE_VERSION}" >> /opt/cosift-test/harness-provenance.env; \
    else \
        ln -sf /opt/cosift-test/stubs/harness-stub.py /usr/local/bin/claude; \
        echo "CLAUDE_PROVENANCE=stub" >> /opt/cosift-test/harness-provenance.env; \
        echo "CLAUDE_VERSION=stub" >> /opt/cosift-test/harness-provenance.env; \
    fi

RUN set -eu; \
    if npm i -g "@openai/codex@${CODEX_VERSION}" >/dev/null 2>&1 \
       && command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then \
        echo "CODEX_PROVENANCE=real" >> /opt/cosift-test/harness-provenance.env; \
        echo "CODEX_VERSION=${CODEX_VERSION}" >> /opt/cosift-test/harness-provenance.env; \
    else \
        ln -sf /opt/cosift-test/stubs/harness-stub.py /usr/local/bin/codex; \
        echo "CODEX_PROVENANCE=stub" >> /opt/cosift-test/harness-provenance.env; \
        echo "CODEX_VERSION=stub" >> /opt/cosift-test/harness-provenance.env; \
    fi

RUN set -eu; \
    if npm i -g "opencode-ai@${OPENCODE_VERSION}" >/dev/null 2>&1 \
       && command -v opencode >/dev/null 2>&1 && opencode --version >/dev/null 2>&1; then \
        echo "OPENCODE_PROVENANCE=real" >> /opt/cosift-test/harness-provenance.env; \
        echo "OPENCODE_VERSION=${OPENCODE_VERSION}" >> /opt/cosift-test/harness-provenance.env; \
    else \
        ln -sf /opt/cosift-test/stubs/harness-stub.py /usr/local/bin/opencode; \
        echo "OPENCODE_PROVENANCE=stub" >> /opt/cosift-test/harness-provenance.env; \
        echo "OPENCODE_VERSION=stub" >> /opt/cosift-test/harness-provenance.env; \
    fi

RUN chmod 0644 /opt/cosift-test/harness-provenance.env

USER tester
ENV HOME=/home/tester
WORKDIR /home/tester
CMD ["bash"]
