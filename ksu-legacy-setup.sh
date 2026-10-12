#!/usr/bin/env bash
set -eu
GKI_ROOT="$(pwd)"
BRANCH="${BRANCH:-legacy}"
OWNER="KernelSU-Next"
REPO="KernelSU-Next"

function cleanup {
    echo "[*] Cleaning up..."
    if [ -L "drivers/kernelsu" ] || [ -d "drivers/kernelsu" ]; then
        rm -rf drivers/kernelsu
        echo "[-] Removed old drivers/kernelsu"
    fi
    if [ -d "$REPO" ]; then
        rm -rf "$REPO"
        echo "[-] Removed old $REPO repo cache"
    fi
}

if [ $# -ge 1 ]; then
    case "$1" in
        --cleanup|-c)
            cleanup
            echo "[+] Cleanup done."
            exit 0
            ;;
        -h|--help)
            echo "Usage: $0 [tag|branch] | --cleanup | -h"
            echo "  不传参/传legacy = 使用legacy分支最新代码"
            echo "  传v3.x.x-legacy = 锁定到指定版本tag"
            echo "  --cleanup       = 清理kernelsu目录和仓库缓存"
            exit 0
            ;;
    esac
fi

cleanup

echo "[+] Setting up KernelSU-Next (branch: $BRANCH, target: ${1:-latest})..."

if [ ! -d "$REPO/.git" ]; then
    git clone --depth 1 --single-branch -b "$BRANCH" "https://github.com/$OWNER/$REPO" "$REPO"
fi
cd "$REPO"
git fetch --tags --depth 1 origin "$BRANCH"
git reset --hard "origin/$BRANCH"
if [ $# -ge 1 ] && [ "$1" != "$BRANCH" ]; then
    if git rev-parse "$1" >/dev/null 2>&1; then
        git checkout --force "$1"
        git reset --hard "$1"
        echo "[-] Pinned to version: $1"
    else
        echo "[!] Warning: tag $1 not found, using latest $BRANCH"
    fi
fi
CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_DATE=$(git log -1 --format=%cd --date=short)
echo "[-] KernelSU-Next commit: $CURRENT_COMMIT ($CURRENT_DATE)"
cd ..

# 不用软链！直接拷贝文件进去，彻底解决out-of-source构建路径问题
echo "[+] Copying KernelSU driver files to drivers/kernelsu..."
mkdir -p drivers/kernelsu
cp -a "$REPO"/kernel/. drivers/kernelsu/

echo "[-] Verifying driver files..."
ls -la drivers/kernelsu/core/init.c drivers/kernelsu/runtime/ksud.h
echo "[✓] KernelSU files copied successfully"

if grep -q "kernelsu" drivers/Makefile; then
    echo "[-] drivers/Makefile already has kernelsu entry, skipping"
else
    echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
    echo "[+] Added kernelsu to drivers/Makefile"
fi

if grep -q "KSU" drivers/Kconfig; then
    echo "[-] drivers/Kconfig already has KSU entry, skipping"
else
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    echo "[+] Added Kconfig entry to drivers/Kconfig"
fi

echo "[✓] KernelSU-Next setup completed successfully!"
echo "[+] All files copied directly (no symlink issues for out-of-source builds)"
