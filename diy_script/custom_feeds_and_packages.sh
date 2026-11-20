#!/bin/bash
#
# custom_feeds_and_packages.sh
# 原则：能走 feeds 的一律走 feeds；需要覆盖官方同名的才 clone 到 package/
# 适用：ImmortalWrt 25.12 / master、OpenWrt CI & 本地编译
#
set -euo pipefail
# ========== 配置区，按需改 ==========
TOPDIR="${TOPDIR:-$PWD}"
FEEDS_CONF="$TOPDIR/feeds.conf.default"
CUSTOM_PKG_PATH="$TOPDIR/package/custom_packages"
MOSDNS_PATH="$TOPDIR/package/mosdns"
FILES_DIR="$TOPDIR/files"
SHALLOW_CLONE=1
# ===================================
# =================================================================
# feeds 扩展列表
# 格式：src-git <别名> <地址>;<分支>
#   别名决定 feeds/ 下的目录名，与官方 README 对齐便于查文档
# =================================================================
gen_repos() {
    local base_repos=(
        # ---------------------------------------------------------------
        # 代理
        # ---------------------------------------------------------------
        "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main"
        "src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main"
        # "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main"
        # "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
        # "src-git OpenClash https://github.com/vernesong/OpenClash.git;master"
        # "src-git helloworld https://github.com/fw876/helloworld.git;dev"
        # ---------------------------------------------------------------
        # 自建插件
        # ---------------------------------------------------------------
        "src-git ghfu https://github.com/seaks/openwrt-ghfu.git;main"
        # ---------------------------------------------------------------
        # 流量监控
        # ---------------------------------------------------------------
        "src-git bandix_backend https://github.com/timsaya/openwrt-bandix.git;main"
        "src-git bandix         https://github.com/timsaya/luci-app-bandix.git;main"
        "src-git netspeedtest   https://github.com/sirpdboy/netspeedtest.git;main"
    )
    if [ "${SKIP_VANTAGE:-0}" -ne 1 ]; then
        base_repos+=(
            # ---------------------------------------------------------------
            # 主题
            # ---------------------------------------------------------------
            "src-git vantage https://github.com/anothaDev/luci-theme-vantage.git;main"
        )
    fi
    printf '%s\n' "${base_repos[@]}"
}
# 追加 feeds 到 feeds.conf.default
append_feeds() {
    echo "===== 追加自定义 feeds 到 $FEEDS_CONF ====="
    : >> "$FEEDS_CONF"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if grep -qxF "$line" "$FEEDS_CONF"; then
            echo "[=] exists: $line"
        else
            printf '%s\n' "$line" >> "$FEEDS_CONF"
            echo "[+] add: $line"
        fi
    done < <(gen_repos)
    echo "===== feeds 追加完成 ====="
}
# feeds install 之后调用：校验 bandix 前后端版本对齐
check_bandix_ver() {
    echo "===== 校验 bandix 前后端版本是否一致 ====="
    local be_feeds="$TOPDIR/feeds/bandix_backend/openwrt-bandix/Makefile"
    local fe_feeds="$TOPDIR/feeds/bandix/luci-app-bandix/Makefile"
    if [ ! -f "$be_feeds" ] || [ ! -f "$fe_feeds" ]; then
        echo "⚠️ bandix feeds 未安装，跳过版本校验"
        return 0
    fi
    local ver_be ver_fe
    ver_be=$(grep -m1 '^PKG_VERSION:' "$be_feeds" | awk '{print $3}')
    ver_fe=$(grep -m1 '^PKG_VERSION:' "$fe_feeds" | awk '{print $3}')
    echo "backend: $ver_be"
    echo "frontend: $ver_fe"
    if [[ "$ver_be" == "$ver_fe" ]]; then
        echo "✅ bandix 前后端版本匹配：$ver_be"
    else
        echo "❌ bandix 前后端版本不一致！后端 $ver_be / 前端 $ver_fe" >&2
        exit 1
    fi
}
# =================================================================
# 自定义软件包
# =================================================================
clone_custom_packages() {
    local path="$CUSTOM_PKG_PATH"
    if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_WORKFLOW:-}" ]; then
        PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
    else
        PATCHES_SRC_DIR="../OpenWrtAction"
    fi
    rm -rf "$path"
    mkdir -p "$path"
    # 克隆到 custom_packages 下
    clone_pkg() {
        local url="$1" dest="$2" branch="${3:-}"
        clone_pkg_abs "$url" "${path}/${dest}" "$branch"
    }
    # 克隆到任意绝对路径（mosdns 要放 package/ 顶层，不能直接复用上面那个）
    clone_pkg_abs() {
        local url="$1" dest="$2" branch="${3:-}"
        echo ">>> 克隆 $url -> $dest${branch:+ (分支 $branch)}"
        local -a git_args=(-c http.timeout=120)
        [ "$SHALLOW_CLONE" -eq 1 ] && git_args+=(--depth 1)
        [ -n "$branch" ] && git_args+=(--branch "$branch")
        git clone "${git_args[@]}" "$url" "$dest" \
            || { echo "!!! 克隆失败: $url" >&2; return 1; }
    }
    # ----------------------------------------------------------------
    # 清理可能残留的旧 mosdns
    #   ⚠️ v2ray-geodata 不要删：
    #      feeds/packages/net/v2ray-geodata 若存在，会被 passwall-packages
    #      的同名包覆盖优先级；删掉反而可能让 mosdns 的依赖解析不到
    #      真出现 multiple times 时再针对性处理
    # ----------------------------------------------------------------
    echo ">>> 清理旧的 mosdns 目录"
    rm -rf "$TOPDIR/package/mosdns"
    rm -rf "$TOPDIR/feeds/packages/net/mosdns"
    # ----------------------------------------------------------------
    # mosdns v5（放 package/mosdns，与 README 的编译路径对齐）
    #   README: make package/mosdns/luci-app-mosdns/compile V=s
    #   v5 分支提供三个目录：
    #     luci-app-mosdns / mosdns / geo2txt
    #   geo2txt 是 install.sh 里替换 v2dat 的工具，别删
    #
    #   geodata 用 passwall-packages 自带那份，不 clone sbwml/v2ray-geodata，
    #   避免和 passwall 撞「defined multiple times」
    #   若哪天把 passwall 也注释掉了，就补一行：
    #     clone_pkg_abs "https://github.com/sbwml/v2ray-geodata.git" "$TOPDIR/package/v2ray-geodata"
    # ----------------------------------------------------------------
    clone_pkg_abs "https://github.com/sbwml/luci-app-mosdns.git" "$MOSDNS_PATH" "v5"
    # ----------------------------------------------------------------
    #内置主题
    # ----------------------------------------------------------------
    clone_pkg "https://github.com/seaks/luci-theme-argon.git" "luci-theme-argon"
    # ============================================================
    # 取消主题自设默认：注释掉行首空白后的 luci.main.mediaurlbase= 赋值行
    # 进程替换而非管道，避免子 shell 变量丢失
    # ============================================================
    local target="luci.main.mediaurlbase="
    echo ">>> 扫描并注释主题自设默认逻辑，关键词：$target"
    while IFS= read -r -d '' file; do
        if grep -qF "$target" "$file"; then
            echo "    命中文件: $file"
            sed -i -E "/^[[:space:]]*${target}/s/^([[:space:]]*)([^#])/\1# \2/" "$file"
        fi
    done < <(find "$path" "$MOSDNS_PATH" -type f \
                  \( -name "Makefile" -o -path "*/etc/uci-defaults/*" \) -print0 2>/dev/null)
    echo ">>> 主题自带默认设置已注释完成"
    # ============================================================
    # 默认主题：zz- 前缀确保在其他 uci-defaults 之后执行
    # ============================================================
    local uci_d_dir="${FILES_DIR}/etc/uci-defaults"
    mkdir -p "$uci_d_dir"
    local theme_script="$uci_d_dir/zz-set-default-theme"
    cat << 'EOF' > "$theme_script"
#!/bin/sh
# 设置默认主题为 Argon（LuCI 标准主题机制）
# Argon README: "Select Argon under
#   System → System → Language and Style → Design"
uci set luci.themes.Argon=/luci-static/argon
uci set luci.main.mediaurlbase=/luci-static/argon
uci commit luci
# 改用 Vantage 时，把上面三行整体替换成下面三行：
# uci set luci.themes.Vantage=/luci-static/vantage
# uci set luci.main.mediaurlbase=/luci-static/vantage
# uci commit luci
#
# Vantage README: "A fresh install switches to the theme for you"
# 它装完会自己切，这里的显式设置只是保险
exit 0
EOF
    chmod +x "$theme_script"
    echo ">>> 默认主题脚本已生成：$theme_script"
    # ============================================================
    # bandix：关闭流量卸载
    # README: "Important: Please disable hardware flow offloading
    #          and Turbo ACC in OpenWrt before using this application"
    # eBPF 抓不到被 offload 的流量，不关统计全是 0
    # 只在首次开机执行一次（uci-defaults 机制）
    # ============================================================
    local offload_script="$uci_d_dir/zz-bandix-disable-offload"
    cat << 'EOF' > "$offload_script"
#!/bin/sh
# 没装 bandix 就什么都不做
command -v bandix >/dev/null 2>&1 || exit 0
# 关闭软件 / 硬件流量卸载
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
# 关闭 Turbo ACC（ImmortalWrt 默认开启）
if uci -q get turboacc.config >/dev/null 2>&1; then
    uci set turboacc.config.flow_offloading='0'
    uci set turboacc.config.flow_offloading_hw='0'
    uci commit turboacc
    /etc/init.d/turboacc restart 2>/dev/null
fi
exit 0
EOF
    chmod +x "$offload_script"
    echo ">>> bandix 关闭卸载脚本已生成：$offload_script"
}
# ========== 入口 ==========
main() {
    append_feeds
    clone_custom_packages
    echo -e "\n✅ custom feeds & packages 处理全部完成"
}

# ⚠️ 关键注释：source加载模式禁止自动运行main，由 diy‑part1 手动调用业务函数
# main "$@"
