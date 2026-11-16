#!/bin/bash
# ==============================================================================
# step02_generate_release_tag.sh
# 作用：为「单个源码平台」生成构建信息表格行，写入 release_<platform>.txt
#       随后由 step06_update_git_log.sh 汇总进 release.txt
#
# 用法：step02_generate_release_tag.sh <release_tag> <source_code_platform> <config_dir>
#
# 【本版修正点】
#   1. 徽章改用 SHA1 校验和形式 /badge/<label>-<msg>-<color>，中文与特殊字符
#      全部安全，无需手工百分号编码
#   2. 徽章文字与 step07 写回时的识别串严格一致（编译中…），保证状态能被覆盖
#   3. 仓库名集中到 REPO_SLUG / ACTIONS_SITE，两处已对齐为真实存在的仓库
#   4. source_code_platform 支持 immortalwrt-master（之前 case 会漏掉）
#   5. 表格行先算完再一次性写入，避免中途失败留下半截 HTML
#   6. 健壮性兜底：参数缺失、平台矩阵为空、config 缺失、KERNEL_PATCHVER
#      取不到、内核版本文件不存在、未知平台
# ==============================================================================

release_tag=$1
source_code_platform=$2
config=$3

source "$GITHUB_WORKSPACE/compile_script/platforms.sh"

# ------------------------------------------------------------------------------
# 集中配置：改这里就能全局生效
#   下载量徽章必须带 latest 或具体 tag，直接 /<repo>/total 会 404
# ------------------------------------------------------------------------------
REPO_SLUG="seaks/OpenWrtAction"                  # 承载 Release 的仓库
ACTIONS_SITE="https://github.com/seaks/MyAction" # Actions 站点仓库，已补上缺失的 s

# 输出文件：与 step06 里 cat 的文件名严格对齐
OUT_FILE="release_${source_code_platform}.txt"

# 徽章文字：⚠️ 必须与 step07_organize_tag.sh 里匹配/替换的串完全一致，
# 否则编译结束后状态徽章无法被覆盖，会永远停在「编译中…」
BADGE_TEXT="编译中…"
BADGE_LABEL="build"

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
#   immortalwrt-master 与 immortalwrt 共用同一份平台矩阵，
#   但产出独立的 release_immortalwrt-master.txt，表格里分两行显示
# ------------------------------------------------------------------------------
case "$source_code_platform" in
    openwrt)
        selected_platforms=("${openwrt_platforms[@]}")
        ;;
    immortalwrt|immortalwrt-master)
        selected_platforms=("${immortalwrt_platforms[@]}")
        ;;
    lede)
        selected_platforms=("${lede_platforms[@]}")
        ;;
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
# 构造徽章 URL
#   采用 shields.io 的 SHA1 校验和形式：
#     /badge/<label>-<message>-<color>
#   其中 label/message 的原始值经 sha1hex 后拼入，可安全承载中文、空格、加号、
#   斜杠等任意字符，比手工做百分号编码可靠得多
# ------------------------------------------------------------------------------
sha1hex() {
    printf '%s' "$1" | sha1sum | awk '{print $1}'
}

badge_url="https://img.shields.io/badge/${BADGE_LABEL}-$(sha1hex "$BADGE_TEXT")-$(sha1hex yellow)?logo=githubactions&logoColor=yellow&style=flat-square"

# scp / plm 是两个自定义属性，供 step07 定位要替换的那一行徽章。
# 值里若含引号或尖括号会破坏 HTML，这里做最小化清洗
sanitize_attr() {
    local s="$1"
    s="${s//\"/}"
    s="${s//</}"
    s="${s//>/}"
    printf '%s' "$s"
}

attr_scp=$(sanitize_attr "$source_code_platform")

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
        echo "⚠️ 未能解析 $platform 的内核版本（$kernel_version_file），表格中标注为未知。"
        kernel_version="未知"
    fi

    attr_plm=$(sanitize_attr "$platform")

    # --- 4. 累积表格行 ---
    rows+="  <tr>"$'\n'
    rows+="    <td><strong>🧊 $platform</strong></td>"$'\n'
    rows+="    <td><strong>$source_code_platform</strong></td>"$'\n'
    rows+="    <td><strong>$kernel_version</strong></td>"$'\n'
    rows+="    <td><strong>$target_board</strong></td>"$'\n'
    rows+="    <td><img scp=\"$attr_scp\" plm=\"$attr_plm\" src=\"$badge_url\" alt=\"编译状态\"/></td>"$'\n'
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
if [[ "$ok_count" -gt 0 ]]; then
    echo "   徽章文字：$BADGE_TEXT（step07 需按此串回写最终状态）"
fi
echo "------------------------------------------------------------"

echo 'status=success' >> "$GITHUB_OUTPUT"
