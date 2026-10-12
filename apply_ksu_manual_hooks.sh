#!/bin/bash
set -eu

# ============================================================
#  ksu-legacy-setup.sh —— 拉取 KernelSU-Next Legacy 并接入内核树
#  修复版：① 参数可用  ② 钉住 tag / commit（默认 v3.4.0-legacy）
#        ③ 自动清理缓存/浅克隆残留，避免版本号停留在 32947 (v3.0.0)
#        ④ 自动探测 GKI 布局（drivers 位于 common/）
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

GIT_ROOT="$(pwd)"
DRIVER_DIR=""
DRIVER_MAKEFILE=""
DRIVER_KCONFIG=""

# 默认目标版本；命令行传参可覆盖
KSU_TARGET="${1:-v3.4.0-legacy}"

REPO="KernelSU-Next"
OWNER="KernelSU-Next"

# -------------------- 探测内核树布局 --------------------
if [ -f "$GIT_ROOT/drivers/Kconfig" ] && [ -f "$GIT_ROOT/drivers/Makefile" ]; then
    # 标准布局
    DRIVER_DIR="$GIT_ROOT/drivers/kernelsu"
    DRIVER_MAKEFILE="$GIT_ROOT/drivers/Makefile"
    DRIVER_KCONFIG="$GIT_ROOT/drivers/Kconfig"
elif [ -f "$GIT_ROOT/common/drivers/Kconfig" ] && [ -f "$GIT_ROOT/common/drivers/Makefile" ]; then
    # GKI 布局（Android 12+ common 内核）
    DRIVER_DIR="$GIT_ROOT/common/drivers/kernelsu"
    DRIVER_MAKEFILE="$GIT_ROOT/common/drivers/Makefile"
    DRIVER_KCONFIG="$GIT_ROOT/common/drivers/Kconfig"
    GIT_ROOT="$GIT_ROOT/common"
else
    echo "[✗] 未找到 drivers/Kconfig 或 common/drivers/Kconfig，请在内核源码根目录运行"
    exit 1
fi

display_usage() {
    cat <<EOF
Usage:
    bash $0 [commit-or-tag]

默认拉取 $KSU_TARGET；可指定任意 tag/commit（例如 v3.2.0-legacy 或某个 commit hash）。
EOF
}

setup_kernelsu() {
    echo "[*] KernelSU 驱动目录: $DRIVER_DIR"
    echo "[*] 目标版本: $KSU_TARGET"

    # ---------- 关键修复：彻底清理任何残留（包括缓存导致的旧状态） ----------
    # 原脚本只做 [ -L ] && rm，但缓存可能留下一个非软链的目录，或者一个
    # 陈旧的 git 仓库导致 pull/fetch 不更新；直接删掉重来是最稳的。
    if [ -e "$DRIVER_DIR" ] || [ -L "$DRIVER_DIR" ]; then
        echo "[*] 清理旧的 drivers/kernelsu ..."
        rm -rf --one-file-system "$DRIVER_DIR"
    fi

    # ---------- 克隆并钉到指定 tag/commit ----------
    if [ ! -d "$REPO" ]; then
        echo "[*] 首次克隆 $OWNER/$REPO (branch=legacy, full history) ..."
        # 不使用 --depth：浅克隆会导致 rev-list --count HEAD 算出的提交数偏小，
        # 从而版本号偏低（这就是你看到 32947 的原因）。
        git clone --single-branch -b legacy "https://github.com/$OWNER/$REPO.git" "$REPO"
    else
        echo "[*] 已存在 $REPO，fetch 最新 legacy 分支引用..."
        # 彻底拉全：--unshallow 处理浅克隆残留；更新所有 tags
        ( cd "$REPO" && \
          git remote set-url origin "https://github.com/$OWNER/$REPO.git" && \
          git fetch origin legacy --tags --force && \
          if [ -f .git/shallow ]; then git fetch --unshallow 2>/dev/null || true; fi )
    fi

    # 切到目标 tag/commit（显式用 FETCH_HEAD / tag 本身，避免本地旧分支阻挡）
    echo "[*] 切换到 $KSU_TARGET ..."
    ( cd "$REPO" && \
      git reset --hard -q && \
      git checkout -q "$KSU_TARGET" && \
      if [ -f .git/shallow ]; then git fetch --unshallow 2>/dev/null || true; fi && \
      echo "[*] 当前 HEAD: $(git log -1 --oneline)" && \
      echo "[*] git describe: $(git describe --tags --abbrev=0 2>/dev/null || echo 'N/A')" && \
      echo "[*] 提交总数: $(git rev-list --count HEAD) -> KSU_VERSION=$((30000 + $(git rev-list --count HEAD) + 289))" )

    # ---------- 软链接内核驱动目录 ----------
    echo "[*] 链接 $REPO/kernel -> drivers/kernelsu ..."
    ln -sf "$GIT_ROOT/$REPO/kernel" "$DRIVER_DIR"

    # 验证软链接指向的目录里确实有 Kbuild（防止路径错配）
    if [ ! -f "$DRIVER_DIR/Kbuild" ]; then
        echo "[✗] 软链创建失败：$DRIVER_DIR/Kbuild 不存在，请检查目录结构"
        exit 1
    fi

    # ---------- 注入 Makefile / Kconfig ----------
    if ! grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"
        echo "[+] 已在 drivers/Makefile 末尾追加 obj-\$(CONFIG_KSU) += kernelsu/"
    else
        echo "[=] drivers/Makefile 已包含 kernelsu，跳过"
    fi

    if ! grep -q "kernelsu" "$DRIVER_KCONFIG"; then
        # 放在 endmenu 之前
        if grep -q "^endmenu" "$DRIVER_KCONFIG"; then
            sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"
        else
            printf 'source "drivers/kernelsu/Kconfig"\n' >> "$DRIVER_KCONFIG"
        fi
        echo "[+] 已在 drivers/Kconfig 中添加 source \"drivers/kernelsu/Kconfig\""
    else
        echo "[=] drivers/Kconfig 已包含 kernelsu，跳过"
    fi

    echo "[✓] KernelSU-Next ($KSU_TARGET) 部署完成"
}

cleanup_kernelsu() {
    echo "[*] 清理 KernelSU..."
    if [ -L "$DRIVER_DIR" ]; then
        rm "$DRIVER_DIR"
        echo "[-] 已删除软链 $DRIVER_DIR"
    elif [ -d "$DRIVER_DIR" ]; then
        rm -rf "$DRIVER_DIR"
        echo "[-] 已删除目录 $DRIVER_DIR"
    else
        echo "[=] $DRIVER_DIR 不存在，无需清理"
    fi

    # Makefile 还原
    if [ -f "$DRIVER_MAKEFILE" ]; then
        sed -i '/kernelsu/d' "$DRIVER_MAKEFILE"
        echo "[-] 已从 drivers/Makefile 移除 kernelsu"
    fi
    if [ -f "$DRIVER_KCONFIG" ]; then
        sed -i '/kernelsu/d' "$DRIVER_KCONFIG"
        echo "[-] 已从 drivers/Kconfig 移除 kernelsu"
    fi

    [ -d "$REPO" ] && rm -rf --one-file-system "$REPO" && echo "[-] 已删除 $REPO 目录"
    echo "[✓] 清理完成"
}

case "${1:-}" in
    --cleanup|-c)
        # 覆盖默认值：--cleanup 不指定版本
        KSU_TARGET="legacy"
        if [ -f "$GIT_ROOT/drivers/Kconfig" ]; then
            DRIVER_DIR="$GIT_ROOT/drivers/kernelsu"
            DRIVER_MAKEFILE="$GIT_ROOT/drivers/Makefile"
            DRIVER_KCONFIG="$GIT_ROOT/drivers/Kconfig"
        elif [ -f "$GIT_ROOT/common/drivers/Kconfig" ]; then
            DRIVER_DIR="$GIT_ROOT/common/drivers/kernelsu"
            DRIVER_MAKEFILE="$GIT_ROOT/common/drivers/Makefile"
            DRIVER_KCONFIG="$GIT_ROOT/common/drivers/Kconfig"
        fi
        cleanup_kernelsu
        ;;
    -h|--help)
        display_usage
        ;;
    *)
        setup_kernelsu
        ;;
esac
