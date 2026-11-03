# syntax=docker/dockerfile:1
# =============================================================================
# act-jenkins-agent — Jenkins agent / GitHub-runner 等价环境
#
# 容器扮演"GitHub 托管 runner"的角色：act 以 -self-hosted 模式在容器内就地执行
# 仓库里的 .github/workflows/*.yml，不依赖 GitHub 服务端，也不创建嵌套容器
# （workflow 用到 services / container / docker:// action 时除外）。
#
# 基础镜像固定为 act 系列的版本化 tag，不用 act-latest，避免上游切换时环境漂移。
#
# 构建：docker build -t act-jenkins-agent:latest .
# 运行：三个持久卷必须挂载，见 README.md
#
# files/ 下的脚本与配置由 COPY 引入：
#   files/actrc                 act 默认配置，软链成 /etc/act/actrc 与 /root/.actrc
#   files/install-act.sh        下载 + 校验 + 安装 act 二进制
#   files/link-node.sh          把基础镜像自带的 Node 软链到 /usr/local/bin
#   files/actrc-entrypoint.sh   容器入口（tini 之后执行）
# =============================================================================
ARG BASE_IMAGE=ghcr.io/catthehacker/ubuntu:act-24.04
FROM ${BASE_IMAGE}

# RUNNER_TOOL_CACHE / AGENT_TOOLSDIRECTORY 是 actions/toolkit 的 tc.find() 实际读取的
# 变量，不能删。时区写死 UTC，与 GitHub 托管 runner 一致。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# pipefail：让 curl / awk | sha256sum 这类管道在中间环节失败时立即中止。
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -----------------------------------------------------------------------------
# 补充工具
#
# 基础镜像已自带 curl wget git git-lfs jq sudo ssh ca-certificates
# python3/pip/venv/pipx zstd yq moby-cli/buildx/compose，此处只补缺失项：
#   - openjdk：Jenkins remoting 需要 JRE，21 → 25 → 17 回退
#   - tini：PID 1，转发信号并回收 act 派生的子进程
#   - build-essential / pkg-config / rsync / procps：workflow 与插件常见依赖
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tini procps rsync zip unzip xz-utils tar gzip \
        locales tzdata build-essential pkg-config; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openjdk-21-jre-headless \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            openjdk-25-jre-headless \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            openjdk-17-jre-headless; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 持久化目录 + tool cache 归一 + git 默认项
#
# host 模式下 act 把 tool cache 放在 <action-cache-path>/tool_cache，容器模式用
# RUNNER_TOOL_CACHE(/opt/hostedtoolcache)。把后者软链到前者之后，两种模式共用同一份
# 数据，setup-node/python/go 下载的工具只存一份且都在持久卷里。
# full-* 基础镜像自带完整 tool cache，非空时保持镜像原值。
#
# 运行时挂载（缺一不可）：
#   -v /srv/act/actions:/var/lib/act/actions
#   -v /srv/act/cache:/var/lib/act/cache
#   -v /srv/act/artifacts:/var/lib/act/artifacts
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /var/lib/act/cache /var/lib/act/artifacts \
             /var/lib/act/actions/tool_cache /etc/act /workspace; \
    chmod -R 0777 /var/lib/act /workspace; \
    if [ -z "$(ls -A /opt/hostedtoolcache 2>/dev/null || true)" ]; then \
        rm -rf /opt/hostedtoolcache; \
        ln -sfn /var/lib/act/actions/tool_cache /opt/hostedtoolcache; \
    fi; \
    git config --system init.defaultBranch main; \
    git config --system advice.detachedHead false

# -----------------------------------------------------------------------------
# 构建期脚本
#
# chmod 不依赖源文件的可执行位（从 Windows 检出或归档解压后 mode 可能丢失）。
# sh -n 是语法门禁，脚本写错在构建期失败，而不是等到容器里执行时。
# actrc 软链成 /etc/act/actrc 与 /root/.actrc 两份。
# -----------------------------------------------------------------------------
COPY files/ /usr/local/lib/act-jenkins-agent/

RUN set -eux; \
    cd /usr/local/lib/act-jenkins-agent; \
    chmod 0755 ./*.sh; \
    chmod 0644 ./actrc; \
    for f in ./*.sh; do sh -n "${f}"; done; \
    ln -sfn /usr/local/lib/act-jenkins-agent/actrc-entrypoint.sh \
            /usr/local/bin/actrc-entrypoint.sh; \
    ln -sfn /usr/local/lib/act-jenkins-agent/actrc /etc/act/actrc; \
    ln -sfn /etc/act/actrc /root/.actrc

# 基础镜像自带的 Node，版本不固定，只补 PATH 软链。
# TARGETARCH 由 buildx 注入，本地 docker build 时为空，脚本内回退 uname -m。
ARG TARGETARCH
RUN /usr/local/lib/act-jenkins-agent/link-node.sh

# act 本体。改 ACT_VERSION 只重建这一层及其后的 actrc 门禁层。
ARG ACT_VERSION=0.2.94
RUN /usr/local/lib/act-jenkins-agent/install-act.sh

# actrc 门禁：只要有一行非法（未知 flag、--pull=maybe 这类非法取值）构建即失败。
# 要覆盖默认配置在运行期挂载：-v /srv/act/actrc:/root/.actrc:ro
RUN set -eux; \
    cat /etc/act/actrc; \
    HOME=/root act --version

# runner 布局按 root 组织，Jenkins checkout 与 act 写出的文件不会出现 uid 冲突。
# 以非 root 运行请用 --user <uid>:<gid>，并把挂载目录属主改成该 uid。
USER root

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/actrc-entrypoint.sh"]
CMD ["sleep", "infinity"]

ARG BASE_IMAGE
LABEL org.opencontainers.image.title="act-jenkins-agent" \
      org.opencontainers.image.description="Jenkins agent running GitHub Actions workflows locally via nektos/act (-self-hosted)" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      act.version="${ACT_VERSION}"
