# Tier B: install mechanics at real production paths inside a throwaway HOME.
# No agent auth, no API key, no Cosift service. The run is executed with
# --network none; only this build step is allowed to reach the network.
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --home-dir /home/cosift --shell /bin/sh --uid 1001 cosift \
    && mkdir -p /opt/cosift-test \
    && chown cosift:cosift /opt/cosift-test

COPY fixtures/install-clis.sh /usr/local/lib/cosift-install-clis.sh
RUN sh /usr/local/lib/cosift-install-clis.sh /opt/cosift-test/cli-report.tsv

# Pristine copy of the throwaway HOME; each assertion group restores from it.
RUN install -d -m 0755 -o cosift -g cosift /opt/cosift-test/home-template

ENV HOME=/home/cosift \
    XDG_CONFIG_HOME=/home/cosift/.config \
    CLI_REPORT=/opt/cosift-test/cli-report.tsv \
    NO_COLOR=1 \
    CI=1
USER cosift
WORKDIR /home/cosift
CMD ["sh", "/opt/fixtures/assertions.sh"]
