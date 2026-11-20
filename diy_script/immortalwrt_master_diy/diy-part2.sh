#!/bin/bash
#
# Copyright (c) 2019-2026 seaks <https://github.com/seaks>
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction   ← 上游模板
# https://github.com/seaks/OpenWrtAction          ← 本 fork
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# 执行时机：feeds update -a && feeds install -a 之后
#

# 不开 set -e：可选步骤失败不该中断整体（dl 缓存、sed、find 都是可选项）
# 关键步骤（rust / token / 校验）内部自己 return 1 / exit 1
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi
export TOPDIR="$PWD"

# ----------------------------------------------------------------
# 定位 custom_feeds_and_packages.sh
#   本脚本：  diy_script/immortalwrt_master_diy/diy-part2.sh
#   目标文件：diy_script/custom_feeds_and_packages.sh
#   → 从脚本自身位置往上一级即到 diy_script/
#   ⚠️ 必须用 BASH_SOURCE：不能用 $GITHUB_WORKSPACE（本地跑时为空），
#      也不能用 ../ （相对 $PWD，workflow 里 cd 时机一变就断）
# ----------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEEDS_SCRIPT="$(cd "$SELF_DIR/.." && pwd)/custom_feeds_and_packages.sh"

HAS_HELPER=0
if [ ! -f "$FEEDS_SCRIPT" ]; then
    echo "!!! 找不到 $FEEDS_SCRIPT" >&2
    echo "    SELF_DIR=$SELF_DIR" >&2
    echo "    该文件的正确位置是 diy_script/custom_feeds_and_packages.sh" >&2
else
    # shellcheck disable=SC1090
    if source "$FEEDS_SCRIPT"; then
        if command -v check_bandix_ver >/dev/null 2>&1 \
           && command -v check_geodata >/dev/null 2>&1; then
            HAS_HELPER=1
            echo "✅ 已加载 custom_feeds_and_packages.sh"
        else
            echo "!!! 脚本已加载，但校验函数缺失" >&2
            echo "    需要 check_bandix_ver / check_geodata" >&2
        fi
    else
        echo "!!! source $FEEDS_SCRIPT 失败" >&2
    fi
fi

#------------------------------------------------------移植包------------------------------------------------------------
# =================================================================
# 稀疏检出注入
#   $1 = 仓库 URL
#   $2 = 目标父目录（如 feeds/packages/lang）
#   $3.. = 仓库内路径（如 lang/rust），目标名取 basename
#
#   ⚠️ --filter=blob:none 是延迟拉取（只下 commit 树，不下 blob），
#      设完 sparse-checkout 模式必须手动 git checkout，
#      否则工作树是空的，cp 会报 "cannot stat"
#   ⚠️ openwrt/packages 默认分支是 master，不写 -b 即用远端默认
#   ⚠️ 任何一步失败都 return 1，绝不打假的 ✅
# =================================================================
inject_feed_pkg() {
    local repo_url="$1" dest_base="$2"
    shift 2
    local paths=("$@")
    local tmp name dest p ftime fallback_time

    tmp=$(mktemp -d)
    echo "🚀 拉取 ${paths[*]} <- $repo_url"

    if ! git clone --filter=blob:none --sparse --depth=1 -c http.timeout=120 \
            "$repo_url" "$tmp/repo" 2>"$tmp/e1"; then
        echo "!!! clone 失败: $repo_url" >&2
        sed 's/^/    /' "$tmp/e1" >&2
        rm -rf "$tmp"
        return 1
    fi

    if ! ( cd "$tmp/repo" \
           && git sparse-checkout set "${paths[@]}" 2>"$tmp/e2" \
           && git checkout 2>"$tmp/e3" ); then
        echo "!!! sparse-checkout / checkout 失败: ${paths[*]}" >&2
        sed 's/^/    /' "$tmp/e2" "$tmp/e3" >&2
        rm -rf "$tmp"
        return 1
    fi

    fallback_time=$(cd "$tmp/repo" && git log -1 --format=%cd --date=unix 2>/dev/null || date +%s)

    for p in "${paths[@]}"; do
        name=$(basename "$p")                     # lang/rust → rust
        dest="$dest_base/$name"

        if [ ! -d "$tmp/repo/$p" ]; then
            echo "!!! 路径不存在：$p （上游可能已改名）" >&2
            echo "    仓库根下实际有：" >&2
            (cd "$tmp/repo" && ls -1) | sed 's/^/      /' >&2
            rm -rf "$tmp"
            return 1
        fi

        # 清掉 OpenWrt 的软链接，避免文件类型冲突
        [ -L "package/feeds/$name" ] && rm -f "package/feeds/$name"

        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        cp -r "$tmp/repo/$p" "$dest"

        # 用上游真实提交时间，避免每次 CI 都重编这个包
        ftime=$(cd "$tmp/repo" && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
        [ -z "$ftime" ] && ftime="$fallback_time"
        find "$dest" -exec touch -m -d @"$ftime" {} +

        echo "✅ 注入 $name -> $dest （$(date -d @"$ftime" '+%F %T')，$(find "$dest" -type f | wc -l) 个文件）"
    done

    rm -rf "$tmp"
    return 0
}

# ----------------------------------------------------------------
# 1. rust —— bandix eBPF 后端必需
#    openwrt/packages 中路径是 lang/rust（根目录没有 rust/）
#    实测可用：PKG_VERSION 1.96.1，7 个文件
# ----------------------------------------------------------------
if ! inject_feed_pkg "https://github.com/openwrt/packages.git" "feeds/packages/lang" "lang/rust"; then
    echo "!!! rust 注入失败，bandix 后端无法编译" >&2
    exit 1
fi
echo "    $(grep -m1 '^PKG_VERSION' feeds/packages/lang/rust/Makefile 2>/dev/null || echo 'Makefile 未取到')"

# ----------------------------------------------------------------
# 2. golang —— sbwml/packages_lang_golang
#    27.x 是该仓库默认分支（Go 1.27.4）
#    ⚠️ 先 clone 到临时目录，成功后再替换。
#       旧写法是「先 rm -rf 再 clone」，clone 一失败就是净删除，
#       源码原版也没了，所有 Go 包（xray-core / sing-box / mosdns）全挂
#    ⚠️ 兼容两种结构：根下有 golang/ 目录，或 Makefile 直接在根
#    ⚠️ 失败只警告不中断：原版 golang 还在，编译最多报版本偏低
# ----------------------------------------------------------------
GOLANG_BRANCH="${GOLANG_BRANCH:-27.x}"
echo ">>> 替换 golang -> sbwml/packages_lang_golang ($GOLANG_BRANCH)"

TMP_GO=$(mktemp -d)
if git clone --depth 1 -b "$GOLANG_BRANCH" -c http.timeout=180 \
        https://github.com/sbwml/packages_lang_golang.git "$TMP_GO/src" 2>"$TMP_GO/e"; then

    if [ -d "$TMP_GO/src/golang" ]; then
        GO_SRC="$TMP_GO/src/golang"
    elif [ -f "$TMP_GO/src/Makefile" ]; then
        GO_SRC="$TMP_GO/src"
    else
        echo "!!! 仓库结构不认识，根目录下实际有：" >&2
        (cd "$TMP_GO/src" && ls -1) | sed 's/^/    /' >&2
        GO_SRC=""
    fi

    if [ -n "$GO_SRC" ]; then
        rm -rf "feeds/packages/lang/golang"
        mkdir -p "feeds/packages/lang"
        cp -r "$GO_SRC" "feeds/packages/lang/golang"
        rm -rf "feeds/packages/lang/golang/.git"      # 别把 .git 带进 feeds 树
        GO_VER=$(sed -n 's/^GO_VERSION:=//p' feeds/packages/lang/golang/golang/Makefile 2>/dev/null | head -n1)
        echo "✅ golang 替换完成：${GO_VER:-版本未取到}（$(find feeds/packages/lang/golang -type f | wc -l) 个文件）"
    else
        echo "⚠️ golang 未替换，保留源码原版" >&2
    fi
else
    echo "⚠️ golang clone 失败，保留源码原版 golang，继续编译" >&2
    sed 's/^/    /' "$TMP_GO/e" >&2
fi
rm -rf "$TMP_GO"

echo "🎉 移植包处理完成"
#------------------------------------------------------end移植包--------------------------------------------------------

#-----------------------------------------------基础修改------------------------------------------------------------
# 默认 IP
sed -i 's/192.168.1.1/192.168.101.1/g' package/base-files/files/bin/config_generate
echo "✅ 默认 IP -> 192.168.101.1"

# dl 缓存（下载过的源码包，能省大量编译时间）
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    if cp -r "$PATCHES_SRC_DIR/library/." dl/ 2>/dev/null; then
        echo "✅ library 缓存导入 dl（$(ls -1 dl | wc -l) 个文件）"
    else
        echo "⚠️ library 目录为空，跳过"
    fi
else
    echo "⚠️ 未找到 $PATCHES_SRC_DIR/library"
fi

# SSH：允许 root 登录
#   两种形态都覆盖：被注释掉的、显式写成 no 的
DROPBEAR_CONF="package/network/services/dropbear/files/dropbear.config"
if [ -f "$DROPBEAR_CONF" ]; then
    sed -i -e 's/^#\s*PermitRootLogin.*/PermitRootLogin yes/' \
           -e 's/^\s*PermitRootLogin\s*no\s*$/PermitRootLogin yes/' "$DROPBEAR_CONF"
    echo "✅ dropbear 允许 root 登录"
else
    echo "⚠️ 未找到 $DROPBEAR_CONF"
fi
#-----------------------------------------------end基础修改----------------------------------------------------------

# ==============================================
# GHFU token 注入
#   ⚠️ workflow 必须显式传 env，否则这里永远是空：
#        env:
#          GHFU_GITHUB_TOKEN: ${{ secrets.GHFU_GITHUB_TOKEN }}
#   实测路径：feeds/ghfu/luci-app-ghfu/luasrc/controller/ghfu.lua
#   README 单编：make package/feeds/ghfu/luci-app-ghfu/compile -j$(nproc)
# ==============================================
if [ -z "${GHFU_GITHUB_TOKEN:-}" ]; then
    echo "⚠️ GHFU_GITHUB_TOKEN 为空，跳过注入"
else
    GHFU_FILE="${GHFU_LUA:-}"
    if [ -z "$GHFU_FILE" ] || [ ! -f "$GHFU_FILE" ]; then
        GHFU_FILE=$(find . -path "*/luci-app-ghfu/*" -name "*.lua" -type f \
                    -exec grep -l '__GHFU_GITHUB_TOKEN__' {} + 2>/dev/null | head -n1)
    fi

    if [ -n "$GHFU_FILE" ] && [ -f "$GHFU_FILE" ]; then
        echo "✅ 找到 ghfu 模板：$GHFU_FILE"
        # 用 | 作分隔符，token 里含 / 也不会把 sed/perl 搞炸
        perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
        if grep -q '__GHFU_GITHUB_TOKEN__' "$GHFU_FILE"; then
            echo "!!! token 注入失败，占位符仍在文件里" >&2
            exit 1
        fi
        echo "✅ GHFU_TOKEN 注入完成（占位符已清空）"
    else
        echo "⚠️ 未找到含 __GHFU_GITHUB_TOKEN__ 的 lua 文件"
    fi
fi

# ==============================================
# 校验（feeds install 之后 feeds/ 下才有 Makefile）
#   函数返回 1 会让 CI 变红 —— 这是故意的：
#   版本错位编出来的固件装完是废的，不如现在就拦住
# ==============================================
if [ "$HAS_HELPER" -eq 1 ]; then
    echo "===== bandix 版本校验 ====="
    check_bandix_ver

    echo "===== geodata 来源检查 ====="
    check_geodata
else
    echo "===== 校验跳过 ====="
    echo "⚠️ bandix 版本与 geodata 来源本次均未校验" >&2
fi

echo "✅ diy-part2 finished"
