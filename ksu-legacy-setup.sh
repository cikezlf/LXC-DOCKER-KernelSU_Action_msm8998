#!/bin/bash
set -euo pipefail

# KernelSU-Next 固定配置 - legacy 分支（非GKI老内核专用）
OWNER="KernelSU-Next"
REPO="KernelSU-Next"
BRANCH="legacy"
GKI_ROOT=$(pwd)
DRIVER_DIR="$GKI_ROOT/drivers/kernelsu"
UAPI_SRC_DIR="$GKI_ROOT/$REPO/uapi"
UAPI_DST_DIR="$DRIVER_DIR/uapi"

# 清理旧残留
echo "[+] Cleaning old KernelSU directories..."
rm -rf "$DRIVER_DIR"
rm -rf "$GKI_ROOT/$REPO"

# 克隆最新legacy分支
echo "[+] Cloning $OWNER/$REPO (branch: $BRANCH)..."
git clone --depth 1 --single-branch -b "$BRANCH" "https://github.com/$OWNER/$REPO.git" "$GKI_ROOT/$REPO"

# 获取真实版本信息
cd "$GKI_ROOT/$REPO"
KSU_GIT_VERSION=$(git rev-list --count HEAD)
KSU_VERSION_TAG=$(git describe --tags --always --dirty)
echo "[✓] KernelSU-Next version: $KSU_VERSION_TAG (commit count: $KSU_GIT_VERSION)"
cd "$GKI_ROOT"

# 拷贝驱动代码
echo "[+] Copying driver files..."
mkdir -p "$DRIVER_DIR"
cp -a "$GKI_ROOT/$REPO/kernel/"* "$DRIVER_DIR/"

# 【关键修复1】拷贝uapi头文件，解决app_profile.h找不到
echo "[+] Copying uapi headers..."
mkdir -p "$UAPI_DST_DIR"
cp -a "$UAPI_SRC_DIR/"* "$UAPI_DST_DIR/"

# 【关键修复2】注入版本号到Kbuild头部，解决fallback问题
echo "[+] Injecting version info into Kbuild..."
KBUILD_FILE="$DRIVER_DIR/Kbuild"
sed -i "1i KSU_GIT_VERSION := $KSU_GIT_VERSION\nKSU_VERSION_TAG := $KSU_VERSION_TAG\n" "$KBUILD_FILE"

# 【关键修复3】校验关键文件
echo "[-] Verifying critical files..."
test -f "$UAPI_DST_DIR/app_profile.h" || { echo "❌ Missing uapi/app_profile.h!"; exit 1; }
test -f "$DRIVER_DIR/core/init.c" || { echo "❌ Missing core/init.c!"; exit 1; }
grep -q "KSU_GIT_VERSION := $KSU_GIT_VERSION" "$KBUILD_FILE" || { echo "❌ Version injection failed!"; exit 1; }
echo "[✓] All critical files verified"

# 修改Makefile和Kconfig（原有正确逻辑保留）
echo "[+] Modifying kernel Makefile..."
if ! grep -q "kernelsu" "$GKI_ROOT/Makefile"; then
  sed -i '/^core-y[[:space:]]*+=/s/$/ kernelsu\//' "$GKI_ROOT/Makefile"
fi

echo "[+] Modifying drivers Kconfig..."
DRIVERS_KCONFIG="$GKI_ROOT/drivers/Kconfig"
if ! grep -q "kernelsu/Kconfig" "$DRIVERS_KCONFIG"; then
  echo 'source "drivers/kernelsu/Kconfig"' >> "$DRIVERS_KCONFIG"
fi

echo "[✓] KernelSU-Next setup completed successfully!"
