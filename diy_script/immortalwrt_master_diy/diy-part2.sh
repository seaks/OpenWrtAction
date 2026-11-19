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

    # 稀疏检出，只拉需要的目录
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    # 子 shell 隔离 cd，失败也不污染后续路径
    (cd temp_repo && git sparse-checkout set "${paths[@]}" > /dev/null 2>&1)

    # 提取上游最新的 Commit 时间戳（兜底用）
    local fallback_time
    fallback_time=$(cd temp_repo && git log -1 --format=%cd --date=unix 2>/dev/null || date +%s)

    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name dest_path feed_name symlink_path file_time
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
            cp -r "temp_repo/$p" "$dest_path"

            # 3. 提取真实时间戳，失败则用兜底时间，欺骗编译缓存
            file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            if [ -z "$file_time" ]; then
                file_time=$fallback_time
            fi
            find "$dest_path" -exec touch -m -d @"$file_time" {} +

            echo "✅ 已注入并伪装时间戳: $pkg_name"
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
#    ⚠️ master 分支若编译报 golang-package.mk 相关错误，先注释掉这段试一次
echo ">>> 替换 golang 为 sbwml/packages_lang_golang 27.x ..."
rm -rf feeds/packages/lang/golang
git clone --depth 1 https://github.com/sbwml/packages_lang_golang -b 27.x feeds/packages/lang/golang
echo "✅ golang 替换完成"

# inject_feed "https://github.com/openwrt/luci.git" "feeds/luci/modules" \
#     "modules/luci-mod-dashboard"

echo "🎉 移植完毕"
#----------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# Modify default IP
sed -i 's/192.168.1.1/192.168.101.1/g' package/base-files/files/bin/config_generate

# inject download package（目录不存在或为空都不中断）
mkdir -p dl
if [ -d "$PATCHES_SRC_DIR/library" ]; then
    cp -r "$PATCHES_SRC_DIR/library/." ./dl/ 2>/dev/null \
        && echo "✅ 已复制 library -> dl/" \
        || echo "library 为空，跳过"
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
GHFU_FILE=$(find . -path "*/luci-app-ghfu/*.lua" -exec grep -l '__GHFU_TOKEN__' {} + 2>/dev/null | head -n1)

if [ -n "$GHFU_FILE" ] && [ -n "${GHFU_GITHUB_TOKEN:-}" ]; then
    echo ">>> 找到ghfu模板文件：$GHFU_FILE"
    echo ">>> 注入GHFU_GITHUB_TOKEN"
    perl -pi -e 's|__GHFU_TOKEN__|$ENV{GHFU_GITHUB_TOKEN}|g' "$GHFU_FILE"
else
    if [ -z "$GHFU_FILE" ]; then
        echo "⚠️  未找到包含 __GHFU_TOKEN__ 的ghfu lua模板，跳过注入"
    else
        echo ">>> 环境变量 GHFU_GITHUB_TOKEN 为空，不注入"
    fi
fi

# ==============================================
# xray-core 版本校准（必须在 diy2，feeds update 之后）
# 只改 Makefile 版本号 + 预下载源码，不动目录结构
# ==============================================
XRAY_VER="25.2.21"
XRAY_SHA="a565db518d2da12fabb74e123d9bf2bdbc34420b81373938f8fcbc7004fda3ba"
XRAY_URL="https://codeload.github.com/XTLS/Xray-core/tar.gz/v${XRAY_VER}"
XRAY_FILE="dl/xray-core-${XRAY_VER}.tar.gz"

XRAY_MK=$(find feeds -path "*xray-core*/Makefile" 2>/dev/null | head -n1)
if [ -n "$XRAY_MK" ] && [ -f "$XRAY_MK" ]; then
    CUR_VER=$(grep -m1 '^PKG_VERSION:=' "$XRAY_MK" | awk '{print $3}')
    echo ">>> xray-core 当前版本：$CUR_VER  ($XRAY_MK)"

    if [ "$CUR_VER" != "$XRAY_VER" ]; then
        echo ">>> 版本不符，改为 $XRAY_VER"
        sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=${XRAY_VER}/" "$XRAY_MK"
        sed -i "s/^PKG_HASH:=.*/PKG_HASH:=${XRAY_SHA}/" "$XRAY_MK"
        rm -f dl/xray-core-*.tar.gz 2>/dev/null || true
    else
        echo ">>> 已是 $XRAY_VER，无需改 Makefile"
    fi

    # 预下载源码到 dl/，带 hash 校验，避免截断包拖到编译期才暴露
    mkdir -p dl
    need_dl=1
    if [ -f "$XRAY_FILE" ]; then
        if [ "$(sha256sum "$XRAY_FILE" | awk '{print $1}')" = "$XRAY_SHA" ]; then
            echo "✅ dl 缓存校验通过，跳过下载"
            need_dl=0
        else
            echo "⚠️ 缓存校验失败，重新下载"
            rm -f "$XRAY_FILE"
        fi
    fi
    if [ "$need_dl" = "1" ]; then
        echo ">>> 预下载 xray-core 源码..."
        curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$XRAY_FILE" "$XRAY_URL"
        if [ $? -eq 0 ]; then
            if [ "$(sha256sum "$XRAY_FILE" | awk '{print $1}')" = "$XRAY_SHA" ]; then
                echo "✅ 下载+sha校验通过"
            else
                echo "❌ 下载完成但哈希不匹配！"
                rm -f "$XRAY_FILE"
            fi
        else
            echo "⚠️ 下载失败，编译时会重试"
            rm -f "$XRAY_FILE"
        fi
    fi
    grep -E "^PKG_(VERSION|HASH):=" "$XRAY_MK"
else
    echo "!!! 未找到 xray-core Makefile，跳过"
fi

# ==============================================
# feeds 目录结构被改动（rust / golang），必须重建软链接
# 不做这步，替换不会生效
# ==============================================
echo ">>> 重新安装 feeds..."
./scripts/feeds install -a

echo "DIY2 is complete!"
#------------------------------------------------end 修改脚本-------------------------------------------------------
