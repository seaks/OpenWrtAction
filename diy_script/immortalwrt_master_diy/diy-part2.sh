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

set -e

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
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
    #
    # ⚠️ 失败不中断：set -e 下 clone 失败会直接退出整个 job，
    #    后面的 feeds install / defconfig / 编译全都不执行。这里兜底跳过。
    if ! git clone --sparse --depth=1 "$repo_url" temp_repo > clone.log 2>&1; then
        echo "❌ clone 失败，跳过：$repo_url"
        tail -5 clone.log 2>/dev/null || true
        rm -rf temp_repo clone.log
        return 0
    fi

    # 稀疏检出，只拉需要的目录；子 shell 隔离 cd，失败也不污染后续路径
    (cd temp_repo && git sparse-checkout set "${paths[@]}" > /dev/null 2>&1)

    # 上游最新 Commit 时间戳（仅作兜底）
    local fallback_time
    fallback_time=$(cd temp_repo && git log -1 --format=%cd --date=unix 2>/dev/null || date +%s)

    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name dest_path symlink_path feed_name file_time
            pkg_name=$(basename "$p")
            dest_path="$feed_dir/$pkg_name"

            # 1. 清理 OpenWrt 软链接，防止文件类型冲突
            feed_name=$(echo "$feed_dir" | cut -d'/' -f2)
            symlink_path="package/feeds/$feed_name/$pkg_name"
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # 2. 清理并覆盖目标目录
            rm -rf "$dest_path"
            if ! cp -r "temp_repo/$p" "$dest_path" 2>cp.err; then
                echo "❌ cp 失败，跳过: $p"
                tail -3 cp.err 2>/dev/null || true
                rm -f cp.err
                continue
            fi

            # 3. 提取真实时间戳，失败则用兜底，欺骗编译缓存
            file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            if [ -z "$file_time" ]; then
                file_time=$fallback_time
                echo "  ↳ $p 取不到独立时间戳，使用兜底值"
            fi
            # 只 touch 文件，不动目录：目录 mtime 变化会放大 make 的重扫范围
            if ! find "$dest_path" -type f -exec touch -m -d @"$file_time" {} + 2>touch.err; then
                echo "⚠️ touch 失败（不影响编译）: $p"
                tail -3 touch.err 2>/dev/null || true
            fi
            rm -f touch.err cp.err

            echo "✅ 已注入并伪装时间戳: $pkg_name (@$file_time)"
        else
            echo "⚠️ 路径不存在，跳过: $p"
        fi
    done

    rm -rf temp_repo clone.log
}

# =================================================================
# 执行注入任务
# =================================================================

# 1. 注入 rust
#    源用 immortalwrt：主线 rust 与 immortalwrt master 的 API 可能不兼容
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
    "lang/rust"

# 2. 替换 golang 为 sbwml 27.x
#    分支已确认存在：19.x 20.x ... 25.x 26.x 27.x
#    ⚠️ master 分支若编译报 golang-package.mk 相关错误，放开下面这段试一次
# echo ">>> 替换 golang 为 sbwml/packages_lang_golang 27.x ..."
# rm -rf feeds/packages/lang/golang
# git clone --depth 1 https://github.com/sbwml/packages_lang_golang -b 27.x feeds/packages/lang/golang
# echo "✅ golang 替换完成"

# inject_feed "https://github.com/openwrt/luci.git" "feeds/luci/modules" \
#     "modules/luci-mod-dashboard"

echo "🎉 移植完毕"
#----------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# Modify default IP（先数一下有几处，避免误改）
IP_CNT=$(grep -c "192\.168\.1\.1" package/base-files/files/bin/config_generate 2>/dev/null || echo 0)
if [ "${IP_CNT:-0}" -gt 0 ]; then
    sed -i 's/192\.168\.1\.1/192.168.101.1/g' package/base-files/files/bin/config_generate
    echo "✅ 默认 IP 已改为 192.168.101.1（替换 $IP_CNT 处）"
else
    echo "⚠️ config_generate 中未找到 192.168.1.1，跳过 IP 修改"
fi

# ===== 修复 netspeedtest 依赖 =====
# 问题：sirpdboy/netspeedtest 的 Makefile 按主线 OpenWrt 写依赖，声明了
#       python3-email 与 python3-pkg-resources 两个子包：
#         - python3-email         主线定义在 lang/python/python3/files/python3-package-email.mk
#         - python3-pkg-resources 主线定义在 lang/python/python-setuptools/Makefile
#       但 ImmortalWrt 的 feeds/packages/lang/python 没有拆分这两个包，
#       apk 装 rootfs 时会报 "no such package"，导致 package/install Error 4。
# 处理：从 LUCI_DEPENDS 里删掉这两项。email 模块随 python3-light 的标准库一起
#       装进设备，import email 不受影响；pkg_resources 只有脚本用到 setuptools 时才需要。
# 位置：必须在 feeds install -a 之前改，这样生成的 .packageinfo 才是正确的。
NETSPEEDTEST_MK="feeds/netspeedtest/luci-app-netspeedtest/Makefile"
if [ -f "$NETSPEEDTEST_MK" ]; then
    sed \
        -e 's/ +python3-pkg-resources//g' \
        -e 's/ +python3-email//g' \
        -e 's/^[[:space:]]*python3-pkg-resources[[:space:]]*\\\{0,1\}//g' \
        -e 's/^[[:space:]]*python3-email[[:space:]]*\\\{0,1\}//g' \
        "$NETSPEEDTEST_MK" > "$NETSPEEDTEST_MK.new" \
        && mv "$NETSPEEDTEST_MK.new" "$NETSPEEDTEST_MK" \
        || { echo "❌ sed 修改失败，保留原文件"; rm -f "$NETSPEEDTEST_MK.new"; }

    if grep -q "python3-email\|python3-pkg-resources" "$NETSPEEDTEST_MK"; then
        echo "⚠️ 仍有残留，请手动检查：$NETSPEEDTEST_MK"
        grep -n "python3-email\|python3-pkg-resources" "$NETSPEEDTEST_MK" || true
    else
        echo "✅ netspeedtest 依赖已修正（已无 python3-email / python3-pkg-resources）"
    fi
else
    echo "⚠️ 未找到 $NETSPEEDTEST_MK，跳过（feed 可能改名或尚未拉取）"
fi

# inject download package（目录不存在或为空都不中断）
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    if cp -r "$PATCHES_SRC_DIR/library/." ./dl/ 2>dl.err; then
        echo "✅ 已复制 library -> dl/（$(ls ./dl | wc -l) 个文件）"
    else
        echo "⚠️ 复制 library 时出错，继续编译"
        tail -3 dl.err 2>/dev/null || true
    fi
    rm -f dl.err
else
    echo "未找到 library 目录，跳过"
fi

# --- Modify SSH Configuration (Dropbear -> 2222, OpenSSH -> 22) ---
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-custom-ssh-config
#!/bin/sh

# --- 1. 停止服务 ---
/etc/init.d/dropbear stop
/etc/init.d/sshd stop 2>/dev/null

# --- 2. 配置 Dropbear (UCI) ---
uci set dropbear.@dropbear[0].Port='22'
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
# GHFU 插件 token 注入：perl 安全替换
# 本地 / fork PR 场景没有 Secrets，token 为空时保留占位符，不注入
# ==============================================
GHFU_FILE=$(find . -path "*/luci-app-ghfu/*.lua" -exec grep -l '__GHFU_GITHUB_TOKEN__' {} + 2>/dev/null | head -n1)

if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    echo ">>> 找到 ghfu 模板文件：$GHFU_FILE"
    echo ">>> 注入 GHFU_GITHUB_TOKEN（长度 ${#GHFU_GITHUB_TOKEN}）"
    perl -pi -e 's|__GHFU_GITHUB_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
else
    if [ -z "$GHFU_FILE" ]; then
        echo "⚠️  未找到包含 __GHFU_GITHUB_TOKEN__ 的 ghfu lua 模板，跳过注入"
    else
        echo ">>> 环境变量 GHFU_GITHUB_TOKEN 为空，保留占位符，不注入"
    fi
fi

echo "DIY2 is complete!"
#------------------------------------------------end 修改脚本-------------------------------------------------------
