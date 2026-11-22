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

set -e

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi


#------------------------------------------------------移植包------------------------------------------------------------
rm -rf temp_resp

# =================================================================
# 极速拉取并注入 Feeds 树的函数
# =================================================================
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    echo "🚀 正在从 $repo_url 极速拉取至 $feed_dir ..."

    # ⚠️ 不要用 --filter=blob:none：
    #    blobless 克隆下 git log -- <path> 要联网拉 blob，大概率返回空，
    #    导致所有包共用 fallback_time → mtime 失真 → Checkpoint 每次都判定
    #    "Base 有变化"，5GB 缓存白推
    #    浅克隆的 blob 都在本地，git log 是纯本地操作，时间戳准确
    git clone --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1

    # 稀疏检出，只拉需要的目录；子 shell 隔离 cd，失败也不污染后续路径
    (cd temp_repo && git sparse-checkout set "${paths[@]}" > /dev/null 2>&1)

    # 上游最新 Commit 时间戳（仅作兜底）
    local fallback_time
    fallback_time=$(cd temp_repo && git log -1 --format=%cd --date=unix 2>/dev/null || date +%s)

    # feed 名取 feed_dir 的父目录名：
    #   feeds/packages/lang -> packages
    #   feeds/packages      -> packages   （单层路径也正确）
    local feed_name; feed_name=$(basename "$(dirname "$feed_dir")")

    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name dest_path symlink_path file_time
            pkg_name=$(basename "$p")
            dest_path="$feed_dir/$pkg_name"

            # 1. 清理 OpenWrt 软链接，防止文件类型冲突
            symlink_path="package/feeds/$feed_name/$pkg_name"
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # 2. 清理并覆盖目标目录
            rm -rf "$dest_path"
            cp -r "temp_repo/$p" "$dest_path"

            # 3. 提取真实时间戳，失败则用兜底，欺骗编译缓存
            file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            if [ -z "$file_time" ]; then
                file_time=$fallback_time
                echo "  ↳ $p 取不到独立时间戳，使用兜底值"
            fi
            # 只 touch 文件，不动目录：目录 mtime 变化会放大 make 的重扫范围
            find "$dest_path" -type f -exec touch -m -d @"$file_time" {} +

            echo "✅ 已注入并伪装时间戳: $pkg_name (@$file_time)"
        else
            echo "⚠️ 路径不存在，跳过: $p"
        fi
    done

    rm -rf temp_repo
}

# =================================================================
# 执行注入任务
# =================================================================

# 1. 注入 rust
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
    "lang/rust"

# 2. 替换 golang 为 sbwml 27.x
echo ">>> 替换 golang 为 sbwml/packages_lang_golang 27.x ..."
rm -rf feeds/packages/lang/golang
git clone --depth 1 -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
echo "✅ golang 替换完成"

# inject_feed "https://github.com/openwrt/luci.git" "feeds/luci/modules" \
#     "modules/luci-mod-dashboard"

echo "🎉 移植完毕"
#----------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# Modify default IP
sed -i 's/192.168.1.1/192.168.101.1/g' package/base-files/files/bin/config_generate

# library -> dl/ 的注入已统一交给 step04_copy_backgroundfiles.sh：
#   两处都做会导致 Defconfig 流程下 dl 内文件 mtime 被刷新成当下，
#   而 Defconfig workflow 没有 Cache 那边的时间戳回拨步骤
echo "ℹ️ library 注入由 step04 负责，此处跳过"

# --- Modify SSH Configuration (Dropbear -> 2222, OpenSSH -> 22) ---
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
# --- End Modify SSH Configuration ---

# ==============================================
# GHFU 插件 token 注入：perl安全替换
# ==============================================
GHFU_FILE=$(find . -path "*/luci-app-ghfu/*.lua" -exec grep -l '__GHFU_GITHUB_TOKEN__' {} + 2>/dev/null | head -n1)

if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    echo ">>> 找到ghfu模板文件：$GHFU_FILE"
    echo ">>> 注入GHFU_GITHUB_TOKEN"
    perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
else
    if [ -z "$GHFU_FILE" ]; then
        echo "⚠️  未找到包含__GHFU_GITHUB_TOKEN__的ghfu lua模板，跳过注入"
    else
        echo ">>> 环境变量 GHFU_GITHUB_TOKEN 为空，不注入"
    fi
fi

echo "DIY2 is complete!"
#------------------------------------------------end 修改脚本-------------------------------------------------------
