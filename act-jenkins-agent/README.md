# act-jenkins-agent

Jenkins agent 镜像：容器本身就是"GitHub 托管 runner 的等价环境"，act 以 `-self-hosted`
模式在容器内就地执行仓库里的 `.github/workflows/*.yml`，不依赖 GitHub 服务端，也不嵌套 Docker。

镜像内包含 act 二进制，以及基础镜像自带的 Node.js、Python、git-lfs、yq、docker CLI 等工具。
基础镜像固定为 `ghcr.io/catthehacker/ubuntu:act-24.04`（act 官方推荐的运行环境）。

## 镜像坐标

镜像由仓库根 `.github/workflows/release.yml` 扫描 `**/Dockerfile` 自动发布：

```text
ghcr.io/<REGISTRY_OWNER>/act-jenkins-agent:<version>
ghcr.io/<REGISTRY_OWNER>/act-jenkins-agent:latest
```

Git tag 前缀为 `act-jenkins-agent/v`，与镜像版本一一对应。

构建参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `BASE_IMAGE` | `ghcr.io/catthehacker/ubuntu:act-24.04` | 固定版本，避免上游切换 latest 导致环境漂移 |
| `ACT_VERSION` | `0.2.94` | act 发布版本，构建时校验 sha256 |

act 的运行参数不暴露成构建参数，全部是 `files/actrc` 里的固定默认值，原样 COPY 成
`/etc/act/actrc`。要改行为就改那个文件后重建镜像，或运行期挂载覆盖。

## 必须挂载的持久卷

act 的三类数据默认写在容器内，容器重建即丢失。不挂载会导致：每次构建重新下载 action
和 toolchain、`actions/cache` 命中率归零、上一次的产物无法复查。

| 容器内路径 | 用途 | 对应 act 参数 | 建议容量 |
| --- | --- | --- | --- |
| `/var/lib/act/actions` | 远程 action 的本地副本 + tool cache（Node/Python/Go 等） | `--action-cache-path` | 1–5 GiB |
| `/var/lib/act/cache` | `actions/cache` 的缓存服务存储 | `--cache-server-path` | 1–10 GiB |
| `/var/lib/act/artifacts` | `actions/upload-artifact` 落盘产物 | `--artifact-server-path` | 按产物大小，无自动清理 |

宿主机建议路径（三者必须是不同目录，不要互相嵌套）：

```text
/srv/act/actions      ->  /var/lib/act/actions
/srv/act/cache        ->  /var/lib/act/cache
/srv/act/artifacts    ->  /var/lib/act/artifacts
```

挂载注意事项：

- **不要挂载 `/opt/hostedtoolcache`**。镜像内该路径是指向 `/var/lib/act/actions/tool_cache`
  的软链，单独挂载空目录会把软链遮掉，导致 `setup-*` 与容器模式的 tool cache 分裂成两份。
- **不要以只读方式挂载**。act 需要写入缓存与产物，只读挂载会在 `actions/cache` 的
  reserve/commit 阶段报错。
- 镜像内三个目录已 `chmod 0777`。容器默认以 root 运行，bind mount 的宿主目录无需额外改权限；
  若用 `--user <uid>:<gid>` 以非 root 运行，需要先在宿主上把对应目录属主改成该 uid。
- 宿主机目录首次需自行创建：`mkdir -p /srv/act/{actions,cache,artifacts}`。
- 在 Kubernetes 里，多个 agent 共享缓存需要 `ReadWriteMany` 的 PVC（NFS/CephFS 等）；
  若只能用 `ReadWriteOnce`，就按 agent 各给一个 PVC，缓存不共享但每份仍然持久。

## 运行方式

### docker run

```bash
mkdir -p /srv/act/{actions,cache,artifacts}

docker run -d --name jenkins-agent-1 \
  -v /srv/act/actions:/var/lib/act/actions \
  -v /srv/act/cache:/var/lib/act/cache \
  -v /srv/act/artifacts:/var/lib/act/artifacts \
  -e JAVA_OPTS="-Xmx1g" \
  ghcr.io/<owner>/act-jenkins-agent:latest
```

`ENTRYPOINT` 是 `tini -- /usr/local/bin/actrc-entrypoint.sh`，入口脚本只做一件事：当前用户的
`$HOME/.actrc` 不存在时从 `/etc/act/actrc` 复制一份（`/root/.actrc` 已是软链，这一步只对
`--user <uid>` 运行的场景有意义；已存在则不覆盖，因此可以挂载自定义 actrc），之后 `exec "$@"`
交给 CMD。Jenkins 侧不需要预置逻辑，`remoting.jar` 由插件注入。

### docker compose

```yaml
services:
  agent:
    image: ghcr.io/<owner>/act-jenkins-agent:latest
    container_name: jenkins-agent-1
    restart: unless-stopped
    volumes:
      - /srv/act/actions:/var/lib/act/actions
      - /srv/act/cache:/var/lib/act/cache
      - /srv/act/artifacts:/var/lib/act/artifacts
      # 自托管 action 源或离线开关走覆盖 actrc，见对应章节
      # - /srv/act/actrc:/root/.actrc:ro
    environment:
      JAVA_OPTS: "-Xmx1g"
```

## 执行 workflow

Jenkins 之外的排查手段，也是首次预热的方式：把仓库挂到 `/workspace` 后直接调 act。

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /srv/act/actions:/var/lib/act/actions \
  -v /srv/act/cache:/var/lib/act/cache \
  -v /srv/act/artifacts:/var/lib/act/artifacts \
  ghcr.io/<owner>/act-jenkins-agent:latest \
  bash -lc 'cd /workspace && act push -W .github/workflows/ci.yml'
```

平台映射（`-P ubuntu-latest=-self-hosted`）、三个 `--*-path`、`--concurrent-jobs`、`--pull`
全部来自内置 actrc，不必重复传；命令行参数会覆盖 actrc。模拟 PR 时加 `-e event.json`
（payload 形状与 GitHub 一致）。

### 离线运行

首次运行需要联网，把 action 与 toolchain 落到持久卷。之后让 actrc 带上 `--action-offline-mode`
即可不再访问远程 action 仓库，两种做法选一种：

- 改 `files/actrc`（取消 `#--action-offline-mode` 的注释）后重建镜像；
- 不动镜像，挂一份自定义 actrc 到 `/root/.actrc`。

注意 `setup-node` / `setup-python` 的版本清单本身仍来自 GitHub，无外网时需要预先填好
tool cache，或改用 `full-*` 基础镜像。

## 内置 act 配置

`files/actrc` 原样 COPY 成 `/etc/act/actrc`，并软链到 `/root/.actrc`。内容：

```text
-P ubuntu-latest=-self-hosted
-P ubuntu-22.04=-self-hosted
-P ubuntu-24.04=-self-hosted
--cache-server-path /var/lib/act/cache
--artifact-server-path /var/lib/act/artifacts
--action-cache-path /var/lib/act/actions
--concurrent-jobs 1
--pull=false
```

act 的读取顺序是 `$XDG_CONFIG_HOME/act/actrc` → `~/.actrc` → 仓库内 `./.actrc`，后读覆盖先读，
命令行再覆盖全部。要点：

- 仓库自带的 `./.actrc` **改不掉**上面这些：`-P ...=-self-hosted`、`--action-cache-path`
  等触及宿主资源的 flag 在项目级文件里会被忽略并告警，只有命令行加 `--trust-project-actrc`
  才生效。
- 覆盖内置配置不需要重建镜像：`-v /srv/act/actrc:/root/.actrc:ro`。
- 构建期有门禁：actrc 落位后立即执行 `HOME=/root act --version`，非法 flag 或非法取值
  （例如 `--pull=maybe`）会让构建失败。
- 路径都是字面量，镜像里没有对应的环境变量。改缓存路径要同时改 `files/actrc` 与
  Dockerfile 创建目录那一层，以及本文的挂载表。

## 自托管 action 源（Gitea / GHES）

act 没有 `DEFAULT_ACTIONS_URL`，等价手段是把"GitHub 实例地址"整体换掉。github context 由 act
自己计算，容器环境里的 `GITHUB_SERVER_URL` 不生效，必须走 `--env` 写进 actrc：

```bash
# 方式一：改 files/actrc（取消末尾两行 --env 的注释并填地址）后重建镜像

# 方式二：不动镜像，运行期挂一份覆盖的 actrc
printf -- '--env GITHUB_SERVER_URL=https://gitea.example.com\n--env GITHUB_API_URL=https://gitea.example.com/api/v3\n' \
  > /srv/act/actrc
docker run ... -v /srv/act/actrc:/root/.actrc:ro ghcr.io/<owner>/act-jenkins-agent:latest
```

挂载覆盖是整份替换：自定义 actrc 里要同时保留 `-P` 与 `--*-path` 等默认行，否则 act 会退回
默认行为（容器模式、缓存写容器内）。

这样 `uses: actions/checkout@v4` 会被 clone 成 `https://gitea.example.com/actions/checkout`，
github context 里的 server/repo 也随之改变。前提是用到的 action 仓库已按相同 `owner/repo`
路径镜像到自托管实例，并保留 `@v4` 这类 tag。单独替换个别仓库时用
`--local-repository actions/checkout@v4=/opt/actions/checkout`（路径需自行挂进容器）。

## 已知限制

- **没有 Docker daemon**。纯 shell 步骤与标准 action 不受影响；workflow 出现 `services:`、
  `container:`、`uses: docker://...`、`runs: using: docker` 时会失败。这类 workflow 需要
  额外挂宿主 docker socket（`-v /var/run/docker.sock:/var/run/docker.sock`）并把 act 的
  `-P` 改为容器映射（去掉 `=-self-hosted`）。
- **host 模式没有 job 间隔离**。所有 job 共用容器文件系统与 HOME，所以 `--concurrent-jobs`
  保持 1，一个 agent 容器只跑一个 build；并发构建请起多个 agent 容器。
- **`GITHUB_TOKEN` 不会自动签发**。需要调 GitHub/Gitea API 的步骤（release、`gh api`、
  `github-script`）必须通过 `--secret-file` 或 `-s GITHUB_TOKEN=...` 传入；纯构建流程可以不给。
- **只跑 Linux job**。`runs-on: windows-*` / `macos-*` 在本镜像内不可用。
- **产物目录不会自动回收**。`/var/lib/act/artifacts` 会随运行次数增长，需要外部清理：

```bash
find /srv/act/artifacts -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} +
```
