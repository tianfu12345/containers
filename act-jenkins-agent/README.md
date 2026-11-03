# act-jenkins-agent

Jenkins agent 镜像：容器本身就是"GitHub 托管 runner 的等价环境"，act 以 `-self-hosted`
模式在容器内就地执行仓库里的 `.github/workflows/*.yml`，不依赖 GitHub 服务端，也不嵌套 Docker。

镜像内已包含 act 二进制、Node.js、Python、git-lfs、yq、docker CLI 等常用工具，
基础镜像固定为 `ghcr.io/catthehacker/ubuntu:act-24.04`（act 官方推荐的运行环境）。

## 镜像坐标

镜像由仓库根 `.github/workflows/release.yml` 扫描 `**/Dockerfile` 自动发布：

```text
ghcr.io/<REGISTRY_OWNER>/act-jenkins-agent:<version>
ghcr.io/<REGISTRY_OWNER>/act-jenkins-agent:latest
```

Git tag 前缀为 `act-jenkins-agent/v`，与镜像版本一一对应。

构建参数（一般不需要改）：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `BASE_IMAGE` | `ghcr.io/catthehacker/ubuntu:act-24.04` | 固定版本，避免上游切换 latest 导致环境漂移 |
| `ACT_VERSION` | `0.2.94` | act 发布版本，构建时校验 sha256 |
| `TZ` | `Etc/UTC` | 容器时区 |

## 必须挂载的持久卷

这是本镜像最关键的部分。act 的三类数据默认写在容器内，容器重建即丢失；不挂载会导致：
每次构建重新下载 action 和 toolchain、`actions/cache` 命中率归零、上一次的产物无法复查。

| 容器内路径 | 用途 | 对应 act 参数 | 建议容量（按 workflow 规模估算） |
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
- **不要以只读方式挂载**。act 需要写入缓存与产物；只读挂载会在 `actions/cache` 的
  reserve/commit 阶段报错。
- 镜像内三个目录已 `chmod 0777`。容器默认以 root 运行，bind mount 的宿主目录无需额外改权限；
  若用 `--user <uid>:<gid>` 以非 root 运行，需要先在宿主上把对应目录的属主改成该 uid。
- 宿主机目录首次需要自行创建：`mkdir -p /srv/act/{actions,cache,artifacts}`。
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

容器 `ENTRYPOINT` 是 tini，默认 `CMD sleep infinity`，作为 Jenkins agent 由插件注入
`remoting.jar` 后启动，不需要在本镜像里预置 Jenkins 相关逻辑。

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
    environment:
      GITHUB_SERVER_URL: https://gitea.example.com   # 见"自托管 action 源"
```

### 手动在容器内跑一次 workflow

Jenkins 之外的排查手段：把仓库挂在 `/workspace` 后直接调 act。

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /srv/act/actions:/var/lib/act/actions \
  -v /srv/act/cache:/var/lib/act/cache \
  -v /srv/act/artifacts:/var/lib/act/artifacts \
  -e GITHUB_SERVER_URL=https://github.com \
  ghcr.io/<owner>/act-jenkins-agent:latest \
  bash -lc '
    cd /workspace &&
    act push \
      -W .github/workflows/ci.yml \
      -P ubuntu-latest=-self-hosted \
      -P ubuntu-24.04=-self-hosted \
      --action-cache-path "$ACT_ACTION_CACHE_DIR" \
      --cache-server-path  "$ACT_CACHE_DIR" \
      --artifact-server-path "$ACT_ARTIFACT_DIR"
  '
```

`ACT_ACTION_CACHE_DIR` / `ACT_CACHE_DIR` / `ACT_ARTIFACT_DIR` 是镜像预置的环境变量，
**act 本身不读取它们**，只是为了少写路径；命令行里仍然必须显式传给 act。
若要跑非默认 workflow 或模拟 PR，加上 `-e event.json`（payload 形状要与 GitHub 一致）。

## 首次预热与离线运行

```bash
# 1) 第一次：联网跑一遍目标 workflow，把 action 与 toolchain 落到持久卷
#    （容器需能看到仓库，这里把当前目录挂到 /workspace）
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /srv/act/actions:/var/lib/act/actions \
  -v /srv/act/cache:/var/lib/act/cache \
  -v /srv/act/artifacts:/var/lib/act/artifacts \
  ghcr.io/<owner>/act-jenkins-agent:latest \
  bash -lc 'cd /workspace && act push -P ubuntu-latest=-self-hosted \
    --action-cache-path /var/lib/act/actions --cache-server-path /var/lib/act/cache \
    --artifact-server-path /var/lib/act/artifacts'

# 2) 之后：加 --action-offline-mode，不再访问远程 action 仓库
#    注意 setup-node / setup-python 的版本清单本身仍来自 GitHub，
#    无外网时需要预先填好 tool cache，或改用 full-* 基础镜像。
```

## 自托管 action 源（Gitea / GHES）

act 没有 `DEFAULT_ACTIONS_URL`，等价手段是把"GitHub 实例地址"整体换掉：

```bash
docker run ... \
  -e GITHUB_SERVER_URL=https://gitea.example.com \
  -e GITHUB_API_URL=https://gitea.example.com/api/v3 \
  ghcr.io/<owner>/act-jenkins-agent:latest
```

这样 `uses: actions/checkout@v4` 会被 clone 成
`https://gitea.example.com/actions/checkout`，同时 github context 里的 server/repo 也跟着变。
前提是用到的 action 仓库已按相同 `owner/repo` 路径镜像到自托管实例，并保留 `@v4` 这类 tag。
单独替换个别仓库时用 `--local-repository actions/checkout@v4=/opt/actions/checkout`
（路径需自行挂进容器）。

## 已知限制

- **没有 Docker daemon**。纯 shell 步骤与标准 action 不受影响；workflow 出现 `services:`、
  `container:`、`uses: docker://...`、`runs: using: docker` 时会失败。这类 workflow 需要
  额外挂宿主 docker socket（`-v /var/run/docker.sock:/var/run/docker.sock`）并把 act 的
  `-P` 改为容器映射（去掉 `=-self-hosted`）。
- **host 模式没有 job 间隔离**。所有 job 共用容器文件系统与 HOME，所以 `--concurrent-jobs`
  应保持 1，且一个 agent 容器只跑一个 build；并发构建请起多个 agent 容器。
- **`GITHUB_TOKEN` 不会自动签发**。需要调 GitHub/Gitea API 的步骤（release、`gh api`、
  `github-script`）必须通过 `--secret-file` 或 `-s GITHUB_TOKEN=...` 传入；纯构建流程可以不给。
- **只跑 Linux job**。`runs-on: windows-*` / `macos-*` 在本镜像内不可用。
- **产物目录不会自动回收**。`/var/lib/act/artifacts` 会随运行次数增长，需要外部清理，例如：

```bash
find /srv/act/artifacts -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} +
```
