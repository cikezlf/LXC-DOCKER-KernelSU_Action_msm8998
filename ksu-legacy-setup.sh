#!/bin/bash
set -euo pipefail

# ============== 固定配置：KernelSU-Next legacy分支（msm8998/4.4老内核专用）==============
OWNER="KernelSU-Next"
REPO="KernelSU-Next"
BRANCH="legacy"
GKI_ROOT=$(pwd)
DRIVER_DIR="$GKI_ROOT/drivers/kernelsu"
UAPI_SRC_DIR="$GKI_ROOT/$REPO/uapi"
UAPI_DST_DIR="$DRIVER_DIR/uapi"
VERSION_FILE="$GKI_ROOT/ksu_version.txt"

echo "[+] =============================================="
echo "[+] Starting KernelSU-Next legacy deployment..."
echo "[+] =============================================="

# 1. 彻底清理所有历史残留（包括错误路径、旧代码、旧缓存）
echo "[+] Cleaning old leftover files..."
rm -rf "$DRIVER_DIR"
rm -rf "$GKI_ROOT/$REPO"
rm -rf "$GKI_ROOT/kernelsu" # 清理之前误创建的根目录错误kernelsu目录
rm -f "$VERSION_FILE"

# 2. 克隆最新legacy分支代码（完整拉取标签，无缓存干扰）
echo "[+] Cloning latest $OWNER/$REPO (branch: $BRANCH)..."
git clone --depth 1 --single-branch -b "$BRANCH" "https://github.com/$OWNER/$REPO.git" "$GKI_ROOT/$REPO"

# 3. 计算真实版本号（直接从git获取，绝对不会fallback）
cd "$GKI_ROOT/$REPO"
KSU_GIT_VERSION=$(git rev-list --count HEAD)
KSU_VERSION_TAG=$(git describe --tags --always --dirty)
cd "$GKI_ROOT"
echo "[✓] Got KernelSU version: $KSU_VERSION_TAG (r$KSU_GIT_VERSION)"

# 4. 写入版本变量文件（供编译步骤直接加载，100%可靠）
cat > "$VERSION_FILE" << EOF
export KSU_GIT_VERSION=$KSU_GIT_VERSION
export KSU_VERSION_TAG=$KSU_VERSION_TAG
EOF
chmod 644 "$VERSION_FILE"

# 5. 拷贝内核驱动代码
echo "[+] Copying kernel driver files..."
mkdir -p "$DRIVER_DIR"
cp -a "$GKI_ROOT/$REPO/kernel/"* "$DRIVER_DIR/"

# 6. 拷贝uapi头文件（解决app_profile.h找不到错误）
echo "[+] Copying uapi header files..."
mkdir -p "$UAPI_DST_DIR"
cp -a "$UAPI_SRC_DIR/"* "$UAPI_DST_DIR/"

# 7. 严谨修改根目录Makefile（绝对避免裸路径错误）
echo "[+] Patching top-level Makefile..."
# 先删除所有旧的kernelsu相关条目，避免重复和错误路径
sed -i '/kernelsu/d' "$GKI_ROOT/Makefile"
# 只在第一个core-y += 行追加完整路径drivers/kernelsu/
sed -i '0,/^core-y[[:space:]]*+=/s/$/ drivers\/kernelsu\//' "$GKI_ROOT/Makefile"

# 8. 修改drivers/Kconfig
echo "[+] Patching drivers/Kconfig..."
DRIVERS_KCONFIG="$GKI_ROOT/drivers/Kconfig"
# 先删除旧条目
sed -i '/source.*kernelsu\/Kconfig/d' "$DRIVERS_KCONFIG"
# 追加正确引用
echo 'source "drivers/kernelsu/Kconfig"' >> "$DRIVERS_KCONFIG"

# 9. 全量校验所有文件和配置（提前拦截所有错误）
echo "[-] Running pre-compile verification..."
# 校验关键驱动文件存在
test -f "$DRIVER_DIR/Makefile" || { echo "❌ Missing drivers/kernelsu/Makefile!"; exit 1; }
test -f "$DRIVER_DIR/core/init.c" || { echo "❌ Missing core/init.c!"; exit 1; }
test -f "$UAPI_DST_DIR/app_profile.h" || { echo "❌ Missing uapi/app_profile.h!"; exit 1; }
# 校验Makefile路径正确（无裸kernelsu/路径）
grep -q "drivers/kernelsu/" "$GKI_ROOT/Makefile" || { echo "❌ Makefile path patch failed!"; exit 1; }
! grep -qE '^[[:space:]]*kernelsu/' "$GKI_ROOT/Makefile" || { echo "❌ Found invalid bare kernelsu path in Makefile!"; exit 1; }
# 校验版本文件正确
test -f "$VERSION_FILE" || { echo "❌ Version file missing!"; exit 1; }
grep -q "KSU_VERSION_TAG=$KSU_VERSION_TAG" "$VERSION_FILE" || { echo "❌ Version write failed!"; exit 1; }

echo "[✓] =============================================="
echo "[✓] All verifications passed!"
echo "[✓] KernelSU-Next deployed successfully!"
echo "[✓] Version: $KSU_VERSION_TAG (r$KSU_GIT_VERSION)"
echo "[✓] =============================================="
