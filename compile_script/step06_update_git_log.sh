#!/bin/bash
source $GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh
release_tag=$1
git_folders=( immortalwrt_master immortalwrt  feeds custompackages)

cd $GITHUB_WORKSPACE

# Ensure the log file ends with a newline before appending new entries.
# This prevents two repos from being concatenated into one line.
ensure_log_trailing_newline() {
    local log_file="$1"
    if [ -f "$log_file" ] && [ -s "$log_file" ] && [ -n "$(tail -c 1 "$log_file" 2>/dev/null)" ]; then
        echo >> "$log_file"
    fi
}

# 初始化 release.txt
echo "[![](https://img.shields.io/github/downloads/seaks/OpenWrtAction/$release_tag/total?style=flat-square)](https://github.com/seaks/MyAction)"> release.txt

echo "">> release.txt
echo "## 源代码信息">> release.txt
echo "[![](https://img.shields.io/badge/source-immortalwrt_master-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt) [![](https://img.shields.io/badge/source-immortalwrt_25.12-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt)">> release.txt
echo "">>release.txt
echo "## 编译信息">> release.txt

echo "<table>">>release.txt
echo "  <tr>">>release.txt
echo "    <th>平台</th>">>release.txt
echo "    <th>源码平台</th>">>release.txt
echo "    <th>内核</th>">>release.txt
echo "    <th>机型</th>">>release.txt
echo "    <th>编译状态</th>">>release.txt
echo "  </tr>">>release.txt

for git_folder in "${git_folders[@]}"; do
    if [[ "$git_folder" == "feeds" ]]; then
        echo "jump $git_folder"
    else
        if [ -f "release_$git_folder.txt" ]; then
            cat "release_$git_folder.txt" >> "release.txt"
        fi
    fi
done
echo "</table>">>release.txt
echo "">>release.txt
echo "## 更新记录" >>release.txt
echo "">>release.txt

# 清理 git_log 目录中的非 log 文件
find git_log -type f ! -name 'log' -exec rm {} +
mkdir -p git_repositories

for git_folder in "${git_folders[@]}"; do
    echo "git_folder: $git_folder"
    declare -n repo_urls="${git_folder}_REPO_URLS"

    if [[ "$git_folder" == "feeds" ]]; then
        echo "">>release.txt
        echo "### feeds更新记录" >>release.txt
        echo "">>release.txt
    fi
    if [[ "$git_folder" == "custompackages" ]]; then
        echo "">>release.txt
        echo "### 软件包更新记录" >>release.txt
        echo "">>release.txt
    fi
    if [[ "$git_folder" == "immortalwrt_master" || "$git_folder" == "immortalwrt" || "$git_folder" == "lede" ]]; then
        echo "">>release.txt
        echo "### $git_folder" >>release.txt
        echo "">>release.txt
    fi

    UPDATE_COUNT=0
    for url in "${repo_urls[@]}"; do
        # 分离 URL 和分支
        REPO_URL=$(echo "$url" | awk '{print $1}')
        BRANCH=$(echo "$url" | awk '{print $2}')
        OUTPUT_FILE="${REPO_URL##*/}"
        OUTPUT_FILE="${OUTPUT_FILE%.git}"  # 移除.git后缀
        TITLE_MESSAGE="${OUTPUT_FILE} 新提交日志"

        # 克隆仓库
        if [ -n "$BRANCH" ]; then
            git clone "$REPO_URL" --filter=blob:none --branch "$BRANCH" "git_repositories/$git_folder/$OUTPUT_FILE"
        else
            git clone "$REPO_URL" --filter=blob:none "git_repositories/$git_folder/$OUTPUT_FILE"
        fi

        # ==========================================
        # 👑 核心一致性改造：获取基准提交哈希 (单一可信源原则)
        # 不再盲目使用远端 HEAD，强制校验构建产物里的历史记录
        # ==========================================
        SHA_End=""
        
        # 1. 优先尝试从对应平台的产物日志中提取 (针对主源码库)
        if [ -f "git_log_${git_folder}.txt" ]; then
            SHA_End=$(grep "^${OUTPUT_FILE}:" "git_log_${git_folder}.txt" 2>/dev/null | cut -d: -f2)
        fi
        
        # 2. 如果没找到，扫描所有下载下来的产物日志匹配 (针对 feeds 和 custompackages)
        if [ -z "$SHA_End" ]; then
            SHA_End=$(grep -h "^${OUTPUT_FILE}:" git_log_*.txt 2>/dev/null | head -n 1 | cut -d: -f2)
        fi

        # 3. 防呆兜底：如果步骤03真的漏了，安全降级使用最新 HEAD 防止脚本崩溃
        if [ -z "$SHA_End" ]; then
            SHA_End=$(git -C "git_repositories/$git_folder/$OUTPUT_FILE" rev-parse HEAD)
            echo "   ⚠️ [降级兜底] 未在构建产物中找到 $OUTPUT_FILE 记录，使用远端最新 HEAD: $SHA_End"
        else
            echo "   ✅ [单一可信源匹配成功] 锁定基准提交哈希 ($OUTPUT_FILE): $SHA_End"
        fi
        # ==========================================

        echo "$git_folder-$OUTPUT_FILE 开始更新提交日志-----------------------------------------------------------"
        echo "结束哈希:$SHA_End"

        LOG_FILE="git_log/$git_folder/log"
        ensure_log_trailing_newline "$LOG_FILE"

        # 检查 log 文件是否存在且是否包含 OUTPUT_FILE 条目
        SHA_Begin=$(grep "^${OUTPUT_FILE}:" "$LOG_FILE" | cut -d: -f2)
        echo "起始哈希:$SHA_Begin"

        # 如果 log 文件不存在或为空，或者没有 OUTPUT_FILE 条目，初始化 log 文件
        if [ ! -f "$LOG_FILE" ] || ! grep -q "^${OUTPUT_FILE}:" "$LOG_FILE"; then
            echo "${OUTPUT_FILE}:${SHA_End}" >> "$LOG_FILE"
            SHA_Begin=""
        fi

        # 检查 SHA 是否有效
        if ! git -C "git_repositories/$git_folder/$OUTPUT_FILE" cat-file -t "$SHA_Begin" >/dev/null 2>&1 && [ -n "$SHA_Begin" ]; then
            echo "     :x: 检测到无效哈希 (起始: $SHA_Begin, 结束: $SHA_End) 仓库: $OUTPUT_FILE"
            echo "<details> <summary> <b>$TITLE_MESSAGE :x: </b> </summary>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "<b>检测到 $OUTPUT_FILE 存在非法提交哈希，该仓库大概率发生了 git 变基操作，本次无法统计更新记录，请等待下次编译。</b>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "</details>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            sed -i "s/^${OUTPUT_FILE}:.*/${OUTPUT_FILE}:${SHA_End}/" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))
        elif [ -z "$SHA_Begin" ] || [ "$SHA_Begin" != "$SHA_End" ]; then
            echo "<details> <summary> <b>$TITLE_MESSAGE :rocket: </b> </summary>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            if [ -z "$SHA_Begin" ]; then
                echo "<b>首次记录 $OUTPUT_FILE 提交日志，无历史哈希。</b>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            else
                # 去除链接末尾可能包含的 .git 后缀，以保证 GitHub 链接格式正确
                CLEAN_REPO_URL="${REPO_URL%.git}"
                # 拼接 GitHub 的 Compare 链接
                COMPARE_URL="${CLEAN_REPO_URL}/compare/${SHA_Begin}...${SHA_End}"
                echo "#### [:mega: 查看完整变更记录。 ](${COMPARE_URL})  " >>"git_log/$git_folder/$OUTPUT_FILE.log";
                echo ":heavy_exclamation_mark: 列表仅展示最新15条提交记录。  " >>"git_log/$git_folder/$OUTPUT_FILE.log"
                echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
                echo "哈希值|作者|提交时间|提交说明" >>"git_log/$git_folder/$OUTPUT_FILE.log"
                echo "-|-|-|-" >>"git_log/$git_folder/$OUTPUT_FILE.log"
                git -C "git_repositories/$git_folder/$OUTPUT_FILE" log --pretty=format:"%h|%an|%ad|%s" "$SHA_Begin...$SHA_End" | head -n 15 >>"git_log/$git_folder/$OUTPUT_FILE.log"
                if [ $(git -C "git_repositories/$git_folder/$OUTPUT_FILE" log --pretty=format:"%h|%an|%ad|%s" "$SHA_Begin...$SHA_End" | wc -l) -gt 15 ]; then 
                    echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
                fi
            fi
            echo "" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "</details>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
            echo "     |-----------------------------------|"
            echo "     $OUTPUT_FILE 已生成更新日志"
            echo "     |-----------------------------------|"
            sed -i "s/^${OUTPUT_FILE}:.*/${OUTPUT_FILE}:${SHA_End}/" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))
        # else
        #     # 没有更新的情况，生成默认日志
        #     echo "<b>No new commits for $OUTPUT_FILE.  :zzz: </b>" >>"git_log/$git_folder/$OUTPUT_FILE.log"
        fi

        # 将生成的 .log 文件追加到 release.txt
        if [ -f "git_log/$git_folder/$OUTPUT_FILE.log" ]; then
            echo "找到日志文件 $OUTPUT_FILE.log!"
            cat "git_log/$git_folder/$OUTPUT_FILE.log" >>release.txt
        else
            echo "未找到日志文件 $OUTPUT_FILE.log"
        fi
        echo "$git_folder-$OUTPUT_FILE 提交日志更新完成-----------------------------------------------------------"
        echo "==========================================================================================================="
        echo ""
        echo ""
        echo ""
    done
    if [ "$UPDATE_COUNT" -eq 0 ]; then
        echo "源码已是最新...... :zzz:">>release.txt
    fi
done

cd $GITHUB_WORKSPACE
find . -type f -name "*.txt" ! -name "release.txt" -exec rm {} +
rm -rf git_repositories