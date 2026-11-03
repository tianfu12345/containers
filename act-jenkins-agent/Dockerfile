# ==========================================
# act / Jenkins agent
#
# 基础镜像是 nektos/act 官方推荐的运行环境（catthehacker/ubuntu），
# 因此容器本身就是"GitHub 托管 runner 的等价环境"：
# act 以 -self-hosted 模式在容器内就地执行 .github/workflows/*.yml，
# 不再嵌套 Docker（services / container / docker:// action 除外）。
#
# 基础镜像 tag 固定为 act-24.04，不使用 act-latest：
# 上游 README 已列出 act-26.04，但 ghcr 上该 tag 尚不存在，
# full-26.04 才有；act-latest 当前与 act-24.04 同 digest，
# 直接钉 24.04 可以避免上游下次切换到 26.04 时环境被动漂移。
# ==========================================
ARG BASE_IMAGE=ghcr.io/catthehacker/ubuntu:act-24.04
FROM ${BASE_IMAGE}

# FROM 前声明的 ARG 在 FROM 之后失效，需要用到的必须重新声明
ARG BASE_IMAGE
# act 本体版本；基础镜像只提供运行环境，不含 act 二进制
ARG ACT_VERSION=0.2.94
ARG TARGETARCH
ARG TZ=Etc/UTC

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ} \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    ACT_ACTION_CACHE_DIR=/var/lib/act/actions \
    ACT_CACHE_DIR=/var/lib/act/cache \
    ACT_ARTIFACT_DIR=/var/lib/act/artifacts

LABEL org.opencontainers.image.title="act-jenkins-agent" \
      org.opencontainers.image.description="Jenkins agent running GitHub Actions workflows locally via nektos/act (-self-hosted)" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      act.version="${ACT_VERSION}"

# ==========================================
# 补充工具
#
# 基础镜像 act-24.04 已自带：curl wget git git-lfs jq sudo ssh ca-certificates
# python3/pip/venv/pipx zstd yq moby-cli/buildx/compose，这里只补缺失项。
# - openjdk：Jenkins remoting 需要 JRE，基础镜像没有；按 21 → 25 → 17 回退，
#   兼容将来基础镜像升级到 26.04 后的包名变化。
# - tini：作为 PID1 转发信号，避免 sleep 容器里 act 子进程成为僵尸。
# - rsync/procps/build-essential：workflow 与 Jenkins 插件常见依赖。
# ==========================================
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tini procps rsync zip unzip xz-utils tar gzip \
        locales tzdata build-essential pkg-config; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-21-jre-headless \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-25-jre-headless \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ==========================================
# Node.js：复用基础镜像自带的那一份
#
# 基础镜像把 node 装在 /opt/acttoolcache/node/<version>/<arch>，
# 版本号在构建基础镜像时从 nodejs.org 取，我们不做任何固定，
# 重建基础镜像后本镜像自动跟随。
# 但它只把 24.x 的路径写进 /etc/environment 的 PATH，
# 而 /etc/environment 仅由 PAM 登录会话读取，
# Jenkins 的 sh 步骤是非登录 shell，未必拿到 node。
# 这里在构建期探测最高版本并软链到 /usr/local/bin，
# 不写死版本号，同时让 host 模式下的 act 能直接调用 node 执行 JS action。
# ==========================================
RUN set -eux; \
    case "$(uname -m)" in \
        aarch64|arm64) node_arch=arm64 ;; \
        *)             node_arch=x64 ;; \
    esac; \
    node_bin="$(find /opt/acttoolcache/node -mindepth 2 -maxdepth 2 -type d -name "${node_arch}" \
                | sort -V | tail -n 1)"; \
    test -n "${node_bin}" || { echo "no Node.js under /opt/acttoolcache/node" >&2; exit 1; }; \
    test -x "${node_bin}/bin/node"; \
    for b in node npm npx corepack; do \
        if [ -x "${node_bin}/bin/${b}" ]; then \
            ln -sfn "${node_bin}/bin/${b}" "/usr/local/bin/${b}"; \
        fi; \
    done; \
    node --version

# ==========================================
# act 本体
# ==========================================
RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
        amd64|x86_64) act_triple=Linux_x86_64 ;; \
        arm64|aarch64) act_triple=Linux_arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_${act_triple}.tar.gz"; \
    curl -fsSL -o checksums.txt "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/checksums.txt"; \
    awk -v f="act_${act_triple}.tar.gz" '$2 == f' checksums.txt | sha256sum -c -; \
    tar -xzf "act_${act_triple}.tar.gz" -C /usr/local/bin act; \
    chmod 0755 /usr/local/bin/act; \
    act --version; \
    rm -f "act_${act_triple}.tar.gz" checksums.txt

# ==========================================
# 持久化目录
#
# act 在 host 模式下把 tool cache 放在 <action-cache-path>/tool_cache，
# 而容器模式的 RUNNER_TOOL_CACHE 指向 /opt/hostedtoolcache。
# 基础镜像里的 /opt/hostedtoolcache 是空目录，
# 软链到持久卷后两种模式共用同一份缓存（setup-node/python/go 下载的东西只存一份）。
# full-* 镜像自带完整 tool cache，非空时保留原样，不覆盖。
#
# 运行时挂载：
#   -v /srv/act/actions:/var/lib/act/actions
#   -v /srv/act/cache:/var/lib/act/cache
#   -v /srv/act/artifacts:/var/lib/act/artifacts
# ==========================================
RUN set -eux; \
    mkdir -p /var/lib/act/cache /var/lib/act/artifacts /var/lib/act/actions/tool_cache /workspace; \
    chmod -R 0777 /var/lib/act /workspace; \
    if [ -z "$(ls -A /opt/hostedtoolcache 2>/dev/null || true)" ]; then \
        rm -rf /opt/hostedtoolcache; \
        ln -sfn /var/lib/act/actions/tool_cache /opt/hostedtoolcache; \
    fi

# 基础镜像已设置 git safe.directory '*'；这里只补默认分支与 detached HEAD 提示，
# 两者都会出现在 workflow 的 git 输出里，避免 noise。
RUN git config --system init.defaultBranch main; \
    git config --system advice.detachedHead false

# 保持 root：act-* 镜像的 runner 布局按 root 组织，
# Jenkins checkout 与 act 写出的文件不会出现 uid 冲突。
USER root

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
