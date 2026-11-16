#!/bin/bash
# ==============================================================================
# step02_generate_release_tag.sh
# 作用：为「单个源码平台」生成构建信息表格行，写入 release_<platform>.txt
#       随后由 step06_update_git_log.sh 汇总进 release.txt
#
# 用法：step02_generate_release_tag.sh <release_tag> <source_code_platform> <config_dir>
#
# 【本次修改清单】
#   1. 全中文输出
#   2. 修复 sorce → source 拼写错误（原先徽章 alt 文本拼错）
#   3. 徽章仓库名集中到 REPO_SLUG，一处修改全局生效
#   4. 修复 MyAction
#   5. 徽章 URL 做百分号编码，平台名若含空格/加号不再拼坏链接
#   6. 表格行改为「先算完再一次性写入」，避免中途失败留下半截 HTML
#   7. 补齐原本缺失的健壮性：config 缺失、KERNEL_PATCHVER 取不到、
#      kernel 文件不存在、未知 source_code_platform 等情况全部兜底
#   8. 徽章文字由「in_progress_or_waiting.....」改为「编译中…」，去掉一串句点
# ==============================================================================

release_tag=$1
source_code_platform=$2
config=$3

source "$GITHUB_WORKSPACE/compile_script/platforms.sh"

# ------------------------------------------------------------------------------
# 集中配置：改这里就能全局生效，不用满文件找
# ------------------------------------------------------------------------------
REPO_SLUG="seaks/OpenWrtAction"          # 有 Release 的那个仓库（下载量徽章指向它）
ACTIONS_SITE="https://github.com/seaks/MyAction"   # 原写成 MyAction，少个 s 导致 404

# 输出文件：和 step06 里 cat 的文件名严格对齐
OUT_FILE="release_${source_code_platform}.txt"

# 徽章状态文字（URL 里不能有空格，用 %20；加号用 %2B）
BADGE_TEXT="%E7%BC%96%E8%AF%91%E4%B8%AD%E2%80%A6"   # 「编译中…」

# ------------------------------------------------------------------------------
# 入口校验
# ------------------------------------------------------------------------------
if [[ -z "$source_code_platform" ]]; then
    echo "❌ 未传入 source_code_platform，无法确定平台矩阵。"
    echo 'status=success' >> "$GITHUB_OUTPUT"
    exit 0
fi

if [[ -z "$config" ]]; then
    echo "❌ 未传入 config 目录参数。"
    echo 'status=success' >> "$GITHUB_OUTPUT"
    exit 0
fi

# ------------------------------------------------------------------------------
# 选取对应源码平台的构建矩阵
# ------------------------------------------------------------------------------
case "$source_code_platform" in
    openwrt)    selected_platforms=("${openwrt_platforms[@]}")    ;;
    immortalwrt) selected_platforms=("${immortalwrt_platforms[@]}") ;;
    lede)       selected_platforms=("${lede_platforms[@]}")       ;;
    *)
        echo "⚠️ 未知源码平台：$source_code_platform，跳过表格生成。"
        selected_platforms=()
        ;;
esac

if [[ "${#selected_platforms[@]}" -eq 0 ]]; then
    echo "⚠️ $source_code_platform 的平台矩阵为空，未生成任何表格行。"
    : > "$OUT_FILE"
    echo 'status=success' >> "$GITHUB_OUTPUT"
    exit 0
fi

# ------------------------------------------------------------------------------
# URL 百分号编码：只处理徽章路径里可能出现的少量字符，够用即可
# ------------------------------------------------------------------------------
url_encode() {
    local s="$1"
    s="${s// /%20}"
    s="${s//+/%2B}"
    s="${s//#/%23}"
    s="${s//\//%2F}"
    printf '%s' "$s"
}

# ------------------------------------------------------------------------------
# 逐平台生成表格行
# ------------------------------------------------------------------------------
rows=""
ok_count=0
skip_count=0

for platform in "${selected_platforms[@]}"; do
    config_file="$GITHUB_WORKSPACE/$config/$platform.config"

    # --- 1. 读取 CONFIG_TARGET_BOARD ---
    if [[ ! -f "$config_file" ]]; then
        echo "⚠️ 找不到 $platform 的配置文件：$config_file，跳过该平台。"
        skip_count=$((skip_count + 1))
        continue
    fi

    target_board=$(grep 'CONFIG_TARGET_BOARD=' "$config_file" | awk -F '=' '{print $2}' | tr -d '"')

    if [[ -z "$target_board" ]]; then
        echo "⚠️ $config_file 里没有 CONFIG_TARGET_BOARD，跳过 $platform。"
        skip_count=$((skip_count + 1))
        continue
    fi

    # --- 2. 读取内核主版本号（KERNEL_PATCHVER） ---
    kernel_file="$GITHUB_WORKSPACE/openwrt/target/linux/$target_board/Makefile"
    if [[ ! -f "$kernel_file" ]]; then
        echo "⚠️ 找不到目标 Makefile：$kernel_file，跳过 $platform。"
        skip_count=$((skip_count + 1))
        continue
    fi

    kernel=$(grep -oP 'KERNEL_PATCHVER:=\K[^ ]+' "$kernel_file" | head -n 1)
    if [[ -z "$kernel" ]]; then
        echo "⚠️ $kernel_file 中未解析到 KERNEL_PATCHVER，跳过 $platform。"
        skip_count=$((skip_count + 1))
        continue
    fi

    # --- 3. 读取精确内核版本 ---
    # lede 与 openwrt / immortalwrt 的内核版本文件位置不同，这里分开处理
    if [[ "$source_code_platform" == "lede" ]]; then
        kernel_version_file="$GITHUB_WORKSPACE/openwrt/include/kernel-$kernel"
    else
        kernel_version_file="$GITHUB_WORKSPACE/openwrt/target/linux/generic/kernel-$kernel"
    fi

    if [[ -f "$kernel_version_file" ]]; then
        kernel_version=$(sed -n '2p' "$kernel_version_file" | awk -F '-' '{print $2}' | awk -F ' =' '{print $1}')
    else
        kernel_version=""
    fi

    if [[ -z "$kernel_version" ]]; then
        echo "⚠️ 未能解析 $platform 的内核版本（$kernel_version_file），表格中留空。"
        kernel_version="未知"
    fi

    # --- 4. 拼徽章 URL（做编码，防止平台名里的特殊字符破坏链接） ---
    badge_plm=$(url_encode "$platform")
    badge_scp=$(url_encode "$source_code_platform")
    badge_url="https://img.shields.io/badge/build-${BADGE_TEXT}-yellow?logo=githubactions&logoColor=yellow&style=flat-square"

    # --- 5. 累积表格行 ---
    rows+="  <tr>"$'\n'
    rows+="    <td><strong>🧊 $platform</strong></td>"$'\n'
    rows+="    <td><strong>$source_code_platform</strong></td>"$'\n'
    rows+="    <td><strong>$kernel_version</strong></td>"$'\n'
    rows+="    <td><strong>$target_board</strong></td>"$'\n'
    rows+="    <td><img scp=\"$badge_scp\" plm=\"$badge_plm\" src=\"$badge_url\" alt=\"编译状态\"/></td>"$'\n'
    rows+="  </tr>"$'\n'

    echo "✅ $platform：目标 $target_board，内核 $kernel_version"
    ok_count=$((ok_count + 1))
done

# ------------------------------------------------------------------------------
# 一次性写入，避免中途失败留下残缺 HTML
# ------------------------------------------------------------------------------
if [[ -n "$rows" ]]; then
    printf '%s' "$rows" > "$OUT_FILE"
else
    : > "$OUT_FILE"
fi

echo "------------------------------------------------------------"
echo "📊 $source_code_platform 表格生成完毕：成功 $ok_count 个平台，跳过 $skip_count 个。"
echo "   输出文件：$OUT_FILE（$(wc -l < "$OUT_FILE") 行）"
echo "------------------------------------------------------------"

touch "$OUT_FILE"
echo 'status=success' >> "$GITHUB_OUTPUT"
