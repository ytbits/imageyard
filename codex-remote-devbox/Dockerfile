FROM node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

ARG CODEX_VERSION="0.149.0"
ARG IMAGE_VERSION="codex-0.149.0-r3"
ARG DOCKER_CLI_PACKAGE_VERSION="5:29.7.2-1~debian.12~bookworm"
ARG DOCKER_BUILDX_PACKAGE_VERSION="0.36.1-1~debian.12~bookworm"
ARG DOCKER_COMPOSE_PACKAGE_VERSION="5.5.0-1~debian.12~bookworm"
ARG DOCKER_APT_GPG_SHA256="1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"

LABEL org.opencontainers.image.title="Codex Remote Devbox" \
      org.opencontainers.image.description="SSH-accessible remote development environment for Codex Desktop" \
      org.opencontainers.image.source="https://github.com/ytbits/imageyard" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/node:24.19.0-bookworm-slim" \
      org.opencontainers.image.base.digest="sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03" \
      io.imageyard.codex.version="${CODEX_VERSION}" \
      io.imageyard.node.version="24.19.0" \
      io.imageyard.docker-ce-cli.package-version="${DOCKER_CLI_PACKAGE_VERSION}" \
      io.imageyard.docker-buildx-plugin.package-version="${DOCKER_BUILDX_PACKAGE_VERSION}" \
      io.imageyard.docker-compose-plugin.package-version="${DOCKER_COMPOSE_PACKAGE_VERSION}" \
      io.imageyard.docker.apt-gpg-sha256="${DOCKER_APT_GPG_SHA256}"

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      bash \
      bubblewrap \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      fd-find \
      file \
      gh \
      git \
      git-lfs \
      iproute2 \
      iputils-ping \
      jq \
      less \
      lsof \
      netcat-openbsd \
      openssh-client \
      openssh-server \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      strace \
      sudo \
      tini; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl --fail --location --silent --show-error \
      https://download.docker.com/linux/debian/gpg \
      --output /etc/apt/keyrings/docker.asc; \
    printf '%s  %s\n' "$DOCKER_APT_GPG_SHA256" /etc/apt/keyrings/docker.asc \
      | sha256sum --check --strict; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://download.docker.com/linux/debian' \
      'Suites: bookworm' \
      'Components: stable' \
      "Architectures: $(dpkg --print-architecture)" \
      'Signed-By: /etc/apt/keyrings/docker.asc' \
      > /etc/apt/sources.list.d/docker.sources; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      "docker-ce-cli=${DOCKER_CLI_PACKAGE_VERSION}" \
      "docker-buildx-plugin=${DOCKER_BUILDX_PACKAGE_VERSION}" \
      "docker-compose-plugin=${DOCKER_COMPOSE_PACKAGE_VERSION}"; \
    test "$(dpkg-query -W -f='${Version}' docker-ce-cli)" = "$DOCKER_CLI_PACKAGE_VERSION"; \
    test "$(dpkg-query -W -f='${Version}' docker-buildx-plugin)" = "$DOCKER_BUILDX_PACKAGE_VERSION"; \
    test "$(dpkg-query -W -f='${Version}' docker-compose-plugin)" = "$DOCKER_COMPOSE_PACKAGE_VERSION"; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; \
    npm install --global --omit=dev "@openai/codex@${CODEX_VERSION}"; \
    npm cache clean --force; \
    groupmod --new-name codex node; \
    usermod --login codex --home /home/codex --move-home --shell /bin/bash node; \
    passwd --delete codex; \
    install -d -o codex -g codex -m 0700 /home/codex /workspaces; \
    install -d -o root -g root -m 0755 /run/sshd; \
    install -d -o root -g root -m 0755 /run/secrets /run/secrets/docker-host; \
    ln -s /usr/bin/fdfind /usr/local/bin/fd; \
    printf '%s\n' 'codex ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/codex; \
    chmod 0440 /etc/sudoers.d/codex; \
    visudo --check --file=/etc/sudoers.d/codex; \
    git lfs install --system --skip-repo

COPY --chmod=0644 sshd_config /etc/ssh/sshd_config
COPY --chmod=0755 entrypoint.sh /usr/local/bin/codex-remote-devbox-entrypoint

RUN set -eux; \
    test "$(id -u codex)" = 1000; \
    test "$(id -g codex)" = 1000; \
    test "$(getent passwd codex | cut -d: -f7)" = /bin/bash; \
    test "$(codex --version)" = "codex-cli ${CODEX_VERSION}"; \
    codex app-server --help >/dev/null; \
    install -d -o root -g root -m 0755 /run/codex-remote-devbox; \
    ssh-keygen -q -t ed25519 -N '' -f /run/codex-remote-devbox/ssh_host_ed25519_key; \
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config; \
    rm -rf /run/codex-remote-devbox; \
    test -z "$(find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' -print -quit)"

ENV HOME=/home/codex \
    SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER root
WORKDIR /workspaces

EXPOSE 2222
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/codex-remote-devbox-entrypoint"]
