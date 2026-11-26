#!/bin/bash
#
# Copyright (c) 2019-2025 seaks <https://github.com/seaks>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/seaks/OpenWrtAction
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# 执行时机：./scripts/feeds update -a 之后、./scripts/feeds install -a 之前
#   ⚠️ 这个顺序是 golang / rust 注入能生效的前提：
#      feeds install -a 会把 feeds/ 下的新内容重新软链到 package/feeds/
#
# ============================================================================
# 可调环境变量（本地编译时用得上）
# ----------------------------------------------------------------------------
#   TARGET_BRANCH     目标分支：master / openwrt-25.12（默认自动探测）
#   RUST_INJECT       1=注入 rust（默认），0=用 ImmortalWrt 自带
#   RUST_REPO         rust 源仓库（默认随分支走 immortalwrt）
#   GOLANG_REPO       golang 源仓库，留空=不替换（默认）
#   GOLANG_BRANCH     golang 分支，需配合 GOLANG_REPO
#   PATCHES_SRC_DIR   OpenWrtAction 仓库本地路径
#   GHFU_GITHUB_TOKEN ghfu token，为空则保留占位符
#
# 示例（编 25.12，全部用官方底座）：
#   RUST_INJECT=0 ./diy_script/immortalwrt_part2.sh
# ============================================================================

set -e

# ---------------------------------------------------------------------------
# 日志函数
# ---------------------------------------------------------------------------
log()  { echo ">>> $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 定位 OpenWrtAction 仓库（放补丁、dl 缓存、library 的那份）
# ---------------------------------------------------------------------------
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="${PATCHES_SRC_DIR:-$GITHUB_WORKSPACE}"
else
    PATCHES_SRC_DIR="${PATCHES_SRC_DIR:-$HOME/OpenWrtAction}"
    [ -d "$PATCHES_SRC_DIR" ] || PATCHES_SRC_DIR="$(cd .. && pwd)/OpenWrtAction"
fi
log "补丁源目录：$PATCHES_SRC_DIR"

# ---------------------------------------------------------------------------
# 探测目标分支（master / openwrt-25.12 / ...）
# ---------------------------------------------------------------------------
if [ -z "${TARGET_BRANCH:-}" ]; then
    if [ -d .git ] && git rev-parse --git-dir > /dev/null 2>&1; then
        TARGET_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    if [ -z "$TARGET_BRANCH" ] || [ "$TARGET_BRANCH" = "HEAD" ]; then
        TARGET_BRANCH="master"
    fi
fi
log "目标分支：$TARGET_BRANCH"

# 非 master 分支一律视为稳定分支（openwrt-25.12、openwrt-24.10 等）
case "$TARGET_BRANCH" in
    master|main) IS_STABLE=0 ;;
    *)           IS_STABLE=1 ;;
esac

# ---------------------------------------------------------------------------
# 清理上一次运行的残留
# ---------------------------------------------------------------------------
rm -rf temp_repo temp_resp clone.log cp.err touch.err dl.err

# ===========================================================================
# 注入函数：从远端仓库稀疏拉取指定目录，覆盖到 feeds 树中
#
# 参数：
#   $1  repo_url   远端仓库
#   $2  feed_dir   feeds 下的目标目录，例如 feeds/packages/lang
#   $3... paths    仓库内的完整路径，例如 lang/rust
#
# ⚠️ paths 必须写「相对仓库根的完整路径」，函数内部会：
#      dest_path    = $feed_dir/$(basename path)
#      symlink_path = package/feeds/<feed名>/<path>   ← 带完整分类路径
#    早期版本用 shift 2 后再 cut -d'/' -f2 推导 feed 名，
#    会把 lang/ 这一级吃掉，导致 package/feeds/packages/rust 这种
#    不存在的路径被清理，真实的软链接残留下来，和覆盖后的真实目录打架。
# ===========================================================================
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    [ "${#paths[@]}" -gt 0 ] || { warn "inject_feed 没有传入路径，跳过：$repo_url"; return 0; }

    log "正在从 $repo_url 拉取至 $feed_dir ..."

    # ⚠️ 不要用 --filter=blob:none：
    #    blobless 克隆下 git log -- <path> 要联网拉 blob，大概率返回空，
    #    导致所有包共用 fallback_time → mtime 失真 → Checkpoint 每次都判定
    #    "Base 有变化"，缓存白推。浅克隆的 blob 都在本地，git log 纯本地，时间戳准确。
    # ⚠️ 失败不中断：set -e 下 clone 失败会直接退出整个 job，
    #    后面的 feeds install / defconfig / 编译全都不执行。这里兜底跳过。
    if ! git clone --sparse --depth=1 "$repo_url" temp_repo > clone.log 2>&1; then
        warn "clone 失败，跳过：$repo_url"
        tail -5 clone.log 2>/dev/null || true
        rm -rf temp_repo clone.log
        return 0
    fi

    # 稀疏检出，只拉需要的目录；子 shell 隔离 cd，失败也不污染后续路径
    if ! (cd temp_repo && git sparse-checkout set --no-cone "${paths[@]}" > /dev/null 2>&1); then
        warn "sparse-checkout 失败，跳过：$repo_url"
        rm -rf temp_repo clone.log
        return 0
    fi

    # 上游最新 Commit 时间戳（仅作兜底）
    local fallback_time
    fallback_time=$(cd temp_repo && git log -1 --format=%cd --date=unix 2>/dev/null || date +%s)

    local p pkg_name dest_path symlink_path feed_name sub_path file_time
    for p in "${paths[@]}"; do
        if [ ! -d "temp_repo/$p" ]; then
            warn "路径不存在，跳过：$p"
            continue
        fi

        pkg_name="$(basename "$p")"
        dest_path="$feed_dir/$pkg_name"

        # feed 名：feeds/packages/lang -> packages
        feed_name="$(printf '%s' "$feed_dir" | sed -n 's|^\([./]*\)feeds/\([^/]*\).*$|\2|p')"
        # feeds 下的子路径：feeds/packages/lang -> packages/lang
        sub_path="$(printf '%s' "$feed_dir" | sed -n 's|^\([./]*\)feeds/||p')"

        # 1. 清理 OpenWrt 软链接，防止文件类型冲突
        if [ -n "$feed_name" ]; then
            if [ -n "$sub_path" ]; then
                symlink_path="package/feeds/$sub_path/$pkg_name"
            else
                symlink_path="package/feeds/$feed_name/$pkg_name"
            fi
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
                log "  已清理旧链接：$symlink_path"
            fi
        else
            warn "无法从 '$feed_dir' 推导 feed 名，跳过软链接清理"
        fi

        # 2. 清理并覆盖目标目录
        rm -rf "$dest_path"
        if ! cp -r "temp_repo/$p" "$dest_path" 2> cp.err; then
            warn "cp 失败，跳过：$p"
            tail -3 cp.err 2>/dev/null || true
            rm -f cp.err
            continue
        fi

        # 3. 提取真实时间戳，失败则用兜底，欺骗编译缓存
        file_time="$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null || true)"
        if [ -z "$file_time" ]; then
            file_time="$fallback_time"
            log "  $p 取不到独立时间戳，使用兜底值"
        fi
        # 只 touch 文件，不动目录：目录 mtime 变化会放大 make 的重扫范围
        if ! find "$dest_path" -type f -exec touch -m -d @"$file_time" {} + 2> touch.err; then
            warn "touch 失败（不影响编译）：$p"
            tail -3 touch.err 2>/dev/null || true
        fi
        rm -f touch.err cp.err

        ok "已注入并伪装时间戳：$pkg_name -> $dest_path (@$file_time)"
    done

    rm -rf temp_repo clone.log
}

# ===========================================================================
# 执行注入任务
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. rust
#    ⚠️ 源必须和目标分支同源：
#       - master      用 openwrt/packages（主线）或 immortalwrt/packages
#       - 稳定分支    用 immortalwrt/packages，主线 rust 版本会漂，
#                     和分支自带的 rust-bindgen 等配套件错开
#    设 RUST_INJECT=0 可完全跳过，直接用 ImmortalWrt 自带的 rust。
# ---------------------------------------------------------------------------
RUST_INJECT="${RUST_INJECT:-1}"

if [ "$RUST_INJECT" = "1" ]; then
    if [ -n "${RUST_REPO:-}" ]; then
        :
    elif [ "$IS_STABLE" = "1" ]; then
        RUST_REPO="https://github.com/immortalwrt/packages.git"
    else
        RUST_REPO="https://github.com/openwrt/packages.git"
    fi

    log "注入 rust（源：$RUST_REPO）"
    inject_feed "$RUST_REPO" "feeds/packages/lang" "lang/rust"
else
    log "RUST_INJECT=0，跳过 rust 注入，使用 ImmortalWrt 自带版本"
fi

# ---------------------------------------------------------------------------
# 2. golang
#    ⚠️ ImmortalWrt 25.12 的 lang/golang 已经是新版结构：
#       golang-bootstrap + golang-version.mk + golang1.26/golang1.27/...
#       默认 Go 版本由 golang-values.mk 的 GO_DEFAULT_VERSION 决定（25.12 为 1.26），
#       golang/host 这个 dummy 包会把依赖转到默认版本，各 Go 包无需改依赖名。
#    ⚠️ 所以稳定分支默认【不替换】，直接沿用官方配套版本最稳。
#    确实要换（比如 master 想固定到某个大版本）时这样开：
#       GOLANG_REPO=https://github.com/sbwml/packages_lang_golang \
#       GOLANG_BRANCH=27.x \
#       ./diy_script/immortalwrt_part2.sh
# ---------------------------------------------------------------------------
if [ -n "${GOLANG_REPO:-}" ]; then
    GOLANG_BRANCH="${GOLANG_BRANCH:-master}"
    log "替换 golang：$GOLANG_REPO (分支 $GOLANG_BRANCH)"

    rm -rf feeds/packages/lang/golang
    if git clone --depth 1 "$GOLANG_REPO" -b "$GOLANG_BRANCH" feeds/packages/lang/golang; then
        ok "golang 替换完成（$GOLANG_BRANCH）"
        grep -E "^GO_DEFAULT_VERSION" feeds/packages/lang/golang/golang-values.mk 2>/dev/null | head -1 || true
    else
        warn "clone golang 失败，尝试恢复官方版本"
        rm -rf feeds/packages/lang/golang
        (./scripts/feeds update -p packages && ./scripts/feeds install golang) || \
            die "golang 恢复失败，请手动执行：./scripts/feeds update -a && ./scripts/feeds install -a"
    fi
else
    log "未设置 GOLANG_REPO，沿用 ImmortalWrt 自带 golang"
    if [ -f feeds/packages/lang/golang/golang-values.mk ]; then
        grep -E "^GO_DEFAULT_VERSION" feeds/packages/lang/golang/golang-values.mk | head -1
    else
        warn "未找到 golang-values.mk，请确认 feeds 已正确拉取"
    fi
fi

# inject_feed "https://github.com/immortalwrt/luci.git" "feeds/luci/modules" \
#     "modules/luci-mod-dashboard"

ok "移植完毕"

#----------------------------------------------------------end 移植包---------

#-----------------------------------------------修改脚本----------------------

# ---------------------------------------------------------------------------
# Modify default IP
# ⚠️ grep -c 无匹配时返回退出码 1，set -e 下必须用 || true 兜住，
#    且不能用 || echo 0（会多输出一行 0，变成 "0\n0"）
# ---------------------------------------------------------------------------
IP_FILE="package/base-files/files/bin/config_generate"
IP_CNT="$(grep -c "192\.168\.1\.1" "$IP_FILE" 2>/dev/null || true)"
IP_CNT="${IP_CNT:-0}"
IP_CNT="${IP_CNT//[[:space:]]/}"

if [ "$IP_CNT" -gt 0 ] 2>/dev/null; then
    sed -i 's/192\.168\.1\.1/192.168.101.1/g' "$IP_FILE"
    ok "默认 IP 已改为 192.168.101.1（替换 $IP_CNT 处）"
else
    warn "$IP_FILE 中未找到 192.168.1.1，跳过 IP 修改"
fi

# ---------------------------------------------------------------------------
# 修复 netspeedtest 依赖
#
# 问题：sirpdboy/netspeedtest 的 Makefile 按主线 OpenWrt 写依赖，声明了
#       python3-email 与 python3-pkg-resources 两个子包：
#         - python3-email         主线定义在 lang/python/python3/files/python3-package-email.mk
#         - python3-pkg-resources 主线定义在 lang/python/python-setuptools/Makefile
#       但 ImmortalWrt 的 feeds/packages/lang/python 没有拆分这两个包，
#       apk 装 rootfs 时会报 "no such package"，导致 package/install Error 4。
# 处理：从 LUCI_DEPENDS 里删掉这两项。email 模块随 python3-light 的标准库一起
#       装进设备，import email 不受影响；pkg_resources 只有脚本用到 setuptools 时才需要。
# 位置：必须在 feeds install -a 之前改，这样生成的 .packageinfo 才是正确的。
# ---------------------------------------------------------------------------
NETSPEEDTEST_MK="feeds/netspeedtest/luci-app-netspeedtest/Makefile"
if [ -f "$NETSPEEDTEST_MK" ]; then
    sed \
        -e 's/ +python3-pkg-resources//g' \
        -e 's/ +python3-email//g' \
        -e 's/^[[:space:]]*python3-pkg-resources[[:space:]]*\\\{0,1\}//g' \
        -e 's/^[[:space:]]*python3-email[[:space:]]*\\\{0,1\}//g' \
        "$NETSPEEDTEST_MK" > "$NETSPEEDTEST_MK.new" \
        && mv "$NETSPEEDTEST_MK.new" "$NETSPEEDTEST_MK" \
        || { warn "sed 修改失败，保留原文件"; rm -f "$NETSPEEDTEST_MK.new"; }

    if grep -q "python3-email\|python3-pkg-resources" "$NETSPEEDTEST_MK"; then
        warn "仍有残留，请手动检查：$NETSPEEDTEST_MK"
        grep -n "python3-email\|python3-pkg-resources" "$NETSPEEDTEST_MK" || true
    else
        ok "netspeedtest 依赖已修正（已无 python3-email / python3-pkg-resources）"
    fi
else
    warn "未找到 $NETSPEEDTEST_MK，跳过（feed 可能改名或尚未拉取）"
fi

# ---------------------------------------------------------------------------
# inject download package（目录不存在或为空都不中断）
# ---------------------------------------------------------------------------
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    LIB_CNT="$(find "$PATCHES_SRC_DIR/library" -type f 2>/dev/null | wc -l)"
    if [ "${LIB_CNT:-0}" -gt 0 ]; then
        if cp -r "$PATCHES_SRC_DIR/library/." ./dl/ 2> dl.err; then
            ok "已复制 library -> dl/（$LIB_CNT 个文件）"
        else
            warn "复制 library 时出错，继续编译"
            tail -3 dl.err 2>/dev/null || true
        fi
        rm -f dl.err
    else
        log "library 目录为空，跳过"
    fi
else
    log "未找到 $PATCHES_SRC_DIR/library，跳过"
fi

# ---------------------------------------------------------------------------
# Modify SSH Configuration (Dropbear -> 2222, OpenSSH -> 22)
# ---------------------------------------------------------------------------
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-custom-ssh-config
#!/bin/sh

# --- 1. 停止服务 ---
/etc/init.d/dropbear stop
/etc/init.d/sshd stop 2>/dev/null

# --- 2. 配置 Dropbear (UCI) ---
uci set dropbear.@dropbear[0].Port='2222'
uci commit dropbear

# --- 3. 配置 OpenSSH (sshd_config) ---
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sed -i 's/^#*Port.*/Port 22/' "$SSHD_CONFIG"
fi

# --- 4. 按顺序启动，避免端口抢占 ---
/etc/init.d/dropbear start
/etc/init.d/sshd enable
/etc/init.d/sshd start

exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-ssh-config
log "已写入 files/etc/uci-defaults/99-custom-ssh-config"

# --- End Modify SSH Configuration ---

# ==========================================================================
# GHFU 插件 token 注入：perl 安全替换
# 本地 / fork PR 场景没有 Secrets，token 为空时保留占位符，不注入
# ==========================================================================
GHFU_FILE="$(find . -path "*/luci-app-ghfu/*.lua" -exec grep -l '__GHFU_GITHUB_TOKEN__' {} + 2>/dev/null | head -n1)"

if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    log "找到 ghfu 模板文件：$GHFU_FILE"
    log "注入 GHFU_GITHUB_TOKEN（长度 ${#GHFU_GITHUB_TOKEN}）"
    perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
else
    if [ -z "$GHFU_FILE" ]; then
        log "未找到包含 __GHFU_GITHUB_TOKEN__ 的 ghfu lua 模板，跳过注入"
    else
        log "环境变量 GHFU_GITHUB_TOKEN 为空，保留占位符，不注入"
    fi
fi

# ---------------------------------------------------------------------------
# 收尾：检查注入目录里有没有 Git 元数据残留，避免被当成包扫进去
# ---------------------------------------------------------------------------
find feeds -maxdepth 4 -name ".git" -type d 2>/dev/null | head -5 | while read -r d; do
    warn "feeds 中残留 Git 目录：$d（建议手动删除，避免 feeds 扫描异常）"
done

ok "DIY2 is complete!"
#------------------------------------------------end 修改脚本----------------
