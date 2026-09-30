#!/bin/bash
# ==============================================
# 【修复版v2】KernelSU-Next v3.4.0-legacy集成脚本
# 修复点：1.路径取当前pwd（内核目录） 2.加--patch自动打钩子 3.每步输出进度
# ==============================================
set +e
echo "=== KernelSU-Next集成脚本启动 [修复版v2] ==="

# 修复1：KERNEL_ROOT取当前工作目录（workflow执行时已经cd到android-kernel，所以这里就是内核根目录）
KERNEL_ROOT=$(pwd)
echo "[1/7] 内核源码根目录: $KERNEL_ROOT"
DRIVER_DIR="$KERNEL_ROOT/drivers"

# KernelSU-Next官方配置
KSU_DIR="$KERNEL_ROOT/KernelSU-Next"
KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_BRANCH="v3.4.0-legacy"

# 清理旧残留
echo "[2/7] 清理旧KernelSU残留..."
rm -rf "$KSU_DIR" "$DRIVER_DIR/kernelsu"
echo "[2/7] 旧文件清理完成"

# 克隆KernelSU-Next
echo "[3/7] 克隆KernelSU-Next $KSU_BRANCH (--depth=1加速)..."
git clone --depth 1 --branch "$KSU_BRANCH" "$KSU_REPO" "$KSU_DIR"
if [ $? -ne 0 ]; then
    echo "[ERROR] 克隆KernelSU-Next失败！检查网络或分支名"
    exit 1
fi
echo "[3/7] 克隆完成，路径: $KSU_DIR"

# 复制驱动到drivers目录
echo "[4/7] 复制kernelsu驱动到$DRIVER_DIR/kernelsu..."
cp -rf "$KSU_DIR/kernel" "$DRIVER_DIR/kernelsu"
echo "[4/7] 驱动复制完成"

# 修复2：执行setup.sh加--patch参数自动打4.4内核钩子
echo "[5/7] 执行自动打钩子(--patch)..."
cd "$KSU_DIR/kernel"
chmod +x setup.sh
bash setup.sh --patch "$KERNEL_ROOT"
echo "[5/7] 钩子注入完成"

# 修改Makefile和Kconfig
echo "[6/7] 修改Kconfig和顶层Makefile..."
echo 'source "drivers/kernelsu/Kconfig"' >> "$DRIVER_DIR/Kconfig"
sed -i '/^core-y/ s|$| drivers/kernelsu|' "$KERNEL_ROOT/Makefile"
echo "[6/7] Makefile/Kconfig配置完成"

# 注入sucompat钩子
echo "[7/7] 注入sucompat钩子到fs/sys_mounts.c..."
FSTAB_PATH="$KERNEL_ROOT/fs/sys_mounts.c"
if [ -f "$FSTAB_PATH" ]; then
    sed -i '/^#include <linux\/mount.h>/a #include <linux/sucompat.h>' "$FSTAB_PATH"
    sed -i '/static int do_mount(/a #if IS_ENABLED(CONFIG_KSU)\n\tif (sucompat_mount_allowed(dev_name)) {\n\t\treturn 0;\n\t}\n#endif' "$FSTAB_PATH"
    echo "[7/7] sucompat钩子注入完成"
else
    echo "[7/7] 未找到sys_mounts.c，跳过钩子注入"
fi

echo ""
echo "✅ === KernelSU-Next v3.4.0-legacy 集成全部完成！ ==="
