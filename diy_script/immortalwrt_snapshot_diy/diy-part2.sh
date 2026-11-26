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
# 环境变量（本地、在线都可用）
# ----------------------------------------------------------------------------
#   TARGET_BRANCH    目标分支，默认自动探测（master / openwrt-25.12 ...）
#   GO_VERSION       切到指定 Go 大版本，例如 GO_VERSION=1.27
#                    留空 = 不动，沿用 ImmortalWrt 默认（25.12 为 1.26）
#   RUST_INJECT      1=注入 rust（默认），0=用 ImmortalWrt 自带
#   RUST_REPO        rust 源，默认随分支走（稳定分支用 immortalwrt）
#   GOLANG_REPO      golang 源，留空=不替换（默认，推荐）
#   GOLANG_BRANCH    配合 GOLANG_REPO 使用，例如 27.x
#   PATCHES_SRC_DIR  OpenWrtAction 仓库路径，默认 $HOME/OpenWrtAction
#   GOLANG_LINK_MODE dl 里 golang 源码的处理方式：copy（默认）/ symlink / skip
#   GHFU_GITHUB_TOKEN ghfu token，为空则保留占位符
#
# 常用场景：
#   在线编 25.12，全部用官方底座：
#     无需任何环境变量，直接跑
#   在线编 25.12，Go 换 1.27：
#     GO_VERSION=1.27 ./diy_script/immortalwrt_part2.sh
#   本地编 master，沿用 sbwml 27.x：
#     GOLANG_REPO=https://github.com/sbwml/packages_lang_golang GOLANG_BRANCH=27.x \
#     ./diy_script/immortalwrt_part2.sh
# ============================================================================

set -e
set -o pipefail

# ---------------------------------------------------------------------------
# 日志函数
# ---------------------------------------------------------------------------
log()  { echo ">>> $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 定位 OpenWrtAction 仓库（补丁、dl 缓存、library 所在的那份）
# ---------------------------------------------------------------------------
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="${PATCHES_SRC_DIR:-$GITHUB_WORKSPACE}"
else
    PATCHES_SRC_DIR="${PATCHES_SRC_DIR:-$HOME/OpenWrtAction}"
    [ -d "$PATCHES_SRC_DIR" ] || PATCHES_SRC_DIR="$(cd .. && pwd)/OpenWrtAction"
fi
log "补丁源目录：$PATCHES_SRC_DIR"

# ---------------------------------------------------------------------------
# 探测目标分支
# ---------------------------------------------------------------------------
if [ -z "${TARGET_BRANCH:-}" ]; then
    if [ -d .git ] && git rev-parse --git-dir >/dev/null 2>&1; then
        TARGET_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    [ -z "$TARGET_BRANCH" ] || [ "$TARGET_BRANCH" = "HEAD" ] && TARGET_BRANCH="master"
fi
log "目标分支：${TARGET_BRANCH:-unknown}"

case "${TARGET_BRANCH:-master}" in
    master|main) IS_STABLE=0 ;;
    *)           IS_STABLE=1 ;;
esac

# ---------------------------------------------------------------------------
# 清理上次运行的残留
# ---------------------------------------------------------------------------
rm -rf temp_repo temp_resp clone.log cp.err touch.err dl.err

# ===========================================================================
# 注入函数：从远端稀疏拉取指定目录，覆盖到 feeds 树
#
# 参数：
#   $1  repo_url   远端仓库
#   $2  feed_dir   feeds 下的目标目录，例如 feeds/packages/lang
#   $3... paths    相对仓库根的完整路径，例如 lang/rust
#
# ⚠️ paths 必须写完整路径。早期版本用 shift 2 后再 cut -d'/' -f2 推 feed 名，
#    会把 lang/ 这一级吃掉，清理的是 package/feeds/packages/rust 这种
#    不存在的路径，真实软链残留下来和覆盖后的目录打架。
# ===========================================================================
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    [ "${#paths[@]}" -gt 0 ] || { warn "inject_feed 未传路径，跳过：$repo_url"; return 0; }

    log "正在从 $repo_url 拉取至 $feed_dir ..."

    # ⚠️ 不要用 --filter=blob:none：blobless 克隆下 git log -- <path> 要联网拉
    #    blob，大概率返回空 → 全部共用 fallback_time → mtime 失真 →
    #    Checkpoint 每次都判定 "Base 有变化"，缓存白推。
    #    浅克隆 blob 都在本地，git log 纯本地，时间戳准确。
    # ⚠️ 失败不中断：set -e 下 clone 失败会直接退出整个 job，
    #    后面的 feeds install / defconfig / 编译全都不执行。
    if ! git clone --sparse --depth=1 "$repo_url" temp_repo > clone.log 2>&1; then
        warn "clone 失败，跳过：$repo_url"
        tail -5 clone.log 2>/dev/null || true
        rm -rf temp_repo clone.log
        return 0
    fi

    # 稀疏检出；--no-cone 让 lang/rust 和 lang/python/* 两种写法都能用
    if ! (cd temp_repo && git sparse-checkout set --no-cone "${paths[@]}" >/dev/null 2>&1); then
        warn "sparse-checkout 失败，跳过：$repo_url"
        rm -rf temp_repo clone.log
        return 0
    fi

    local fallback_time now_ts
    fallback_time="$(cd temp_repo && git log -1 --format=%cd --date=unix 2>/dev/null || true)"
    fallback_time="${fallback_time:-$(date +%s)}"
    now_ts="$(date +%s)"

    local p pkg_name dest_path symlink_path feed_name sub_path file_time
    for p in "${paths[@]}"; do
        if [ ! -d "temp_repo/$p" ]; then
            warn "路径不存在，跳过：$p"
            continue
        fi

        pkg_name="$(basename "$p")"
        dest_path="$feed_dir/$pkg_name"

        # feeds/packages/lang -> feed_name=packages, sub_path=packages/lang
        feed_name="$(printf '%s' "$feed_dir" | sed -n 's|^\([./]*\)feeds/\([^/]*\).*$|\2|p')"
        sub_path="$(printf '%s' "$feed_dir"  | sed -n 's|^\([./]*\)feeds/||p')"

        # 1. 清理旧软链接，防止文件类型冲突
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

        # 3. 伪装时间戳：取该路径最后一次 commit 时间
        file_time="$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null || true)"
        file_time="${file_time:-$fallback_time}"
        # ⚠️ 上游 commit 时间可能晚于当前时间（仓库时间线靠前），
        #    未来时间会让 make 每次都判定需要重编，这里钳到当前时间
        if [ "$file_time" -gt "$now_ts" ] 2>/dev/null; then
            log "  $p 时间戳 ($file_time) 晚于当前时间，钳制为 $now_ts"
            file_time="$now_ts"
        fi
        # 只 touch 文件，不动目录：目录 mtime 变化会放大 make 的重扫范围
        if ! find "$dest_path" -type f -exec touch -m -d @"$file_time" {} + 2> touch.err; then
            warn "touch 失败（不影响编译）：$p"
            tail -3 touch.err 2>/dev/null || true
        fi
        rm -f touch.err cp.err

        ok "已注入：$pkg_name -> $dest_path (@$file_time)"
    done

    rm -rf temp_repo clone.log
}

# ===========================================================================
# Go 版本切换
#
# 不写死 CONFIG_GO_VERSION_1_27 这种名字：不同 golang 包的 Config.in
# 写法可能是 `config GO_VERSION` + string，也可能是 choice + GO_VERSION_1_27。
# 这里让 scripts/config 自己按值去找符号，找不到就报警告不中断。
# ===========================================================================
go_select() {
    local want="$1"
    local golang_dir="feeds/packages/lang/golang"

    if [ ! -f "$golang_dir/golang-values.mk" ]; then
        warn "未找到 $golang_dir/golang-values.mk，跳过 Go 版本切换"
        return 0
    fi

    local supported
    supported="$(sed -n 's/^GO_VERSIONS[[:space:]]*:?*=\(.*\)$/\1/p' "$golang_dir/golang-values.mk" 2>/dev/null \
                 | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+$' || true)"

    log "该分支支持的 Go 版本：$(printf '%s' "$supported" | tr '\n' ' ')"

    if [ -n "$supported" ] && ! printf '%s\n' "$supported" | grep -qx "$want"; then
        warn "Go $want 不在支持列表内，保持默认版本"
        return 0
    fi

    if [ ! -x scripts/config ]; then
        warn "scripts/config 不存在或不可执行，跳过 Go 版本切换"
        return 0
    fi

    # 找到值为 $want 的那个符号名
    local sym
    sym="$(scripts/config --symbols 2>/dev/null | tr ' ' '\n' \
           | grep -E '^CONFIG_GO_VERSION' \
           | while read -r s; do
                 v="$(scripts/config --state "${s#CONFIG_}" 2>/dev/null || true)"
                 [ "$v" = "$want" ] && printf '%s\n' "$s"
             done | head -1)"

    if [ -z "$sym" ]; then
        # 兜底：choice 形式通常是 CONFIG_GO_VERSION_1_27
        sym="CONFIG_GO_VERSION_$(printf '%s' "$want" | tr '.' '_')"
        if ! scripts/config --symbols 2>/dev/null | tr ' ' '\n' | grep -qx "$sym"; then
            warn "未找到 Go $want 对应的配置符号，保持默认版本"
            return 0
        fi
    fi

    log "切换到 Go $want（符号：$sym）"
    scripts/config --enable "${sym#CONFIG_}" 2>/dev/null \
        || scripts/config --set-str GO_VERSION "$want" 2>/dev/null \
        || { warn "切换失败，保持默认版本"; return 0; }

    ok "Go 版本已设为 $want"
    grep -E "^CONFIG_GO_VERSION" .config 2>/dev/null | head -5 || true
}

# ===========================================================================
# 执行注入任务
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. rust
#    ⚠️ 源必须和目标分支同源：
#       - master   用 openwrt/packages（主线）或 immortalwrt/packages
#       - 稳定分支 用 immortalwrt/packages；主线 rust 版本会漂，
#                  还会和分支自带的 rust-bindgen 等配套件错开
#    RUST_INJECT=0 可完全跳过，直接用 ImmortalWrt 自带的 rust。
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
#    ⚠️ ImmortalWrt 25.12 的 lang/golang 已是新版结构：
#       golang-bootstrap + golang-version.mk + golang1.26/golang1.27/...
#       golang-values.mk 里的 GO_DEFAULT_VERSION 决定 golang/host 指向谁
#       （25.12 为 1.26），各 Go 包无需改依赖名。
#    ⚠️ 所以稳定分支默认【不替换】，沿用官方配套版本最稳。
#    要换源（比如 master 固定到某大版本）：
#       GOLANG_REPO=https://github.com/sbwml/packages_lang_golang \
#       GOLANG_BRANCH=27.x ./diy_script/immortalwrt_part2.sh
# ---------------------------------------------------------------------------
if [ -n "${GOLANG_REPO:-}" ]; then
    GOLANG_BRANCH="${GOLANG_BRANCH:-master}"
    log "替换 golang：$GOLANG_REPO（分支 $GOLANG_BRANCH）"

    rm -rf feeds/packages/lang/golang
    if git clone --depth 1 "$GOLANG_REPO" -b "$GOLANG_BRANCH" feeds/packages/lang/golang; then
        ok "golang 替换完成（$GOLANG_BRANCH）"
    else
        warn "clone golang 失败，尝试恢复官方版本"
        rm -rf feeds/packages/lang/golang
        if ./scripts/feeds update -p packages && ./scripts/feeds install golang; then
            ok "已恢复官方 golang"
        else
            die "golang 恢复失败，请手动执行：./scripts/feeds update -a && ./scripts/feeds install -a"
        fi
    fi
else
    log "未设置 GOLANG_REPO，沿用 ImmortalWrt 自带 golang"
    if [ -f feeds/packages/lang/golang/golang-values.mk ]; then
        grep -E "^GO_DEFAULT_VERSION" feeds/packages/lang/golang/golang-values.mk | head -1 || true
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
# ⚠️ grep -c 无匹配时返回 1，set -e 下必须 || true 兜住；
#    不能用 || echo 0，会多输出一行变成 "0\n0"
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
#       python3-email 与 python3-pkg-resources：
#         - python3-email         主线在 lang/python/python3/files/python3-package-email.mk
#         - python3-pkg-resources 主线在 lang/python/python-setuptools/Makefile
#       ImmortalWrt 的 feeds/packages/lang/python 没拆这两个包，
#       apk 装 rootfs 时报 "no such package"，package/install Error 4。
# 处理：从 LUCI_DEPENDS 删掉这两项。email 随 python3-light 标准库一起装进设备，
#       import email 不受影响；pkg_resources 只有脚本用到 setuptools 时才需要。
# 位置：必须在 feeds install -a 之前改，这样 .packageinfo 才是正确的。
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
# inject download package
# ⚠️ dl 可能是指向外部缓存的软链接，cp -r 会顺着链接把文件塞进链接目标，
#    所以先判 -L；想省空间可以用 GOLANG_LINK_MODE=symlink
# ---------------------------------------------------------------------------
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    LIB_CNT="$(find "$PATCHES_SRC_DIR/library" -type f 2>/dev/null | wc -l)"
    LIB_CNT="${LIB_CNT//[[:space:]]/}"

    if [ "${LIB_CNT:-0}" -gt 0 ]; then
        if [ -L "dl" ]; then
            ok "dl 是软链接（$(readlink -f dl)），直接往里复制"
        fi
        case "${GOLANG_LINK_MODE:-copy}" in
            symlink)
                ln -sfn "$(readlink -f "$PATCHES_SRC_DIR/library")" ./dl/library_link
                ok "已软链接 library -> dl/library_link"
                ;;
            skip)
                log "GOLANG_LINK_MODE=skip，跳过 library 复制"
                ;;
            *)
                if cp -r "$PATCHES_SRC_DIR/library/." ./dl/ 2> dl.err; then
                    ok "已复制 library -> dl/（$LIB_CNT 个文件）"
                else
                    warn "复制 library 时出错，继续编译"
                    tail -3 dl.err 2>/dev/null || true
                fi
                rm -f dl.err
                ;;
        esac
    else
        log "$PATCHES_SRC_DIR/library 为空，跳过"
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
ok "已写入 files/etc/uci-defaults/99-custom-ssh-config"

# --- End Modify SSH Configuration ---

# ==========================================================================
# GHFU 插件 token 注入：perl 安全替换
# 本地 / fork PR 场景没有 Secrets，token 为空时保留占位符，不注入
# ==========================================================================
GHFU_FILE="$(find . -path "*/luci-app-ghfu/*.lua" -exec grep -l '__GHFU_GITHUB_TOKEN__' {} + 2>/dev/null | head -n1)"

if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    log "找到 ghfu 模板：$GHFU_FILE"
    log "注入 GHFU_GITHUB_TOKEN（长度 ${#GHFU_GITHUB_TOKEN}）"
    perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
else
    if [ -z "$GHFU_FILE" ]; then
        log "未找到含 __GHFU_GITHUB_TOKEN__ 的 ghfu 模板，跳过注入"
    else
        log "GHFU_GITHUB_TOKEN 为空，保留占位符，不注入"
    fi
fi

# ---------------------------------------------------------------------------
# Go 版本切换（放在最后：golang 目录可能刚被替换过）
# ---------------------------------------------------------------------------
if [ -n "${GO_VERSION:-}" ]; then
    go_select "$GO_VERSION"
else
    log "未设置 GO_VERSION，沿用默认 Go 版本"
    if [ -f feeds/packages/lang/golang/golang-values.mk ]; then
        grep -E "^GO_DEFAULT_VERSION" feeds/packages/lang/golang/golang-values.mk | head -1 || true
    fi
fi

# ---------------------------------------------------------------------------
# 收尾检查：只报 feeds 子目录里的 .git
#   feeds/bandi/.git 这类是 src-git 拉下来自带的，属正常，不报
# ---------------------------------------------------------------------------
find feeds -mindepth 2 -maxdepth 5 -name ".git" -type d 2>/dev/null \
    | grep -vE "^feeds/[^/]+/\.git$" | head -10 | while read -r d; do
    warn "feeds 子目录中残留 Git 目录（疑似 cp -r 污染）：$d"
done

# 关键目录自检
for d in feeds/packages/lang/rust feeds/packages/lang/golang feeds/luci/luci-base; do
    [ -e "$d" ] || warn "关键目录缺失：$d"
done

ok "DIY2 is complete!"
#------------------------------------------------end 修改脚本---------------
