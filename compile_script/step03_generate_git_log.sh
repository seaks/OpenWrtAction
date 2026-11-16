#!/bin/bash
# =============================================================================
# step03_generate_git_log.sh —— 收集源码 SHA 指纹（真理日志）
#
# 用法: step03_generate_git_log.sh <source_code_platform>
#
# 产出: git_log_<platform>.txt
#         第一行  <platform>:<主源码 SHA>      供 step06 识别主源码基线
#         其余行  <仓库名>:<SHA>               供 step06 匹配 feeds / 自定义包
#
# 注意: 这里的 <platform> 必须和 workflow 矩阵里的 matrix.source_code_platform
#       完全一致，否则 step06 的 artifact 专属匹配会落空，退化为跨文件扫描。
# =============================================================================

source_code_platform="$1"

if [ -z "$source_code_platform" ]; then
    echo "❌ 缺少参数 source_code_platform，用法: $0 <platform>"
    echo "status=failed" >> "$GITHUB_OUTPUT"
    exit 1
fi

cd "$GITHUB_WORKSPACE" || exit 1

log_file="git_log_${source_code_platform}.txt"

# ------------------------------------------------------------
# 关键：先清空旧文件，避免同一 runner 复用或重试时反复 >> 追加
# 造成同一个仓库出现多行、step06 取到陈旧的头一行。
# ------------------------------------------------------------
: > "$log_file"

echo "==== 🔍 开始收集源码 SHA 指纹（$source_code_platform）===="

# ------------------------------------------------------------
# 1. 主源码仓库（immortalwrt_master / immortalwrt / lede 共用同一个目录名 openwrt）
# ------------------------------------------------------------
main_sha=$(git -C openwrt log -n 1 --format="%H" 2>/dev/null)

if [ -z "$main_sha" ]; then
    echo "⚠️  未能读取 openwrt/ 的 HEAD SHA（目录不存在或不是 Git 仓库）"
else
    echo "${source_code_platform}:${main_sha}" >> "$log_file"
    echo "  [主源码] ${source_code_platform}: ${main_sha}"
fi

# ------------------------------------------------------------
# 2. 动态遍历 feeds/ 与 package/ 下所有独立 Git 仓库
#    用临时文件承接 find 结果，避开管道子 shell 导致的计数丢失
# ------------------------------------------------------------
tmp_list=$(mktemp)
find openwrt/feeds openwrt/package -type d -name ".git" 2>/dev/null > "$tmp_list"

pack_count=0
skip_count=0

while read -r gitdir; do
    [ -z "$gitdir" ] && continue
    repo_dir=$(dirname "$gitdir")

    # 直接问 Git 底层要真实远端 URL（比猜目录名可靠）
    repo_url=$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null)

    if [ -z "$repo_url" ]; then
        skip_count=$((skip_count + 1))
        continue
    fi

    # 与 step06 完全一致的切割规则：取最后一段、去掉 .git
    repo_name="${repo_url##*/}"
    repo_name="${repo_name%.git}"

    # 跳过空名与 . 开头异常名
    if [ -z "$repo_name" ] || [[ "$repo_name" == .* ]]; then
        skip_count=$((skip_count + 1))
        continue
    fi

    sha=$(git -C "$repo_dir" log -n 1 --format="%H" 2>/dev/null)

    if [ -n "$sha" ]; then
        echo "${repo_name}:${sha}" >> "$log_file"
        echo "  [软件包] ${repo_name}: ${sha}"
        pack_count=$((pack_count + 1))
    else
        # 仓库存在但读不到提交（空仓库 / 浅克隆损坏）
        skip_count=$((skip_count + 1))
        echo "  ⚠️  跳过（无提交记录）: $repo_dir"
    fi
done < "$tmp_list"

rm -f "$tmp_list"

# ------------------------------------------------------------
# 去重保险：同一仓库名若因软链接/重复 feed 出现多次，只留最后一次
# （awk 保序去重，后出现的覆盖先出现的，与"最终态"一致）
# ------------------------------------------------------------
if [ -s "$log_file" ]; then
    # 两遍法：记录每个仓库名最后一次出现的完整行，按首次出现顺序输出
    awk -F: '
        { last[$1]=$0; if (!($1 in first_at)) { first_at[$1]=NR; order[NR]=$1 } }
        END {
            n=0
            for (i=1; i<=NR; i++) {
                if (i in order) {
                    k=order[i]
                    print last[k]
                }
            }
        }
    ' "$log_file" > "${log_file}.dedup"
    mv "${log_file}.dedup" "$log_file"
fi

total=$(wc -l < "$log_file")

echo "---- 汇总 ----"
echo "  主源码     : ${main_sha:-（未读取到）}"
echo "  软件包仓库 : $pack_count 个"
echo "  跳过       : $skip_count 个"
echo "  记录总行数 : $total"
echo "==== ✅ SHA 指纹收集完毕 ===="

echo "status=success" >> "$GITHUB_OUTPUT"
