#!/bin/bash
source "$GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh"

release_tag=$1
git_folders=(immortalwrt immortalwrt_master feeds custompackages)

cd "$GITHUB_WORKSPACE" || exit 1

# ------------------------------------------------------------
# 分类元数据： 显示名 | artifact 文件名 | 主仓库分类(需要构建表格)
# 说明：bash 变量名不能含横杠，故内部一律用下划线；显示名在这里还原成横杠
# ------------------------------------------------------------
declare -A FOLDER_TITLE=(
    [immortalwrt]="immortalwrt 25.12"
    [immortalwrt_master]="immortalwrt master"
    [feeds]="通用 Feeds"
    [custompackages]="自定义软件包"
)
declare -A FOLDER_ARTIFACT=(
    [immortalwrt]="immortalwrt"
    [immortalwrt_master]="immortalwrt-master"
    [feeds]="feeds"
    [custompackages]="custompackages"
)

# ⚠️ 请核对：以下两个名字我无法替你确认，必须你自己看一眼
REPO_SLUG="seaks/OpenWrtAction"        # 有 Release 的那个仓库
ACTIONS_SITE="https://github.com/seaks" # MyAction 实测 404，先指向账号页

ensure_log_trailing_newline() {
    local f="$1"
    [ -f "$f" ] && [ -s "$f" ] && [ -n "$(tail -c 1 "$f" 2>/dev/null)" ] && echo >> "$f"
    return 0
}

# ============================================================
# 一、Release 头部：徽章 + 构建信息表格
# ============================================================
{
    echo "[![](https://img.shields.io/github/downloads/${REPO_SLUG}/latest/total?style=flat-square)](${ACTIONS_SITE})"
    echo ""
    echo "## 源码信息"
    echo "[![](https://img.shields.io/badge/source-immortalwrt_25.12-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt)"
    echo "[![](https://img.shields.io/badge/source-immortalwrt_master-orange?logo=openwrt&logoColor=orange&style=flat-square)](https://github.com/immortalwrt/immortalwrt/tree/master)"
    echo ""
    echo "## 构建信息"
    echo "<table>"
    echo "  <tr><th>平台</th><th>源码平台</th><th>内核</th><th>目标</th><th>编译状态</th></tr>"
} > release.txt

for folder in "${git_folders[@]}"; do
    case "$folder" in
        immortalwrt|immortalwrt_master)
            if [ -f "release_${folder}.txt" ]; then
                cat "release_${folder}.txt" >> release.txt
            else
                echo "  <tr><td colspan=\"5\">⚠️ ${folder} 未生成构建信息（检查 step02 日志）</td></tr>" >> release.txt
            fi
            ;;
    esac
done

{
    echo "</table>"
    echo ""
    echo "## 更新内容"
    echo ""
} >> release.txt

# ============================================================
# 二、逐分类比对提交
# ============================================================
find git_log -type f ! -name 'log' -delete 2>/dev/null
mkdir -p git_repositories

for folder in "${git_folders[@]}"; do
    title="${FOLDER_TITLE[$folder]:-$folder}"
    hint="${FOLDER_ARTIFACT[$folder]:-$folder}"
    echo ">>> 处理分类: $folder （标题「$title」，artifact 名 $hint）"

    declare -n repo_urls="${folder}_REPO_URLS" 2>/dev/null
    if [ $? -ne 0 ] || [ -z "${repo_urls+x}" ]; then
        echo "   ⚠️ 未定义数组 ${folder}_REPO_URLS，请在 main_and_feeds_url.sh 中补上"
        printf "\n### %s\n\n⚠️ 未配置 <code>%s_REPO_URLS</code>，请检查 main_and_feeds_url.sh。\n\n" "$title" "$folder" >> release.txt
        continue
    fi

    mkdir -p "git_log/$folder"
    printf "\n### %s\n\n" "$title" >> release.txt

    UPDATE_COUNT=0
    seen_list=$(mktemp)

    for url in "${repo_urls[@]}"; do
        [ -z "$url" ] && continue
        REPO_URL=$(printf '%s' "$url" | awk '{print $1}')
        BRANCH=$(printf '%s'  "$url" | awk '{print $2}')
        [ -z "$REPO_URL" ] && continue

        NAME="${REPO_URL##*/}"; NAME="${NAME%.git}"
        [ -z "$NAME" ] || [ "$NAME" = "$REPO_URL" ] && continue

        if grep -qx "$NAME" "$seen_list"; then
            echo "   ↷ 跳过重复源: $NAME"; continue
        fi
        printf '%s\n' "$NAME" >> "$seen_list"

        DEST="git_repositories/$folder/$NAME"
        if [ -n "$BRANCH" ]; then
            git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 --branch "$BRANCH" "$DEST" 2>/dev/null \
             || git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 "$DEST" 2>/dev/null
        else
            git clone "$REPO_URL" --filter=blob:none --no-checkout --depth 300 "$DEST" 2>/dev/null
        fi

        if [ ! -d "$DEST" ]; then
            echo "   ✗ 克隆失败: $REPO_URL"
            printf '<b>⚠️ 仓库 <code>%s</code> 克隆失败，本次跳过。</b>\n\n' "$NAME" >> release.txt
            continue
        fi

        # ---- 取真理 SHA ----
        SHA_END=""
        if [ -f "git_log_${hint}.txt" ]; then
            SHA_END=$(grep "^${NAME}:" "git_log_${hint}.txt" 2>/dev/null | tail -n 1 | cut -d: -f2-)
        fi
        if [ -z "$SHA_END" ]; then
            SHA_END=$(grep -h "^${NAME}:" git_log_*.txt 2>/dev/null | tail -n 1 | cut -d: -f2-)
        fi
        if [ -z "$SHA_END" ]; then
            SHA_END=$(git -C "$DEST" rev-parse HEAD 2>/dev/null)
            echo "   ⚠️ [降级] artifact 无记录，使用 HEAD: $SHA_END"
        else
            echo "   ✅ [SSoT] $NAME → $SHA_END"
        fi
        if [ -z "$SHA_END" ]; then
            echo "   ✗ 取不到 SHA，跳过 $NAME"; continue
        fi

        LOG_FILE="git_log/$folder/log"
        ensure_log_trailing_newline "$LOG_FILE"
        SHA_BEGIN=$(grep "^${NAME}:" "$LOG_FILE" 2>/dev/null | tail -n 1 | cut -d: -f2-)
        BLOCK="git_log/$folder/$NAME.log"
        : > "$BLOCK"

        if ! grep -q "^${NAME}:" "$LOG_FILE" 2>/dev/null; then
            printf '%s:%s\n' "$NAME" "$SHA_END" >> "$LOG_FILE"
            printf '<details> <summary> <b>%s 首次记录基线 :seedling: </b> </summary>\n\n<b>已记录当前提交 <code>%s</code>，自下次编译起展示变更明细。</b>\n\n</details>\n' \
                "$NAME" "${SHA_END:0:7}" >> "$BLOCK"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))
            echo "   → 首次建立基线"

        elif ! git -C "$DEST" cat-file -e "${SHA_BEGIN}^{commit}" 2>/dev/null; then
            printf '<details> <summary> <b>%s 新提交记录 :warning: </b> </summary>\n\n<b>历史提交 <code>%s</code> 已不存在，该仓库可能 rebase 或强制推送，本次无法统计，基线已重置。</b>\n\n</details>\n' \
                "$NAME" "${SHA_BEGIN:0:7}" >> "$BLOCK"
            sed -i "s|^${NAME}:.*|${NAME}:${SHA_END}|" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))
            echo "   ✗ SHA 非法，基线已重置"

        elif [ "$SHA_BEGIN" != "$SHA_END" ]; then
            printf '<details> <summary> <b>%s 新提交记录 :rocket: </b> </summary>\n\n' "$NAME" >> "$BLOCK"
            printf '#### [:mega: 查看完整变更记录](%s/compare/%s...%s)  \n' "${REPO_URL%.git}" "$SHA_BEGIN" "$SHA_END" >> "$BLOCK"
            echo ':heavy_exclamation_mark: 列表仅展示最近 15 条提交。  ' >> "$BLOCK"
            echo "" >> "$BLOCK"
            echo "提交|作者|日期|说明" >> "$BLOCK"
            echo "-|-|-|-" >> "$BLOCK"

            git -C "$DEST" log --pretty=format:'%h|%an|%ad|%s' --date=short "${SHA_BEGIN}...${SHA_END}" 2>/dev/null \
                | head -n 15 >> "$BLOCK"

            TOTAL=$(git -C "$DEST" log --pretty=format:'%h' "${SHA_BEGIN}...${SHA_END}" 2>/dev/null | wc -l)
            if [ "${TOTAL:-0}" -gt 15 ]; then
                printf '\n> 共 %s 条提交，此处仅列出前 15 条。\n' "$TOTAL" >> "$BLOCK"
            fi
            printf '\n</details>\n' >> "$BLOCK"

            sed -i "s|^${NAME}:.*|${NAME}:${SHA_END}|" "$LOG_FILE"
            UPDATE_COUNT=$((UPDATE_COUNT + 1))
            echo "     ── $NAME 有更新（$TOTAL 条）"
        else
            echo "   → 无变化（${SHA_BEGIN:0:7}）"
        fi

        cat "$BLOCK" >> release.txt
        echo "" >> release.txt
    done

    if [ "$UPDATE_COUNT" -eq 0 ]; then
        echo "本分类所有仓库均无新提交...... :zzz:" >> release.txt
        echo "" >> release.txt
    fi
    rm -f "$seen_list"
    echo "   📊 $folder 分类：有变化/新建基线 $UPDATE_COUNT 个仓库"
done

# ============================================================
# 三、清理
# ============================================================
cd "$GITHUB_WORKSPACE" || exit 1
find . -maxdepth 1 -type f -name '*.txt' ! -name 'release.txt' -delete
rm -rf git_repositories
echo "==== release.txt 生成完毕 ===="
