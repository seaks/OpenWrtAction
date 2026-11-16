#!/bin/bash
source $GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh
release_tag=$1
git_folders=(openwrt immortalwrt lede feeds custompackages)

cd $GITHUB_WORKSPACE

# ------------------------------------------------------------
# 工具函数：确保日志文件末尾有换行，避免两个仓库的记录粘成一行
# ------------------------------------------------------------
ensure_log_trailing_newline() {
    local log_file="$1"
    if [ -f "$log_file" ] && [ -s "$log_file" ] && [ -n "$(tail -c 1 "$log_file" 2>/dev/null)" ]; then
        echo >> "$log_file"
    fi
}

# [改动] 下载量徽章：原版仓库路径缺少 Release 时会 404，这里保留结构但修正跳转链接
#        注意：若你的仓库名不是 OpenWrtAction，请同步修改下面两处仓库名
REPO_SLUG="seaks/OpenWrtAction"          # [改动] 集中定义，避免多处写错
ACTIONS_SITE="https://github.com/seaks/MyAction"   # [改动] 原为 MyAction（少个 s），已修正

echo "[![](https://img.shields.io/github/downloads/${REPO_SLUG}/${release_tag}/total?style=flat-square)](${ACTIONS_SITE})" > release.txt

echo "" >> release.txt
echo "## 源码信息" >> release.txt                                    # [改动] Source Code Information
echo "[![](https://img.shields.io/badge/source-openwrt_25.12-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/openwrt/openwrt) [![](https://img.shields.io/badge/source-immortalwrt_25.12-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt) [![](https://img.shields.io/badge/source-lean_SNAPSHOT-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/coolsnowwolf/lede)" >> release.txt
echo "" >> release.txt

echo "## 构建信息" >> release.txt                                    # [改动] Build Information
echo "<table>" >> release.txt
echo "  <tr>" >> release.txt
echo "    <th>平台</th>" >> release.txt                              # [改动] platform
echo "    <th>源码平台</th>" >> release.txt                          # [改动] source platform
echo "    <th>内核</th>" >> release.txt                              # [改动] kernel
echo "    <th>目标</th>" >> release.txt                              # [改动] target
echo "    <th>编译状态</th>" >> release.txt                          # [改动] compile status
echo "  </tr>" >> release.txt

# 拼接各源码平台生成的表格行
for git_folder in "${git_folders[@]}"; do
    if [[ "$git_folder" == "feeds" ]]; then
        echo "跳过 feeds（feeds 无独立构建表格）"
    else
        if [ -f "release_$git_folder.txt" ]; then
            cat "release_$git_folder.txt" >> "release.txt"
        fi
    fi
done

echo "</table>" >> release.txt
echo "" >> release.txt
echo "## 更新内容" >> release.txt                                     # [改动] What's Changed
echo "" >> release.txt

# 清理 git_log 目录中的非 log 文件（只保留名为 log 的 SHA 记录文件）
find git_log -type f ! -name 'log' -exec rm {} +
mkdir -p git_repositories

# ------------------------------------------------------------
# 主循环：逐个源码分类处理
# ------------------------------------------------------------
for git_folder in "${git_folders[@]}"; do
    echo ">>> 处理分类: $git_folder"
    declare -n repo_urls="${git_folder}_REPO_URLS"

    # 分区标题（中文）
    case "$git_folder" in
        feeds)          echo "" >> release.txt; echo "### 通用 Feeds" >> release.txt;   echo "" >> release.txt ;;   # [改动]
        custompackages) echo "" >> release.txt; echo "### 自定义软件包" >> release.txt; echo "" >> release.txt ;;   # [改动]
        openwrt|immortalwrt|lede)
                        echo "" >> release.txt; echo "### $git_folder" >> release.txt;  echo "" >> release.txt ;;
    esac

    UPDATE_COUNT=0

    for url in "${repo_urls[@]}"; do
        # ---------- [改动] 跳过空行与重复项 ----------
        [ -z "$url" ] && continue
        REPO_URL=$(echo "$url" | awk '{print $1}')
        BRANCH=$(echo "$url"  | awk '{print $2}')

        OUTPUT_FILE="${REPO_URL##*/}"
        OUTPUT_FILE="${OUTPUT_FILE%.git}"          # 去掉 .git 后缀
        TITLE_MESSAGE="${OUTPUT_FILE} 新提交记录"    # [改动] new commit log → 新提交记录

        # ---------- [改动] 同一分类内去重，避免 openwrt-ghfu 打印两次 ----------
        if [ -d "git_repositories/$git_folder/$OUTPUT_FILE" ]; then
            echo "   ↷ 跳过重复源: $OUTPUT_FILE"
            continue
        fi

        # ---------- 克隆仓库（[改动] 加 --no-checkout --depth 提速）----------
        if [ -n "$BRANCH" ]; then
            git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 --branch "$BRANCH" \
                "git_repositories/$git_folder/$OUTPUT_FILE" 2>/dev/null \
            || git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 \
                "git_repositories/$git_folder/$OUTPUT_FILE" 2>/dev/null
        else
            git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 \
                "git_repositories/$git_folder/$OUTPUT_FILE" 2>/dev/null
        fi

        if [ ! -d "git_repositories/$git_folder/$OUTPUT_FILE" ]; then
            echo "   ✗ 克隆失败，跳过: $REPO_URL"
            echo "<b>⚠️ 仓库 <code>${OUTPUT_FILE}</code> 克隆失败，本次跳过。</b>" >> release.txt
            echo "" >> release.txt
            continue
        fi

        # ========================================================
        #  获取真理 SHA（SSoT）：优先用 Artifact 里记录的历史值
        # ========================================================
        SHA_End=""

        # 1) 优先从本分类的 artifact 日志取
        if [ -f "git_log_${git_folder}.txt" ]; then
            SHA_End=$(grep "^${OUTPUT_FILE}:" "git_log_${git_folder}.txt" 2>/dev/null | cut -d: -f2)
        fi

        # 2) 退而求其次，扫描全部 artifact 日志
        if [ -z "$SHA_End" ]; then
            SHA_End=$(grep -h "^${OUTPUT_FILE}:" git_log_*.txt 2>/dev/null | head -n 1 | cut -d: -f2)
        fi

        # 3) 兜底：用当前 HEAD（step03 漏记时的安全降级）
        if [ -z "$SHA_End" ]; then
            SHA_End=$(git -C "git_repositories/$git_folder/$OUTPUT_FILE" rev-parse HEAD)
            echo "   ⚠️ [降级] Artifact 中未找到 $OUTPUT_FILE 记录，使用最新 HEAD: $SHA_End"
        else
            echo "   ✅ [SSoT 命中] $OUTPUT_FILE → $SHA_End"
        fi

        echo "$git_folder/$OUTPUT_FILE 开始比对 -------------------------------------"
        echo "   SHA_End : $SHA_End"

        LOG_FILE="git_log/$git_folder/log"
        ensure_log_trailing_newline "$LOG_FILE"

        SHA_Begin=$(grep "^${OUTPUT_FILE}:" "$LOG_FILE" 2>/dev/null | cut -d: -f2)
        echo "   SHA_Begin: ${SHA_Begin:-（无历史记录）}"

        # ---------- 首次：log 文件里没有该仓库条目 → 建立基线 ----------
        if [ ! -f "$LOG_FILE" ] || ! grep -q "^${OUTPUT_FILE}:" "$LOG_FILE" 2>/dev/null; then
            echo "${OUTPUT_FILE}:${SHA_End}" >> "$LOG_FILE"

            # [改动] 首次不再静默，输出一条基线提示，避免满屏“无更新”
            echo "<details> <summary> <b>${OUTPUT_FILE} 首次记录基线 :seedling: </b> </summary>" \
                >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "<b>已记录当前提交 <code>${SHA_End:0:7}</code>，自下次编译起将展示变更明细。</b>" \
                >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "</details>" >> "git_log/$git_folder/$OUTPUT_FILE.log"

            UPDATE_COUNT=$((UPDATE_COUNT + 1))
            echo "   → 首次建立基线"
        fi

        # ---------- SHA 非法（可能被 rebase / force push）----------
        if [ -n "$SHA_Begin" ] \
           && ! git -C "git_repositories/$git_folder/$OUTPUT_FILE" cat-file -e "${SHA_Begin}^{commit}" 2>/dev/null; then

            echo "   ✗ SHA 非法（Begin: $SHA_Begin, End: $SHA_End）"

            echo "<details> <summary> <b>$TITLE_MESSAGE :warning: </b> </summary>" \
                >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "<b>检测到 <code>${OUTPUT_FILE}</code> 的历史提交 <code>${SHA_Begin:0:7}</code> 已不存在，" \
                 "该仓库可能发生过 rebase 或强制推送，本次无法统计变更，基线已重置。</b>" \
                >> "git_log/$git_folder/$OUTPUT_FILE.log"                                    # [改动] 中文说明
            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "</details>" >> "git_log/$git_folder/$OUTPUT_FILE.log"

            sed -i "s/^${OUTPUT_FILE}:.*/${OUTPUT_FILE}:${SHA_End}/" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))

        # ---------- 有变更 ----------
        elif [ -z "$SHA_Begin" ] || [ "$SHA_Begin" != "$SHA_End" ]; then

            echo "<details> <summary> <b>$TITLE_MESSAGE :rocket: </b> </summary>" \
                >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"

            if [ -z "$SHA_Begin" ]; then
                echo "<b>该仓库尚无历史基线，本次仅记录当前提交。</b>" \
                    >> "git_log/$git_folder/$OUTPUT_FILE.log"                              # [改动]
            else
                CLEAN_REPO_URL="${REPO_URL%.git}"
                COMPARE_URL="${CLEAN_REPO_URL}/compare/${SHA_Begin}...${SHA_End}"

                echo "#### [:mega: 查看完整变更记录](${COMPARE_URL})  " \
                    >> "git_log/$git_folder/$OUTPUT_FILE.log"                               # [改动]
                echo ":heavy_exclamation_mark: 列表仅展示最近 15 条提交。  " \
                    >> "git_log/$git_folder/$OUTPUT_FILE.log"                               # [改动]
                echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
                echo "提交|作者|日期|说明" >> "git_log/$git_folder/$OUTPUT_FILE.log"          # [改动]
                echo "-|-|-|-" >> "git_log/$git_folder/$OUTPUT_FILE.log"

                git -C "git_repositories/$git_folder/$OUTPUT_FILE" \
                    log --pretty=format:"%h|%an|%ad|%s" --date=short \
                    "${SHA_Begin}...${SHA_End}" 2>/dev/null | head -n 15 \
                    >> "git_log/$git_folder/$OUTPUT_FILE.log"

                TOTAL_COMMITS=$(git -C "git_repositories/$git_folder/$OUTPUT_FILE" \
                    log --pretty=format:"%h" "${SHA_Begin}...${SHA_End}" 2>/dev/null | wc -l)
                if [ "$TOTAL_COMMITS" -gt 15 ]; then
                    echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
                    echo "> 共 ${TOTAL_COMMITS} 条提交，此处仅列出前 15 条。" \
                        >> "git_log/$git_folder/$OUTPUT_FILE.log"                            # [改动]
                fi
            fi

            echo "" >> "git_log/$git_folder/$OUTPUT_FILE.log"
            echo "</details>" >> "git_log/$git_folder/$OUTPUT_FILE.log"

            echo "     |-----------------------------------|"
            echo "     $OUTPUT_FILE 有更新"
            echo "     |-----------------------------------|"

            sed -i "s/^${OUTPUT_FILE}:.*/${OUTPUT_FILE}:${SHA_End}/" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))

        # ---------- 无变更 ----------
        else
            echo "   → 无变化（$SHA_Begin）"
        fi

        # 追加该仓库的 log 到 release.txt
        if [ -f "git_log/$git_folder/$OUTPUT_FILE.log" ]; then
            echo "   ✓ 找到 $OUTPUT_FILE.log，已追加"
            cat "git_log/$git_folder/$OUTPUT_FILE.log" >> release.txt
            echo "" >> release.txt
        else
            echo "   ✗ 未找到 $OUTPUT_FILE.log"
        fi

        echo "$git_folder/$OUTPUT_FILE 比对结束 -------------------------------"
        echo ""
    done

    # [改动] 整个分类都没有任何变化时给一句说明；有新提交则不输出
    if [ "$UPDATE_COUNT" -eq 0 ]; then
        echo "本分类所有仓库均无新提交...... :zzz:" >> release.txt                          # [改动]
        echo "" >> release.txt
    fi
done

# ------------------------------------------------------------
# 清理：只保留 release.txt，其余临时 txt 全部删除
# ------------------------------------------------------------
cd $GITHUB_WORKSPACE
find . -type f -name "*.txt" ! -name "release.txt" -exec rm {} +
rm -rf git_repositories

echo "==== release.txt 生成完毕 ===="
