#!/bin/sh
set -eu

GKI_ROOT=$(pwd)
REPO="KernelSU-Next"
OWNER="KernelSU-Next"

display_usage() {
    echo "Usage: $0 [--cleanup | <commit-or-tag>]"
    echo "  --cleanup:              Cleans up previous modifications made by the script."
    echo "  <commit-or-tag>:        Sets up or updates the KernelSU-Next to specified tag or commit."
    echo "  -h, --help:             Displays this usage information."
    echo "  (no args):              Sets up or updates the KernelSU-Next environment to the latest non-beta stable tagged version."
}

initialize_variables() {
    if test -d "$GKI_ROOT/common/drivers"; then
         DRIVER_DIR="$GKI_ROOT/common/drivers"
    elif test -d "$GKI_ROOT/drivers"; then
         DRIVER_DIR="$GKI_ROOT/drivers"
    else
         echo '[ERROR] "drivers/" directory not found.'
         exit 127
    fi

    DRIVER_MAKEFILE=$DRIVER_DIR/Makefile
    DRIVER_KCONFIG=$DRIVER_DIR/Kconfig
}

# Reverts modifications made by this script
perform_cleanup() {
    echo "[+] Cleaning up..."
    [ -L "$DRIVER_DIR/kernelsu" ] && rm "$DRIVER_DIR/kernelsu" && echo "[-] Symlink removed."
    grep -q "kernelsu" "$DRIVER_MAKEFILE" && sed -i '/kernelsu/d' "$DRIVER_MAKEFILE" && echo "[-] Makefile reverted."
    grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG" && sed -i '/drivers\/kernelsu\/Kconfig/d' "$DRIVER_KCONFIG" && echo "[-] Kconfig reverted."
    if [ -d "$GKI_ROOT/$REPO" ]; then
        rm -rf "$GKI_ROOT/$REPO" && echo "[-] $REPO directory deleted."
    fi
}

# 获取最新正式稳定版tag，自动排除所有beta/rc/test等预发布版本
get_latest_stable_tag() {
    LATEST_STABLE_TAG=$(git ls-remote --tags --refs "https://github.com/$OWNER/$REPO" \
        | grep -v -iE "beta|rc|test|preview|nightly|dev" \
        | sort -t '/' -k3 -Vr \
        | head -1 \
        | cut -d '/' -f 3)
    
    if [ -z "$LATEST_STABLE_TAG" ]; then
        echo "[!] 未获取到有效正式稳定版tag，自动fallback到legacy分支，不会中断构建流程"
        return 1
    fi
    echo "[+] 筛选到最新正式稳定版tag: $LATEST_STABLE_TAG"
    return 0
}

# Sets up or update KernelSU-Next environment
setup_kernelsu() {
    echo "[+] Setting up $REPO..."
    if [ ! -d "$GKI_ROOT/$REPO" ]; then
        git clone -b legacy "https://github.com/$OWNER/$REPO" "$GKI_ROOT/$REPO"
        echo "[+] Repository cloned."
    fi

    cd "$GKI_ROOT/$REPO"
    # 清理现场
    git stash && echo "[-] Stashed current changes."
    git pull origin legacy && echo "[+] Repository updated."
    
    # 关键修复：拉取远程所有tag到本地，解决git pull不自动拉取tag的问题
    git fetch --tags && echo "[+] All remote tags fetched."

    # 切换到最新正式稳定版tag，自动跳过所有预发布版本
    if get_latest_stable_tag; then
        if git checkout "tags/$LATEST_STABLE_TAG" 2>/dev/null; then
            echo "[+] 已成功切换到最新正式稳定版: $LATEST_STABLE_TAG"
        else
            echo "[!] checkout tags/$LATEST_STABLE_TAG 失败（tag可能不存在于当前仓库），fallback到legacy分支"
            git checkout legacy
        fi
    else
        git checkout legacy
        echo "[!] 已fallback到legacy分支保证构建流程正常执行"
    fi

    cd "$DRIVER_DIR"
    ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$GKI_ROOT/$REPO/kernel")" "kernelsu" && echo "[+] Symlink created."

    grep -q "kernelsu" "$DRIVER_MAKEFILE" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE" && echo "[+] Modified Makefile."
    grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" && echo "[+] Modified Kconfig."
    echo '[+] Done.'
}

# Process command-line arguments
if [ "$#" -eq 0 ]; then
    initialize_variables
    setup_kernelsu
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    display_usage
elif [ "$1" = "--cleanup" ]; then
    initialize_variables
    perform_cleanup
else
    initialize_variables
    setup_kernelsu "$@"
fi
