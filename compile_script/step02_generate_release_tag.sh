#!/bin/bash

release_tag=$1
source_code_platform=$2
config=$3

source $GITHUB_WORKSPACE/compile_script/platforms.sh

# echo "[![](https://img.shields.io/github/downloads/seaks/OpenWrtAction/$release_tag/total?style=flat-square)](https://github.com/seaks/MyAction)">> release.txt
# echo ""
# echo "## 源代码信息">> release.txt
# echo "[![](https://img.shields.io/badge/sorce-immortalwrt-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt) [![](https://img.shields.io/badge/sorce-immortalwrt-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt) [![](https://img.shields.io/badge/sorce-immortalwrt_master-green?logo=openwrt&logoColor=green&style=flat-square)](https://github.com/immortalwrt/immortalwrt)
# ">> release.txt
# echo ""
# echo "## Build Information"

# echo "<table>">>release.txt
# echo "  <tr>">>release.txt
# echo "    <th>平台</th>">>release.txt
# echo "    <th>源码平台</th>">>release.txt
# echo "    <th>内核</th>">>release.txt
# echo "    <th>目标</th>">>release.txt
# echo "    <th>编译状态</th>">>release.txt
# echo "  </tr>">>release.txt



if [[ "$source_code_platform" == "immortalwrt_master" ]]; then
  selected_platforms=("${immortalwrt_master_platforms[@]}")
elif [[ "$source_code_platform" == "immortalwrt" ]]; then
  selected_platforms=("${immortalwrt_platforms[@]}")
elif [[ "$source_code_platform" == "lede" ]]; then
  selected_platforms=("${lede_platforms[@]}")
fi


for platform in "${selected_platforms[@]}"; do
    # 拼接 .config 文件路径
    config_file="$GITHUB_WORKSPACE/$config/$platform.config"

    # 读取 CONFIG_TARGET_BOARD 的值
    if [[ -f $config_file ]]; then
        target_board=$(grep 'CONFIG_TARGET_BOARD=' "$config_file" | awk -F '=' '{print $2}' | tr -d '"')
    else
        echo "未找到 $platform 的配置文件。"
        continue
    fi

    # 从 Makefile 读取 KERNEL_PATCHVER
    kernel=$(grep -oP 'KERNEL_PATCHVER:=\K[^ ]+' "$GITHUB_WORKSPACE/openwrt/target/linux/$target_board/Makefile")

    # kernel_version=$(sed -n '2p' "$GITHUB_WORKSPACE/openwrt/include/kernel-$kernel" | awk -F '-' '{print $2}' | awk -F ' =' '{print $1}')

    # 从对应内核文件读取内核版本
    if [[ "$source_code_platform" == "lede" ]]; then
      kernel_version=$(sed -n '2p' "$GITHUB_WORKSPACE/openwrt/include/kernel-$kernel" | awk -F '-' '{print $2}' | awk -F ' =' '{print $1}')
    else
      kernel_version=$(sed -n '2p' "$GITHUB_WORKSPACE/openwrt/target/linux/generic/kernel-$kernel" | awk -F '-' '{print $2}' | awk -F ' =' '{print $1}')  
    fi


    echo "  <tr>">>release_$source_code_platform.txt
    echo "    <td><strong>🧊 $platform</strong></td>">>release_$source_code_platform.txt
    echo "    <td><strong>$source_code_platform</strong></td>">>release_$source_code_platform.txt
    echo "    <td><strong>$kernel_version</strong></td>">>release_$source_code_platform.txt
    echo "    <td><strong>$target_board</strong></td>">>release_$source_code_platform.txt
    echo "    <td><img scp=\"$source_code_platform\" plm=\"$platform\" src=\"https://img.shields.io/badge/build-编译中.....-yellow?logo=githubactions&logoColor=yellow&style=flat-square\" alt=\"编译状态\"/></td>">>release_$source_code_platform.txt
    echo "  </tr>">>release_$source_code_platform.txt

done


# echo "</table>">>release.txt

touch release_$source_code_platform.txt
echo 'status=success' >>$GITHUB_OUTPUT
