# ==========================================
# 下载和提取二进制文件
# ==========================================
FROM ubuntu:26.04 AS builder
COPY scripts /scripts
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    chmod +x /scripts/utils.sh && \
    grep -q 'archive.ubuntu.com' /etc/apt/sources.list.d/ubuntu.sources && \
      sed -i -E 's/(archive|security|ports)\.ubuntu\.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources || true && \
    /scripts/utils.sh apt_install curl wget unzip tar ca-certificates git jq
WORKDIR /downloads

# Helm
FROM builder AS builder-helm
ENV HELM_VERSION=3.22.0
RUN /scripts/utils.sh download_tarball "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "/downloads" "linux-amd64/helm" && \
    install /downloads/helm /usr/local/bin
ENV HELM_PLUGINS=/downloads/helm-plugins
RUN mkdir -p $HELM_PLUGINS && \
    helm plugin install https://github.com/databus23/helm-diff && \
    helm plugin install https://github.com/jkroepke/helm-secrets && \
    helm plugin install https://github.com/helm-unittest/helm-unittest

# Helmfile
FROM builder AS builder-helmfile
#ENV HELMFILE_VERSION=v1.5.5
RUN /scripts/utils.sh download_github_tarball "helmfile/helmfile" "${HELMFILE_VERSION}" "*linux_amd64.tar.gz" "/downloads" "helmfile"

# Kubectl
FROM builder AS builder-kubectl
RUN KUBE_STABLE="$(curl -L -s https://dl.k8s.io/release/stable.txt)" && \
    /scripts/utils.sh download_binary "https://dl.k8s.io/release/${KUBE_STABLE}/bin/linux/amd64/kubectl" "kubectl"

# SOPS
FROM builder AS builder-sops
#ENV SOPS_VERSION=v3.13.3
RUN /scripts/utils.sh download_github_binary "getsops/sops" "${SOPS_VERSION}" "*linux.amd64" "sops"

# Docker
FROM builder AS builder-docker
ENV DOCKER_VERSION=29.8.0
RUN /scripts/utils.sh download_tarball "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" "/downloads" "docker/"

# fnm + Node.js LTS
FROM builder AS builder-fnm
ENV FNM_DIR=/usr/local/fnm
RUN /scripts/utils.sh run_install_script "https://fnm.vercel.app/install" --install-dir /usr/local/bin --skip-shell && \
    eval "$(fnm env)" && \
    fnm install --lts && \
    fnm default lts-latest

# uv
FROM builder AS builder-uv
ENV UV_UNMANAGED_INSTALL=/usr/local/bin
RUN /scripts/utils.sh run_install_script "https://astral.sh/uv/install.sh" && \
    uv --version

# ==========================================
# 运行时镜像
# ==========================================
FROM ubuntu:26.04
COPY scripts /scripts
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    chmod +x /scripts/utils.sh && \
    grep -q 'archive.ubuntu.com' /etc/apt/sources.list.d/ubuntu.sources && \
      sed -i -E 's/(archive|security|ports)\.ubuntu\.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources || true && \
    /scripts/utils.sh apt_install \
        bash bash-completion locales ca-certificates sudo \
        curl wget git gnupg openssh-client \
        tar unzip xz-utils bzip2 zstd \
        jq gawk less vim patch \
        htop ncdu tree file tmux ripgrep \
        dnsutils netcat-openbsd iproute2 iputils-ping \
        openssl nftables psmisc lsof strace \
        make build-essential \
        ffmpeg \
        skopeo uidmap && \
    locale-gen zh_CN.UTF-8 en_US.UTF-8
# 从 Builder 阶段复制工具
COPY --from=builder-docker /downloads/ /usr/local/bin/
COPY --from=hashicorp/terraform:latest /bin/terraform /usr/local/bin/
COPY --from=mikefarah/yq:latest /usr/bin/yq /usr/local/bin/
COPY --from=builder-helm /downloads/helm /usr/local/bin/helm
COPY --from=builder-helm /downloads/helm-plugins /usr/local/share/helm/plugins
ENV HELM_PLUGINS=/usr/local/share/helm/plugins
COPY --from=builder-helmfile /downloads/helmfile /usr/local/bin/helmfile
COPY --from=builder-kubectl /downloads/kubectl /usr/local/bin/kubectl
COPY --from=builder-sops /downloads/sops /usr/local/bin/sops

# fnm + Node.js LTS
ENV FNM_DIR=/usr/local/fnm
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
COPY --from=builder-fnm /usr/local/bin/fnm /usr/local/bin/fnm
COPY --from=builder-fnm /usr/local/fnm /usr/local/fnm
RUN ln -sf "$(fnm exec --using=default which node)" /usr/local/bin/node && \
    ln -sf "$(fnm exec --using=default which npm)" /usr/local/bin/npm && \
    ln -sf "$(fnm exec --using=default which npx)" /usr/local/bin/npx

# UV + Python
COPY --from=builder-uv /usr/local/bin/uv /usr/local/bin/uv
ENV UV_PYTHON_INSTALL_DIR=/usr/local/python
RUN uv python install 3.12 && \
    ln -sf $(uv python find 3.12) /usr/local/bin/python3.12 && \
    ln -sf $(uv python find 3.12) /usr/local/bin/python3

# chromium
RUN npx playwright install-deps chromium
USER ubuntu
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --non-interactive
WORKDIR /home/ubuntu