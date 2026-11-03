#!/bin/sh
# install-act.sh — 下载、校验并安装 act 二进制
#
# 由 Dockerfile 在构建期调用：
#   ACT_VERSION=0.2.94 ./install-act.sh
#
# 环境变量：
#   ACT_VERSION  必填，act 发布版本（不带 v 前缀）
#   TARGETARCH   buildx 注入；本地构建时为空，回退 uname -m
#   DEST_DIR     安装目录，默认 /usr/local/bin

set -eu

: "${ACT_VERSION:?ACT_VERSION must be set}"

dest_dir=${DEST_DIR:-/usr/local/bin}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/act-install.XXXXXX")
trap 'rm -rf "${tmp_dir}"' EXIT HUP INT TERM

case "${TARGETARCH:-$(uname -m)}" in
    amd64|x86_64)  act_triple=Linux_x86_64 ;;
    arm64|aarch64) act_triple=Linux_arm64 ;;
    *)
        echo "install-act: unsupported architecture: ${TARGETARCH:-$(uname -m)}" >&2
        exit 1
        ;;
esac

base="https://github.com/nektos/act/releases/download/v${ACT_VERSION}"
asset="act_${act_triple}.tar.gz"

cd "${tmp_dir}"
curl -fsSLO "${base}/${asset}"
curl -fsSL -o checksums.txt "${base}/checksums.txt"

# checksums.txt 里查不到该文件时，sha256sum 读到空输入即失败
awk -v f="${asset}" '$2 == f' checksums.txt | sha256sum -c -

tar -xzf "${asset}" act
install -m 0755 act "${dest_dir}/act"

"${dest_dir}/act" --version
echo "install-act: ${ACT_VERSION} (${act_triple}) -> ${dest_dir}/act"
