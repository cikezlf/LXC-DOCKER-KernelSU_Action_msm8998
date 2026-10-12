#!/bin/bash
#
# KernelSU-Next v3.4.0-legacy 部署脚本（最终版，零手动hook，kprobe模式）
# 适用于4.4/4.9/4.14等支持kprobe的旧内核，不用插任何手动hook，不会有语法错误
#
set -eu

KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_TARGET="${1:-v3.4.0-legacy}"
DRIVER_DIR="KernelSU-Next"

echo "[*] KernelSU-Next 目标版本: $KSU_TARGET"

# 清理旧残留
if [ -d "$DRIVER_DIR" ]; then
    echo "[*] 清理旧KernelSU目录"
    rm -rf "$DRIVER_DIR"
fi

# 克隆指定版本（浅克隆，只拉取目标tag）
echo "[*] 正在克隆 KernelSU-Next $KSU_TARGET ..."
git clone --depth=1 --branch "$KSU_TARGET" "$KSU_REPO" "$DRIVER_DIR"
echo "[+] 仓库克隆完成"

# 创建软链
echo "[*] 创建驱动软链..."
if [ -d "drivers" ]; then
    ln -sf "../$DRIVER_DIR/kernel" drivers/kernelsu
elif [ -d "common/drivers" ]; then
    ln -sf "../../$DRIVER_DIR/kernel" common/drivers/kernelsu
else
    echo "[!] 找不到drivers目录"
    exit 1
fi
echo "[+] 软链创建完成"

# 修改Makefile
if ! grep -q "kernelsu" Makefile; then
    echo "[*] 修改根Makefile..."
    sed -i '/^core-y[[:space:]]*+=/a\core-y += KernelSU-Next/kernel/' Makefile
    echo "[+] Makefile修改完成"
else
    echo "[=] Makefile已配置，跳过"
fi

# 修改Kconfig
if ! grep -q "kernelsu/Kconfig" drivers/Kconfig 2>/dev/null; then
    echo "[*] 修改drivers/Kconfig..."
    echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
    echo "[+] Kconfig修改完成"
elif [ -f common/drivers/Kconfig ] && ! grep -q "kernelsu/Kconfig" common/drivers/Kconfig; then
    echo "[*] 修改common/drivers/Kconfig..."
    echo 'source "drivers/kernelsu/Kconfig"' >> common/drivers/Kconfig
    echo "[+] Kconfig修改完成"
else
    echo "[=] Kconfig已配置，跳过"
fi

echo ""
echo "[✓] KernelSU-Next $KSU_TARGET 部署完成！"
echo "[!] 请在defconfig中配置："
echo "    CONFIG_KSU=y"
echo "    CONFIG_KPROBES=y   # 开启kprobe，完全不需要手动插hook"
echo "    # CONFIG_KSU_MANUAL_HOOK is not set"
echo ""
