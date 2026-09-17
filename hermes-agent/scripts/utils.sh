#!/bin/bash
set -euo pipefail

# ====================================================
# 通用函数库 — 可 source 供应商也可作为脚本直接执行
# 作为脚本执行: /path/to/utils.sh <函数名> <参数...>
# ====================================================

# 输出函数
log_info()    { echo "ℹ️ $1" >&2; }
log_success() { echo "✅ $1" >&2; }
log_warning() { echo "⚠️ $1" >&2; }
log_error()   { echo "❌ $1" >&2; }
log_progress(){ echo "⏳ $1" >&2; }
log_step()    { echo "🚀 $1" >&2; }
log_done()    { echo "🎉 $1" >&2; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo "🔍 DEBUG: $1" >&2; }

# 检查是否以root身份执行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo "$0" "$@"
        else
            log_error "未找到 sudo 命令，请手动以 root 身份运行此脚本。"
            exit 1
        fi
    fi
}

# 执行apt安装
apt_install() {
    local to_install=()
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log_success "所有软件包 ($*) 均已安装，跳过。"
    else
        log_progress "开始安装: ${to_install[*]}..."
        apt-get update -qq
        apt-get install --no-install-recommends -y "${to_install[@]}"
        log_success "安装完成： ${to_install[*]}"
    fi
}

# 判断是否为容器
is_container() {
    # 检查是否存在 /.dockerenv 文件
    if [ -f /.dockerenv ]; then
        return 0
    fi
    # 检查 /proc/1/cgroup 是否包含容器关键字
    if [ -f /proc/1/cgroup ] && grep -qiE "docker|kubepods|containerd|lxc" /proc/1/cgroup; then
        return 0
    fi
    # 检查 /proc/1/sched 中的进程名（部分容器1号进程不是 systemd/init）
    # 如果1号进程是普通的业务进程，大概率是容器
    if [ -f /proc/1/sched ]; then
        local init_name=$(head -n 1 /proc/1/sched | awk '{print $1}')
        if [[ "$init_name" != "systemd" && "$init_name" != "init" ]]; then
            # 排除一些常见的宿主机 init 变体，如果不确定可以不启用此条
            return 0
        fi
    fi
    return 1
}

# ==========================================
# 通用下载函数
# - download_binary: 直接下载二进制文件
# - download_tarball: 下载 tar.gz 归档并提取
# - run_install_script: 执行远程安装脚本
# - download_zip: 下载并解压 zip 归档
# - download_github_binary: 从 GitHub Release 下载二进制
# - download_github_tarball: 从 GitHub Release 下载 tar.gz
#
# 依赖调用方开启 set -euo pipefail（见 00_base.sh / 01_install.sh）
# 本函数库不主动设置，避免覆盖调用方的错误处理策略
# ==========================================


# 直接下载二进制文件并赋予可执行权限
# 用法: download_binary <url> <output_path>
#   url         - 下载地址
#   output_path - 输出文件路径（相对或绝对路径）
# 行为: curl -fL <url> -o <output_path> && chmod +x
# 注意: -f 保证 HTTP 非 200 时立即失败；-L 跟随重定向
download_binary() {
    local url="$1"
    local output_path="$2"
    log_progress "正在下载二进制文件: $(basename "$output_path")"
    curl -fL "$url" -o "$output_path"
    chmod +x "$output_path"
    log_success "二进制文件下载完成: $output_path"
}

# 下载 tar.gz/tgz 归档并提取指定文件或目录
# 用法: download_tarball <url> <output_dir> [extract_path]
#   url          - 归档下载地址
#   output_dir   - 提取目标目录
#   extract_path - 归档内要提取的路径（可选；不传则提取全部）
#                  以 / 结尾 → 视为目录，内容直接落到 output_dir 下
#                  不以 / 结尾 → 视为文件，剥离父目录层级后直接落在 output_dir 下
# 说明: 按 extract_path 层级自动计算 --strip-components；文件模式额外 chmod +x
download_tarball() {
    local url="$1"
    local output_dir="$2"
    local extract_path="${3:-}"
    mkdir -p "$output_dir"
    if [[ -n "$extract_path" ]]; then
        # 计算需要剥离的目录层级
        local strip_count
        strip_count=$(echo "$extract_path" | tr '/' '\n' | wc -l)
        ((strip_count--))

        if [[ "$extract_path" == */ ]]; then
            # 提取目录：剥离层级，目录内容直接落到 output_dir
            log_progress "正在下载并提取目录: $extract_path (剥离 $strip_count 层)"
            curl -fL "$url" | tar -xz -C "$output_dir" --strip-components="$strip_count" "$extract_path"
        else
            # 提取文件：剥离父目录层级，文件直接落到 output_dir
            log_progress "正在下载并提取文件: $(basename "$extract_path") (剥离 $strip_count 层)"
            curl -fL "$url" | tar -xz -C "$output_dir" --strip-components="$strip_count" "$extract_path"
            chmod +x "${output_dir}/$(basename "$extract_path")"
        fi
    else
        log_progress "正在下载并提取归档到: $output_dir"
        curl -fL "$url" | tar -xz -C "$output_dir"
    fi
    log_success "归档提取完成: $output_dir"
}

# 执行远程安装脚本
# 用法: run_install_script <url> [args...]
#   url  - 安装脚本地址
#   args - 传递给安装脚本的参数（可选，直接透传）
run_install_script() {
    local url="$1"
    shift
    local tmp_script="/tmp/install_$$.sh"
    log_progress "正在下载并执行安装脚本: $url"
    curl -fL "$url" -o "$tmp_script"
    bash "$tmp_script" "$@"
    rm -f "$tmp_script"
    log_success "安装脚本执行完成"
}

# 下载并解压 zip 归档
# 用法: download_zip <url> <output_dir> [zip_filename]
#   url          - 归档下载地址
#   output_dir   - 解压目标目录
#   zip_filename - 临时 zip 文件名（可选，默认 _download.zip）
# 说明: 解压后自动清理临时 zip 文件
download_zip() {
    local url="$1"
    local output_dir="$2"
    local zip_filename="${3:-_download.zip}"
    mkdir -p "$output_dir"
    log_progress "正在下载并解压 zip 归档: $output_dir"
    curl -fL "$url" -o "$zip_filename"
    unzip -q "$zip_filename" -d "$output_dir"
    rm -f "$zip_filename"
    log_success "zip 归档解压完成: $output_dir"
}

# 通过 GitHub API 获取仓库最新 Release tag
# 用法: _latest_github_tag <repo>
#   repo - 仓库路径，格式 "owner/repo"（如 "getsops/sops"）
# 依赖: curl, jq
# 注意: 未认证 API 限速 60次/小时，设置 GITHUB_TOKEN 环境变量可提升至 5000
_latest_github_tag() {
    local repo="$1"
    local auth_header=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    local tag
    tag=$(curl -sSfL "${auth_header[@]}" "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "无法获取 $repo 的最新 Release tag（可能无 Release 或 API 限速）"
        exit 1
    fi
    echo "$tag"
}

# 通过 GitHub API 查询 Release 资产下载地址
# 用法: _github_release_asset_url <repo> <tag> <pattern>
#   repo    - 仓库路径，格式 "owner/repo"
#   pattern - 资产文件名匹配模式，支持 * 和 ? 通配符（如 "*linux_amd64*"）
# 输出: 匹配资产的 browser_download_url（多匹配时取第一个，并给出警告）
# 依赖: curl, jq
_github_release_asset_url() {
    local repo="$1"
    local tag="$2"
    local pattern="$3"

    local auth_header=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

    # 将 glob 模式转换为 jq test() 可用的正则表达式
    local regex="${pattern//\*/.*}"
    regex="${regex//\?/.}"

    local download_url
    download_url=$(curl -sSfL "${auth_header[@]}" "$api_url" \
        | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url')

    if [[ -z "$download_url" ]]; then
        log_error "未找到匹配 '$pattern' 的资产 (tag: $tag)"
        exit 1
    fi

    local count
    count=$(echo "$download_url" | wc -l)
    if [[ $count -gt 1 ]]; then
        log_warning "匹配到 $count 个资产，将下载第一个: $(echo "$download_url" | head -n 1 | xargs basename)"
    fi

    echo "$download_url" | head -n 1
}

# 从 GitHub Release 下载二进制文件
# 用法: download_github_binary <repo> [tag] <asset_pattern> <output_path>
#   repo          - 仓库路径，格式 "owner/repo"（如 "getsops/sops"）
#   tag           - Release 标签（如 "v3.13.1"），留空则自动获取最新 tag
#   asset_pattern - 资产文件名匹配模式，支持 * 和 ? 通配符（如 "*linux_amd64*"）
# 行为: 通过 GitHub API 查询 Release 资产，用 jq 按模式匹配后下载
download_github_binary() {
    local repo="$1"
    local tag="$2"
    local pattern="$3"
    local output_path="$4"
    if [[ -z "$tag" ]]; then
        tag=$(_latest_github_tag "$repo")
        log_info "自动获取最新 tag: $tag"
    fi
    log_progress "正在查询 $repo 的 Release 资产 (tag: $tag)..."
    local download_url
    download_url=$(_github_release_asset_url "$repo" "$tag" "$pattern")
    if [[ -z "$download_url" ]]; then
        log_error "无法获取匹配 '$pattern' 的资产下载地址 (tag: $tag)"
        exit 1
    fi
    download_binary "$download_url" "$output_path"
}

# 从 GitHub Release 下载 tar.gz/tgz 归档
# 用法: download_github_tarball <repo> [tag] <asset_pattern> <output_dir> [extract_path]
#   repo          - 仓库路径，格式 "owner/repo"
#   tag           - Release 标签（如 "v1.5.5"），留空则自动获取最新 tag
#   asset_pattern - 资产文件名匹配模式，支持 * 和 ? 通配符
# 行为: 通过 GitHub API 查询 Release 资产，用 jq 按模式匹配后下载解压
download_github_tarball() {
    local repo="$1"
    local tag="$2"
    local pattern="$3"
    local output_dir="$4"
    local extract_path="${5:-}"
    if [[ -z "$tag" ]]; then
        tag=$(_latest_github_tag "$repo")
        log_info "自动获取最新 tag: $tag"
    fi
    log_progress "正在查询 $repo 的 Release 资产 (tag: $tag)..."
    local download_url
    download_url=$(_github_release_asset_url "$repo" "$tag" "$pattern")
    if [[ -z "$download_url" ]]; then
        log_error "无法获取匹配 '$pattern' 的资产下载地址 (tag: $tag)"
        exit 1
    fi
    download_tarball "$download_url" "$output_dir" "$extract_path"
}

# ==========================================
# 自执行入口 — 作为脚本直接运行时，将参数作为函数名调用
# 用法: /scripts/utils.sh <函数名> <参数...>
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    "$@"
fi