#!/bin/bash
#
# Copyright (c) 2019-2025 SmallProgram <https://github.com/smallprogram>
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

set -e

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$CURRENT_DIR")"
export TOPDIR="$PWD"

FEEDS_SCRIPT="$PARENT_DIR/custom_feeds_and_packages.sh"
if [ ! -f "$FEEDS_SCRIPT" ]; then
    echo "!!! 找不到 $FEEDS_SCRIPT" >&2
    echo "    当前 PARENT_DIR=$PARENT_DIR" >&2
    echo "    确认 custom_feeds_and_packages.sh 放在 OpenWrtAction/ 根目录下" >&2
    exit 1
fi

# source 只加载函数与变量（文件末尾 main 已注释，不会自动执行业务）
source "$FEEDS_SCRIPT"

# 防御：确认函数确实加载进来了
command -v append_feeds_top >/dev/null 2>&1 \
    || { echo "!!! append_feeds_top 未定义，source 可能失败" >&2; exit 1; }
command -v clone_custom_packages >/dev/null 2>&1 \
    || { echo "!!! clone_custom_packages 未定义" >&2; exit 1; }

echo "===== TOPDIR=$TOPDIR ===="
echo "===== 插入自定义 feeds 到顶部 ===="
append_feeds_top

echo "===== 克隆自定义包 ===="
clone_custom_packages

echo "===== 最终 feeds.conf.default ===="
if [ -f "$FEEDS_CONF" ]; then
    cat "$FEEDS_CONF"
else
    echo "!!! $FEEDS_CONF 不存在，TOPDIR=$TOPDIR" >&2
    exit 1
fi
echo "==================================="

echo "✅ diy-part1 finished"
