#!/bin/sh
# actrc-entrypoint.sh — 容器入口，由 tini 调起后交给 CMD
#
# 保证当前用户的 $HOME/.actrc 存在：/root/.actrc 是构建期软链，以 --user <uid> 运行时
# HOME 不是 /root，这里从 /etc/act/actrc 复制一份。已存在则不覆盖，便于挂载自定义 actrc。

set -eu

rc=/etc/act/actrc
home=${HOME:-/root}

if [ ! -f "${home}/.actrc" ] && [ -f "${rc}" ]; then
    mkdir -p "${home}"
    cp -f "${rc}" "${home}/.actrc"
fi

exec "$@"
