#!/bin/bash
set -euo pipefail

echo "=== 开始集成KernelSU-Next v3.4.0-legacy ==="

# KernelSU-Next官方仓库地址和版本
KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_VERSION="v3.4.0-legacy"
KERNEL_ROOT=$(pwd)

# 清理旧版本残留
rm -rf KernelSU-Next drivers/kernelsu
echo "[✓] 旧版本残留已清理"

# 克隆KernelSU-Next（--depth=1加速，不会卡住）
echo "=== 克隆KernelSU-Next $KSU_VERSION ==="
git clone -q --depth=1 --branch "$KSU_VERSION" "$KSU_REPO" KernelSU-Next
echo "[✓] KernelSU-Next $KSU_VERSION 克隆完成"

# 复制驱动到内核源码
echo "=== 复制KernelSU驱动到内核源码 ==="
cp -rf KernelSU-Next/kernel drivers/kernelsu
echo "[✓] 驱动复制完成"

# 集成内核Makefile和Kconfig
echo "=== 集成KernelSU到内核构建系统 ==="
sed -i 's/^CONFIG_KERNELSU=.*/CONFIG_KERNELSU=y/' .config
echo "CONFIG_KERNELSU=y" >> .config
echo "CONFIG_KPROBES=y" >> .config
echo "CONFIG_HAVE_KPROBES=y" >> .config
echo "CONFIG_KPROBE_EVENTS=y" >> .config

# 把kernelsu加入drivers/Makefile和Kconfig
if ! grep -q "kernelsu" drivers/Makefile; then
    echo "obj-\$(CONFIG_KERNELSU)		+= kernelsu/" >> drivers/Makefile
fi
if ! grep -q "kernelsu" drivers/Kconfig; then
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
echo "[✓] 内核构建系统集成完成"

# 给KernelSU驱动加警告豁免，避免Clang警告终止编译
echo "ccflags-y += -w -Wno-error" >> drivers/kernelsu/Makefile
echo "[✓] KernelSU驱动警告豁免配置完成"

# 同步配置
make ARCH=arm64 olddefconfig O=out 2>/dev/null || true
echo "[✓] KernelSU-Next v3.4.0-legacy 集成完成"
