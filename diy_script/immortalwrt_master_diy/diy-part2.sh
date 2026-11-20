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
#

# ⚠️ 不开 set -e：可选步骤失败不该中断整体
#    关键步骤（clone / 校验）内部自己 return 1 / exit 1
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi
export TOPDIR="$PWD"

# ----------------------------------------------------------------
# 定位 custom_feeds_and_packages.sh
#   本脚本在 diy_script/immortalwrt_master_diy/ 下 → 往上一级到 diy_script/
# ----------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEEDS_SCRIPT="$(cd "$SELF_DIR/.." && pwd)/custom_feeds_and_packages.sh"

if [ ! -f "$FEEDS_SCRIPT" ]; then
    echo "!!! 找不到 $FEEDS_SCRIPT" >&2
    echo "    SELF_DIR=$SELF_DIR" >&2
    echo "skip bandix check"
else
    # shellcheck disable=SC1090
    source "$FEEDS_SCRIPT" || { echo "!!! source $FEEDS_SCRIPT 失败" >&2; exit 1; }
    command -v check_bandix_ver >/dev/null 2>&1 || { echo "!!! check_bandix_ver 未定义" >&2; exit 1; }
    echo "✅ 已加载 custom_feeds_and_packages.sh"
fi

#------------------------------------------------------移植包------------------------------------------------------------
# =================================================================
# 稀疏检出注入（新版：mktemp 动态临时目录，无硬编码 temp_repo）
#   $1 = 仓库 URL
#   $2 = 目标父目录（如 feeds/packages/lang）
#   $3.. = 仓库内路径（如 lang/rust），目标名取 basename
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
        name=$(basename "$p")
        dest="$dest_base/$name"

        if [ ! -d "$tmp/repo/$p" ]; then
            echo "!!! 路径不存在：$p （上游可能已改名）" >&2
            echo "    仓库根下实际有：" >&2
            (cd "$tmp/repo" && ls -1) | sed 's/^/      /' >&2
            rm -rf "$tmp"
            return 1
        fi

        [ -L "package/feeds/$name" ] && rm -f "package/feeds/$name"

        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        cp -r "$tmp/repo/$p" "$dest"

        ftime=$(cd "$tmp/repo" && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
        [ -z "$ftime" ] && ftime="$fallback_time"
        find "$dest" -exec touch -m -d @"$ftime" {} +

        echo "✅ 注入 $name -> $dest （$(date -d @"$ftime" '+%F %T')，$(find "$dest" -type f | wc -l) 个文件）"
    done

    rm -rf "$tmp"
}

# ----------------------------------------------------------------
# 1. rust —— bandix eBPF 后端需要
#    ⚠️ openwrt/packages 里的路径是 lang/rust
# ----------------------------------------------------------------
if ! inject_feed_pkg "https://github.com/openwrt/packages.git" "feeds/packages/lang" "lang/rust"; then
    echo "!!! rust 注入失败，bandix 后端无法编译" >&2
    exit 1
fi
echo "    $(grep -m1 '^PKG_VERSION' feeds/packages/lang/rust/Makefile 2>/dev/null || echo 'Makefile 未取到')"

# ----------------------------------------------------------------
# 2. golang —— sbwml 维护版
# ----------------------------------------------------------------
GOLANG_BRANCH="${GOLANG_BRANCH:-26.x}"
echo ">>> 替换 golang -> sbwml/packages_lang_golang ($GOLANG_BRANCH)"

TMP_GO=$(mktemp -d)
if git clone --depth 1 -b "$GOLANG_BRANCH" -c http.timeout=120 \
        https://github.com/sbwml/packages_lang_golang.git "$TMP_GO/golang" 2>"$TMP_GO/e"; then
    rm -rf "feeds/packages/lang/golang"
    mv "$TMP_GO/golang" "feeds/packages/lang/golang"
    rm -rf "feeds/packages/lang/golang/.git"
    GO_VER=$(grep -m1 '^GO_VERSION:=' feeds/packages/lang/golang/golang/Makefile 2>/dev/null | sed 's/^GO_VERSION:=//')
    echo "✅ golang 替换完成：${GO_VER:-版本未取到}"
else
    echo "!!! golang clone 失败，保留源码原版" >&2
    sed 's/^/    /' "$TMP_GO/e" >&2
fi
rm -rf "$TMP_GO"

echo "🎉 移植包处理完成"
#------------------------------------------------------end移植包--------------------------------------------------------

#-----------------------------------------------基础修改------------------------------------------------------------
# 默认 IP
sed -i 's/192.168.1.1/192.168.101.1/g' package/base-files/files/bin/config_generate
echo "✅ 默认 IP -> 192.168.101.1"

# dl 缓存
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    if cp -r "$PATCHES_SRC_DIR/library/." dl/ 2>/dev/null; then
        echo "✅ library缓存导入dl（$(ls -1 dl | wc -l) 个文件）"
    else
        echo "⚠️ library 为空，跳过"
    fi
else
    echo "⚠️ 未找到 $PATCHES_SRC_DIR/library"
fi

# SSH：允许 root 登录
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
        perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
        if grep -q '__GHFU_GITHUB_TOKEN__' "$GHFU_FILE"; then
            echo "!!! token 注入失败，占位符仍在" >&2
            exit 1
        fi
        echo "✅ GHFU_TOKEN 注入完成"
    else
        echo "⚠️ 未找到含 __GHFU_GITHUB_TOKEN__ 的 lua 文件"
    fi
fi

# ==============================================
# bandix 版本校验
# ==============================================
if [[ -n "${FEEDS_SCRIPT:-}" && -f "$FEEDS_SCRIPT" ]]; then
    echo "===== bandix 版本校验 ====="
    check_bandix_ver
else
    echo "===== bandix 版本校验 ====="
    echo "skip bandix check"
fi

echo "===== geodata 来源检查 ====="
check_geodata

echo "✅ diy-part2 finished"
