#!/bin/bash

# feeds扩展内容
export repos=(
  "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main"
  "src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git;main"
  "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main"
  "src-git OpenClash https://github.com/vernesong/OpenClash;master"
  "src-git ghfu https://github.com/seaks/openwrt-ghfu.git;main"
  "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
  "src-git helloworld https://github.com/fw876/helloworld.git;dev"
  "src-git small https://github.com/kenzok8/small"

)

# 自定义软件包列表
clone_custom_packages () {
    local path="package/custom_packages/"

    if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
        PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
    else
        PATCHES_SRC_DIR="../OpenWrtAction"
    fi

    # 克隆失败重试：任一包拉不下来都要明确报错，不能静默生成缺包配置
    clone_with_retry() {
        local url="$1" dest="$2" name="$3" i rc=0
        for i in 1 2 3 4 5; do
            echo "clone $name (第 $i 次)..."
            if git clone --depth 1 "$url" "$dest"; then
                return 0
            fi
            rc=$?
            rm -rf "$dest"
            sleep $((RANDOM % 5 + 3))
        done
        echo "!!! $name 克隆失败(rc=$rc): $url" >&2
        return 1
    }

    # 存在才 sed，避免 clone 改名/失败后 sed -i 报错
    sed_version() {
        if [ -f "$1" ]; then
            sed -i '/^[[:blank:]]*PKG_VERSION:=/ s/\(PKG_VERSION:=[[:blank:]]*\)[^0-9.]*\([0-9.]*\)[^0-9.]*/\1\2/' "$1"
        else
            echo "⚠️ 跳过 PKG_VERSION 处理，文件不存在: $1"
        fi
    }

    rm -rf "${path}"
    mkdir -p "${path}"

    # 主题
    clone_with_retry https://github.com/seaks/luci-theme-argon.git "${path}luci-theme-argon" "luci-theme-argon" || return 1
    clone_with_retry https://github.com/anothaDev/luci-theme-vantage.git "${path}luci-theme-vantage" "luci-theme-vantage" || return 1

    # 该主题 Makefile 使用相对路径 ../../luci.mk, 在 package/custom_packages 下无法找到, 改为 feeds 中的路径
    # sed -i 's#^include[[:blank:]]\+\.\./\.\./luci\.mk#include $(TOPDIR)/feeds/luci/luci.mk#' "${path}luci-theme-ctmodem/luci-theme-ctmodem/Makefile"

    clone_with_retry https://github.com/sbwml/luci-app-mosdns -b v5 "${path}mosdns" "mosdns" || return 1

    clone_with_retry https://github.com/sirpdboy/netspeedtest.git "${path}netspeedtest" "netspeedtest" || return 1

    clone_with_retry https://github.com/timsaya/openwrt-bandix.git "${path}openwrt-bandix" "openwrt-bandix" || return 1
    clone_with_retry https://github.com/timsaya/luci-app-bandix.git "${path}luci-app-bandix" "luci-app-bandix" || return 1

    # argon 是 seaks 的 fork，版本号可能带 commit 串，规范化成纯数字
    sed_version "${path}luci-theme-argon/Makefile"

    #-------------------------------------------取消默认主题自动设置------------------------------------------
    local target='luci\.main\.mediaurlbase='

    echo "开始全量扫描并注释目标字符串, 取消主题自动设置为默认主题..."
    # -print0 + read -d '' : 兼容含空格/换行的路径
    find "$path" -type f \( -name "Makefile" -o -path "*/etc/uci-defaults/*" \) -print0 |
    while IFS= read -r -d '' file; do
        # Makefile 里该行行首可能是 Tab 或空格，用 [[:blank:]]* 兼容
        if grep -q "$target" "$file"; then
            echo "命中目标: $file"
            sed -i "/$target/s/^\([[:blank:]]*\)\([^#[:blank:]]\)/\1# \2/" "$file"
        fi
    done

    echo "注释处理完成。"
    #-------------------------------------------end取消默认主题自动设置------------------------------------------

    #-------------------------------------------设置默认主题------------------------------------------
    # 1. 确保构建根目录下的自定义文件路径存在
    mkdir -p files/etc/uci-defaults
    # 2. 将主题设置脚本写入到 zz-set-default-theme 文件中
    #    文本全部顶格写，防止 #!/bin/sh 前面产生空格
cat << "EOF" > files/etc/uci-defaults/zz-set-default-theme
#!/bin/sh

# 强制覆写节点，不判断任何条件，设置默认主题

# 设置默认主题为 Argon
 uci set luci.themes.Argon=/luci-static/argon
 uci set luci.main.mediaurlbase=/luci-static/argon
 uci commit luci

# 设置默认主题为 vantage
# uci set luci.themes.Vantage=/luci-static/vantage
# uci set luci.main.mediaurlbase=/luci-static/vantage
# uci commit luci

exit 0
EOF

    # 3. 赋予可执行权限（否则不会在开机执行）
    chmod +x files/etc/uci-defaults/zz-set-default-theme

    echo "默认主题设置已生成！"
    #-------------------------------------------end设置默认主题------------------------------------------
}
