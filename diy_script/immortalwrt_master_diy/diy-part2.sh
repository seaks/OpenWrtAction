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
# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi
export TOPDIR="$PWD"

# 加载 bandix 版本校验函数
PARENT_DIR="$GITHUB_WORKSPACE"
FEEDS_SCRIPT="$PARENT_DIR/custom_feeds_and_packages.sh"
if [ -f "$FEEDS_SCRIPT" ]; then
    source "$FEEDS_SCRIPT"
    echo "✅ 已加载 custom_feeds_and_packages.sh，导入 check_bandix_ver"
else
    echo "⚠️ 找不到 custom_feeds_and_packages.sh，跳过 bandix 版本校验"
    check_bandix_ver() {
        echo "skip bandix check"
    }
fi

#------------------------------------------------------移植包------------------------------------------------------------
rm -rf temp_repo
# =================================================================
# 快速拉取feeds内包函数
# =================================================================
inject_feed_pkg() {
    local repo_url="$1"
    local feed_path="$2"
    shift 2
    local pkg_list=("$@")
    echo "🚀 拉取包：${pkg_list[*]} 到 $feed_path"
    git clone --filter=blob:none --sparse --depth 1 "$repo_url" temp_repo >/dev/null 2>&1
    (cd temp_repo && git sparse-checkout set "${pkg_list[@]}")
    for pkg in "${pkg_list[@]}"; do
        rm -rf "$feed_path/$pkg"
        cp -r "temp_repo/$pkg" "$feed_path/"
        local pkg_target="$feed_path/$pkg"
        find "$pkg_target" -type f -print0 | xargs -0 touch -m
        echo "✅ 导入 $pkg -> $feed_path"
    done
    rm -rf temp_repo
}
# =================================================================
# 执行导入
# =================================================================
# 1. 导入rust
inject_feed_pkg "https://github.com/openwrt/packages.git" "feeds/packages/lang" "rust"
# 2. 替换golang为sbwml 27.x
echo ">>> 替换 golang 为 sbwml/packages lang/golang 27.x"
rm -rf feeds/packages/lang/golang
inject_feed_pkg "https://github.com/sbwml/packages.git" "feeds/packages/lang" "golang"
echo "🎉 移植包处理完成"
#------------------------------------------------------end移植包--------------------------------------------------------

#-----------------------------------------------基础修改------------------------------------------------------------
# 修改默认IP
sed -i 's/192.168.1.1/192.168.101.1/g' package/base-files/files/bin/config_generate
# 复制dl缓存
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    cp -r "$PATCHES_SRC_DIR/library/." dl/ 2>/dev/null && echo "✅ library缓存导入dl" || echo "library为空，跳过"
fi
# 配置ssh
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' package/network/services/dropbear/files/dropbear.config
#-----------------------------------------------end基础修改----------------------------------------------------------

# ==============================================
# GHFU token注入
# ==============================================
GHFU_FILE=$(find . -path "*/luci-app-ghfu/*ghfu.lua" -type f | head -n1)
if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    echo "✅ 找到ghfu模板：$GHFU_FILE"
    perl -pi -e "s|__GHFU_GITHUB_TOKEN__|$GHFU_GITHUB_TOKEN|g" "$GHFU_FILE"
    echo "✅ GHFU_TOKEN 注入完成"
else
    echo "⚠️ 未找到ghfu.lua或者GHFU_GITHUB_TOKEN为空，跳过注入"
fi

# bandix版本校验
echo "===== 执行 bandix 版本校验 ====="
check_bandix_ver

echo "✅ diy-part2 finished"
