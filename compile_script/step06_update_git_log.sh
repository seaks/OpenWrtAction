#!/bin/bash
# =============================================================================
# 生成 release.txt：源码信息 + 编译信息 + 各仓库更新日志
#
# 用法： gen_release_log.sh <release_tag>
#
# 核心逻辑（SSoT 修正版）：
#   SHA_Begin = 上次记录（本地 git_log/<folder>/log）
#   SHA_End   = 本次 clone 的真实 HEAD   ← 关键，不能取自 artifact
#   artifact 里的 git_log_<folder>.txt 只在本地 log 丢失时用作兜底基准
# =============================================================================

set -uo pipefail

source "$GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh"

release_tag="${1:-}"
if [ -z "$release_tag" ]; then
    echo "❌ 缺少 release_tag 参数" >&2
    exit 1
fi

git_folders=(immortalwrt_master immortalwrt_snapshot feeds custompackages)

cd "$GITHUB_WORKSPACE" || exit 1

# ---- 全局去重（原来声明了 seen_title 却用 seen_repo，这里统一） ----
declare -A seen_repo=()

# ---- 只显示最新 N 条提交 ----
LOG_LIMIT=15

# =============================================================================
# 工具函数
# =============================================================================

# 确保日志文件以换行结尾，避免两个仓库内容黏在同一行
ensure_log_trailing_newline() {
    local log_file="$1"
    if [ -f "$log_file" ] && [ -s "$log_file" ] && [ -n "$(tail -c 1 "$log_file" 2>/dev/null)" ]; then
        echo >> "$log_file"
    fi
}

# 安全读取某个仓库上次记录的 SHA
# 参数：$1=log 文件  $2=仓库名
read_recorded_sha() {
    local log_file="$1" repo_name="$2"
    [ -f "$log_file" ] || return 0
    grep "^${repo_name}:" "$log_file" 2>/dev/null | tail -n 1 | cut -d: -f2
}

# 校验 SHA 在仓库里是否真实存在（防止 rebase / force push 后失效）
sha_exists() {
    local repo_dir="$1" sha="$2"
    [ -n "$sha" ] || return 1
    git -C "$repo_dir" cat-file -t "$sha" >/dev/null 2>&1
}

# =============================================================================
# 初始化 release.txt
# =============================================================================

{
    echo "[![](https://img.shields.io/github/downloads/seaks/OpenWrtAction/${release_tag}/total?style=flat-square)](https://github.com/seaks/OpenWrtAction)"
    echo ""
    echo "## 源码信息"
    echo "[![](https://img.shields.io/badge/source-immortalwrt_master-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt) [![](https://img.shields.io/badge/source-immortalwrt_snapshot-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt/tree/openwrt-25.12)"
    echo ""
    echo "## 编译信息"
    echo "<table>"
    echo "  <tr>"
    echo "    <th>版本</th><th>源码</th><th>内核</th><th>机型</th><th>编译状态</th>"
    echo "  </tr>"
} > release.txt

# 汇总各平台的编译信息表格
for git_folder in "${git_folders[@]}"; do
    if [[ "$git_folder" == "feeds" ]]; then
        echo "jump $git_folder"
        continue
    fi
    if [ -f "release_${git_folder}.txt" ]; then
        cat "release_${git_folder}.txt" >> release.txt
    fi
done

{
    echo "</table>"
    echo ""
    echo "## 更新记录"
    echo ""
} >> release.txt

# =============================================================================
# 准备工作目录
#   git_log/        持久化的 SHA 记录（会作为 artifact 上传，供下次比对）
#   git_repositories/  临时 clone 目录
# =============================================================================

# 清理 git_log 目录中的非 log 文件（保留名为 log 的记录文件）
# ⚠️ 只删文件、不动目录：artifact 恢复下来的子目录结构必须保留，
#    否则下面 LOG_FILE 写入会因目录不存在而静默失败
if [ -d git_log ]; then
    find git_log -mindepth 2 -type f ! -name 'log' -delete 2>/dev/null || true
fi
# 确保每个平台的子目录都存在（首次运行 / artifact 未覆盖时兜底）
for _f in "${git_folders[@]}"; do
    mkdir -p "git_log/${_f}"
done
mkdir -p git_repositories

# =============================================================================
# 主循环
# =============================================================================

for git_folder in "${git_folders[@]}"; do
    echo "==================== git_folder: $git_folder ===================="

    # nameref 指向 URL 列表数组，例如 immortalwrt_master_REPO_URLS
    declare -n repo_urls="${git_folder}_REPO_URLS"

    if [[ "$git_folder" == "feeds" ]]; then
        { echo ""; echo "### FEEDS 源更新日志"; echo ""; } >> release.txt
    elif [[ "$git_folder" == "custompackages" ]]; then
        { echo ""; echo "### 软件包更新日志"; echo ""; } >> release.txt
    elif [[ "$git_folder" == "immortalwrt_master" || "$git_folder" == "immortalwrt_snapshot" ]]; then
        { echo ""; echo "### ${git_folder}"; echo ""; } >> release.txt
    fi

    UPDATE_COUNT=0

    for url in "${repo_urls[@]}"; do
        REPO_URL=$(echo "$url" | awk '{print $1}')
        BRANCH=$(echo "$url" | awk '{print $2}')

        OUTPUT_FILE="${REPO_URL##*/}"
        OUTPUT_FILE="${OUTPUT_FILE%.git}"      # 去掉 .git 后缀
        OUTPUT_FILE="${OUTPUT_FILE%.git/}"     # 兼容末尾带斜杠的写法
        TITLE_MESSAGE="${OUTPUT_FILE} 更新日志"

        # ---------------- 去重 ----------------
        if [[ -n "${seen_repo[$OUTPUT_FILE]:-}" ]]; then
            echo "⏭️  Skip duplicate repo: $OUTPUT_FILE"
            continue
        fi
        seen_repo["$OUTPUT_FILE"]=1

        # ---------------- clone ----------------
        #   tree:0 只拉 commit 图，不拉 tree/blob。
        #   本脚本只用 git log，这样最快；若后续要用 diff --stat 需改回 blob:none
        clone_dir="git_repositories/${git_folder}/${OUTPUT_FILE}"
        if [ -n "$BRANCH" ]; then
            if ! git clone --filter=tree:0 --branch "$BRANCH" "$REPO_URL" "$clone_dir" >/dev/null 2>&1; then
                echo "❌ clone 失败，跳过：$REPO_URL ($BRANCH)"
                continue
            fi
        else
            if ! git clone --filter=tree:0 "$REPO_URL" "$clone_dir" >/dev/null 2>&1; then
                echo "❌ clone 失败，跳过：$REPO_URL"
                continue
            fi
        fi

        echo "$git_folder-$OUTPUT_FILE Begin git log update -------------------"

        # =====================================================================
        # ★ 核心修正：SHA_End 取本次 clone 的真实 HEAD
        # =====================================================================
        SHA_End=$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)
        if [ -z "$SHA_End" ]; then
            echo "   ❌ 无法取得 HEAD，跳过：$OUTPUT_FILE"
            continue
        fi
        echo "   🔭 远端当前 HEAD: $SHA_End"

        # ---- SHA_Begin：优先本地持久记录 ----
        LOG_FILE="git_log/${git_folder}/log"
        mkdir -p "$(dirname "$LOG_FILE")"      # 双保险：目录不存在则建
        ensure_log_trailing_newline "$LOG_FILE"
        SHA_Begin=$(read_recorded_sha "$LOG_FILE" "$OUTPUT_FILE")
        echo "   📒 本地记录 SHA : ${SHA_Begin:-（无）}"

        # ---- 本地记录缺失时，用 artifact 里的历史记录兜底 ----
        if [ -z "$SHA_Begin" ]; then
            ARTIFACT_LOG="git_log_${git_folder}.txt"
            if [ -f "$ARTIFACT_LOG" ]; then
                _prev=$(grep "^${OUTPUT_FILE}:" "$ARTIFACT_LOG" 2>/dev/null | tail -n 1 | cut -d: -f2)
                if sha_exists "$clone_dir" "$_prev"; then
                    SHA_Begin="$_prev"
                    echo "   ↩️  本地记录缺失，沿用 artifact 基准: $SHA_Begin"
                elif [ -n "$_prev" ]; then
                    echo "   ⚠️  artifact 基准 $_prev 在仓库中已不存在（可能 rebase），按首次记录处理"
                fi
            fi
        fi

        # ---- 兼容首次运行：写入基准并在 release 里标注 ----
        FIRST_RUN=0
        if [ ! -f "$LOG_FILE" ] || ! grep -q "^${OUTPUT_FILE}:" "$LOG_FILE" 2>/dev/null; then
            FIRST_RUN=1
        fi

        # ---- 分支 A：SHA_Begin 失效（rebase / force push）----
        if [ -n "$SHA_Begin" ] && ! sha_exists "$clone_dir" "$SHA_Begin"; then
            echo "   ⚠️  Invalid SHA (Begin: $SHA_Begin) — 疑似 rebase / force push"
            {
                echo "<details> <summary> <b>${TITLE_MESSAGE} :x: </b> </summary>"
                echo ""
                echo "<b> 检测到 ${OUTPUT_FILE} 的历史 SHA 已不存在（可能发生了 rebase 或 force push），本次无法统计增量日志，已重置基准，下次编译恢复。</b>"
                echo ""
                echo "</details>"
                echo ""
            } >> "git_log/${git_folder}/${OUTPUT_FILE}.log"

        # ---- 分支 B：有新提交 ----
        elif [ -z "$SHA_Begin" ] || [ "$SHA_Begin" != "$SHA_End" ]; then
            {
                echo "<details> <summary> <b>${TITLE_MESSAGE} :rocket: </b> </summary>"
                echo ""
            } >> "git_log/${git_folder}/${OUTPUT_FILE}.log"

            if [ "$FIRST_RUN" = "1" ] || [ -z "$SHA_Begin" ]; then
                echo "<b>首次记录 ${OUTPUT_FILE}，已建立基准，后续编译将显示增量日志。</b>" \
                    >> "git_log/${git_folder}/${OUTPUT_FILE}.log"
            else
                CLEAN_REPO_URL="${REPO_URL%.git}"
                COMPARE_URL="${CLEAN_REPO_URL}/compare/${SHA_Begin}...${SHA_End}"
                {
                    echo "#### [:mega: 更新日志.](${COMPARE_URL})  "
                    echo ":heavy_exclamation_mark: 列表仅显示最新的 ${LOG_LIMIT} 条提交日志。  "
                    echo ""
                    echo "SHA|Author|Date|Message"
                    echo "-|-|-|-"
                } >> "git_log/${git_folder}/${OUTPUT_FILE}.log"

                # 只跑一次 git log，结果复用（原来跑了两次）
                COMMITS=$(git -C "$clone_dir" \
                    log --no-merges --pretty=format:'%h|%an|%ad|%s' --date=short \
                    "${SHA_Begin}...${SHA_End}" 2>/dev/null || true)

                if [ -n "$COMMITS" ]; then
                    echo "$COMMITS" | head -n "$LOG_LIMIT" >> "git_log/${git_folder}/${OUTPUT_FILE}.log"
                    TOTAL=$(echo "$COMMITS" | wc -l)
                    if [ "$TOTAL" -gt "$LOG_LIMIT" ]; then
                        echo "" >> "git_log/${git_folder}/${OUTPUT_FILE}.log"
                        echo "> 共 ${TOTAL} 条提交，仅展示前 ${LOG_LIMIT} 条，[查看完整对比](${COMPARE_URL})。" \
                            >> "git_log/${git_folder}/${OUTPUT_FILE}.log"
                    fi
                else
                    echo "| - | - | - | 区间内无可展示提交（可能为分支回退） |" \
                        >> "git_log/${git_folder}/${OUTPUT_FILE}.log"
                fi
            fi

            {
                echo ""
                echo "</details>"
                echo ""
            } >> "git_log/${git_folder}/${OUTPUT_FILE}.log"

            echo "     |-----------------------------------|"
            echo "     $OUTPUT_FILE has update"
            echo "     |-----------------------------------|"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))

        # ---- 分支 C：真的没更新 ----
        else
            echo "     💤 no new commits"
        fi

        # ---- 无论哪种情况，都把基准推进到本次 HEAD ----
        if [ -n "$SHA_End" ]; then
            if grep -q "^${OUTPUT_FILE}:" "$LOG_FILE" 2>/dev/null; then
                sed -i "s|^${OUTPUT_FILE}:.*|${OUTPUT_FILE}:${SHA_End}|" "$LOG_FILE"
            else
                echo "${OUTPUT_FILE}:${SHA_End}" >> "$LOG_FILE"
            fi
        fi

        # ---- 追加到 release.txt ----
        if [ -f "git_log/${git_folder}/${OUTPUT_FILE}.log" ]; then
            echo "   found file ${OUTPUT_FILE}.log"
            cat "git_log/${git_folder}/${OUTPUT_FILE}.log" >> release.txt
        else
            echo "   no file ${OUTPUT_FILE}.log"
        fi

        echo "$git_folder-$OUTPUT_FILE complete -------------------------------"
        echo ""
    done

    if [ "$UPDATE_COUNT" -eq 0 ]; then
        echo "当前没有更新...... 💤" >> release.txt
        echo "（${git_folder}：本轮无仓库产生新提交）"
    else
        echo "（${git_folder}：${UPDATE_COUNT} 个仓库有更新）"
    fi
done

# =============================================================================
# 收尾清理
#   ⚠️ 只删主源码库的 release_*.txt，不要误删 release.txt 本身
# =============================================================================
cd "$GITHUB_WORKSPACE" || exit 0
find . -maxdepth 1 -type f -name "release_*.txt" -delete
rm -rf git_repositories

echo "✅ release.txt 生成完毕"
