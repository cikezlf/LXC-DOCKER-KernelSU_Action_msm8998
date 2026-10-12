#!/bin/bash
set -euo pipefail

# KernelSU-Next 固定配置 - legacy 分支（msm8998 4.4老内核专用）
OWNER="KernelSU-Next"
REPO="KernelSU-Next"
BRANCH="legacy"
GKI_ROOT=$(pwd)
DRIVER_DIR="$GKI_ROOT/drivers/kernelsu"
UAPI_SRC_DIR="$GKI_ROOT/$REPO/uapi"
UAPI_DST_DIR="$DRIVER_DIR/uapi"

# 1. 彻底清理所有旧残留，避免历史错误配置干扰
echo "[+] Cleaning old KernelSU directories and leftover configs..."
rm -rf "$DRIVER_DIR"
rm -rf "$GKI_ROOT/$REPO"
# 清除根目录下可能残留的错误kernelsu空目录
rm -rf "$GKI_ROOT/kernelsu"

# 2. 克隆最新legacy分支，保证代码完整
echo "[+] Cloning $OWNER/$REPO (branch: $BRANCH)..."
git clone --depth 1 --single-branch -b "$BRANCH" "https://github.com/$OWNER/$REPO.git" "$GKI_ROOT/$REPO"

# 3. 获取真实版本信息，完全避免fallback
cd "$GKI_ROOT/$REPO"
KSU_GIT_VERSION=$(git rev-list --count HEAD)
KSU_VERSION_TAG=$(git describe --tags --always --dirty)
echo "[✓] KernelSU-Next version: $KSU_VERSION_TAG (commit count: $KSU_GIT_VERSION)"
cd "$GKI_ROOT"

# 4. 拷贝驱动代码到正确的drivers/kernelsu目录
echo "[+] Copying driver files to drivers/kernelsu..."
mkdir -p "$DRIVER_DIR"
cp -a "$GKI_ROOT/$REPO/kernel/"* "$DRIVER_DIR/"

# 5. 拷贝uapi头文件，解决app_profile.h找不到
echo "[+] Copying uapi headers..."
mkdir -p "$UAPI_DST_DIR"
cp -a "$UAPI_SRC_DIR/"* "$UAPI_DST_DIR/"

# 6. 强制注入版本号到Kbuild头部，彻底解决版本fallback
echo "[+] Injecting version info into Kbuild..."
KBUILD_FILE="$DRIVER_DIR/Kbuild"
sed -i "1i KSU_GIT_VERSION := $KSU_GIT_VERSION\nKSU_VERSION_TAG := $KSU_VERSION_TAG\n" "$KBUILD_FILE"

# 7. 【核心修复】严谨修改Makefile，只追加完整路径drivers/kernelsu/
echo "[+] Patching kernel Makefile with full path..."
# 先删除之前错误写入的裸kernelsu/条目，避免重复
sed -i '/kernelsu\//d' "$GKI_ROOT/Makefile"
# 在core-y += 行末尾追加完整路径，绝对不允许裸kernelsu/
sed -i '/^core-y[[:space:]]*+=/s/$/ drivers\/kernelsu\//' "$GKI_ROOT/Makefile"

# 8. 严谨修改drivers/Kconfig
echo "[+] Patching drivers/Kconfig..."
DRIVERS_KCONFIG="$GKI_ROOT/drivers/Kconfig"
# 先删除旧的重复条目
sed -i '/kernelsu\/Kconfig/d' "$DRIVERS_KCONFIG"
# 重新追加正确的Kconfig引用
echo 'source "drivers/kernelsu/Kconfig"' >> "$DRIVERS_KCONFIG"

# 9. 全量关键文件校验，提前暴露所有问题
echo "[-] Verifying all critical files and paths..."
test -f "$UAPI_DST_DIR/app_profile.h" || { echo "❌ Missing uapi/app_profile.h!"; exit 1; }
test -f "$DRIVER_DIR/core/init.c" || { echo "❌ Missing core/init.c!"; exit 1; }
test -f "$DRIVER_DIR/Makefile" || { echo "❌ Missing drivers/kernelsu/Makefile!"; exit 1; }
grep -q "KSU_GIT_VERSION := $KSU_GIT_VERSION" "$KBUILD_FILE" || { echo "❌ Version injection failed!"; exit 1; }
grep -q "drivers/kernelsu/" "$GKI_ROOT/Makefile" || { echo "❌ Makefile path patch failed!"; exit 1; }
echo "[✓] All critical files and paths verified"

echo "[✓] KernelSU-Next setup completed 100% successfully!"
