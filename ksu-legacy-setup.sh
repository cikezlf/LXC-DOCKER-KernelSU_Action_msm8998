#!/bin/sh
set -eu

# ============================================================
# 部署“最新的 KernelSU-Next legacy”到当前内核源码树
#
# 官方仓库：KernelSU-Next/KernelSU-Next
#   - 面向非 GKI / 老内核（如 msm8998 4.4）的最新代码在 legacy 分支
#   - 不传参数：始终对齐 legacy 分支最新代码（滚动最新）
#   - 传 tag/commit：锁定到指定版本（如 v3.4.0-legacy）
#
# 用法：
#   ./ksu-legacy-setup.sh                 # legacy 分支最新（含 legacy 传参等价）
#   ./ksu-legacy-setup.sh v3.4.0-legacy   # 锁定到指定 legacy 标签
#   ./ksu-legacy-setup.sh --cleanup       # 清理本脚本做过的改动
#   ./ksu-legacy-setup.sh -h | --help
# ============================================================

GKI_ROOT=$(pwd)
OWNER="KernelSU-Next"
REPO="KernelSU-Next"
BRANCH="legacy"

display_usage() {
    echo "Usage: $0 [--cleanup | <commit-or-tag>]"
    echo "  --cleanup:              Cleans up previous modifications made by the script."
    echo "  <commit-or-tag>:        Sets up or updates KernelSU-Next legacy to the specified tag or commit."
    echo "  -h, --help:             Displays this usage information."
    echo "  (no args):              Sets up or updates KernelSU-Next legacy to the latest."
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

# 撤销本脚本做过的改动
perform_cleanup() {
    echo "[+] Cleaning up..."
    [ -L "$DRIVER_DIR/kernelsu" ] && rm "$DRIVER_DIR/kernelsu" && echo "[-] Symlink removed."
    grep -q "kernelsu" "$DRIVER_MAKEFILE" && sed -i '/kernelsu/d' "$DRIVER_MAKEFILE" && echo "[-] Makefile reverted."
    grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG" && sed -i '/drivers\/kernelsu\/Kconfig/d' "$DRIVER_KCONFIG" && echo "[-] Kconfig reverted."
    if [ -d "$GKI_ROOT/$REPO" ]; then
        rm -rf "$GKI_ROOT/$REPO" && echo "[-] $REPO directory deleted."
    fi
}

# 部署 / 更新 KernelSU-Next legacy
setup_kernelsu() {
    TAG="${1:-}"
    BRANCH="${BRANCH:-legacy}"
    echo "[+] Setting up $REPO (branch: $BRANCH)..."

    # 目录不存在就 clone（直接 -b 指定 legacy，避免首次拉默认 dev 分支）
    if [ ! -d "$GKI_ROOT/$REPO/.git" ]; then
        git clone -b "$BRANCH" "https://github.com/$OWNER/$REPO" "$GKI_ROOT/$REPO"
        echo "[+] Repository cloned (branch: $BRANCH)."
    fi

    cd "$GKI_ROOT/$REPO"
    # 拉取远端全部分支与标签，并清理已删除的远端引用
    git fetch --tags --prune origin

    # 空 / legacy：始终取 legacy 分支最新代码；其它值：锁定到该 tag 或 commit
    case "$TAG" in
        ""|legacy)
            git checkout --force "$BRANCH"
            git reset --hard "origin/$BRANCH"
            echo "[-] Checked out $BRANCH and hard-reset to origin/$BRANCH (latest legacy)."
            ;;
        *)
            git checkout --force "$TAG"
            git reset --hard "$TAG"
            echo "[-] Checked out and hard-reset to $TAG."
            ;;
    esac
    echo "[-] Current commit: $(git rev-parse --short HEAD)  ($(git log -1 --format=%cd --date=short))"

    cd "$DRIVER_DIR"
    # 兼容没有 realpath 命令的精简构建环境
    if command -v realpath >/dev/null 2>&1; then
        KSU_REL="$(realpath --relative-to="$DRIVER_DIR" "$GKI_ROOT/$REPO/kernel")"
    else
        # 没有 realpath 时计算相对路径（drivers 目录下相对到 KernelSU-Next/kernel）
        KSU_REL="../../$REPO/kernel"
    fi
    ln -sf "$KSU_REL" "kernelsu" && echo "[+] Symlink created: $KSU_REL -> drivers/kernelsu"

    # 补 Makefile / Kconfig 构建条目（已存在则跳过）
    grep -q "kernelsu" "$DRIVER_MAKEFILE" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE" && echo "[+] Modified Makefile."
    grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" && echo "[+] Modified Kconfig."
    echo '[+] Done.'
}

# 命令行参数处理
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
