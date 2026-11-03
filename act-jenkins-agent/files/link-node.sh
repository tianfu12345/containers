#!/bin/sh
# link-node.sh — 把基础镜像自带的 Node.js 软链到 /usr/local/bin
#
# 基础镜像把 node 装在 /opt/acttoolcache/node/<version>/<arch>，版本随基础镜像走，
# 这里不固定版本：取 bin/node 可执行且版本最高的一个。
# 需要软链是因为基础镜像只把 node 路径写进 /etc/environment，而该文件仅由 PAM 登录
# 会话读取；Jenkins 的 sh 步骤是非登录 shell，host 模式下的 act 也依赖 PATH 里的 node。
#
# 环境变量：
#   TARGETARCH   buildx 注入；本地构建时为空，回退 uname -m
#   NODE_ROOT    Node 根目录，默认 /opt/acttoolcache/node
#   LINK_DIR     软链目标目录，默认 /usr/local/bin

set -eu

node_root=${NODE_ROOT:-/opt/acttoolcache/node}
link_dir=${LINK_DIR:-/usr/local/bin}

case "${TARGETARCH:-$(uname -m)}" in
    amd64|x86_64)  node_arch=x64 ;;
    arm64|aarch64) node_arch=arm64 ;;
    *)
        echo "link-node: unsupported architecture: ${TARGETARCH:-$(uname -m)}" >&2
        exit 1
        ;;
esac

root=${node_root}
[ -d "${root}" ] || { echo "link-node: base image provides no ${root}" >&2; exit 1; }

mkdir -p "${link_dir}"

# sort -V 保证 9 < 10 < 24 的版本序
found=''
for dir in $(find "${root}" -mindepth 2 -maxdepth 2 -type d -name "${node_arch}" | sort -V); do
    if [ -x "${dir}/bin/node" ]; then
        found=${dir}
    fi
done

if [ -z "${found}" ]; then
    echo "link-node: no usable node for ${node_arch} under ${root}" >&2
    ls -la "${root}" >&2 || true
    exit 1
fi

for bin in node npm npx corepack; do
    if [ -x "${found}/bin/${bin}" ]; then
        ln -sfn "${found}/bin/${bin}" "${link_dir}/${bin}"
    fi
done

echo "link-node: linked ${found} -> ${link_dir}"
