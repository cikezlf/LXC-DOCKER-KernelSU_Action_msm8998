#!/bin/sh
set -eu

GKI_ROOT=$(pwd)
# OWNER="KernelSU-Next"
# REPO="$OWNER"
REPO="KernelSU-Next" 
#OWNER="kaho97"
OWNER="KernelSU-Next"

display_usage() {
    echo "Usage: $0 [--cleanup | <commit-or-tag>]"
    echo "  --cleanup:              Cleans up previous modifications made by the script."
    echo "  <commit-or-tag>:        Sets up or updates the KernelSU-Next to specified tag or commit."
    echo "  -h, --help:             Displays this usage information."
    echo "  (no args):              Sets up or updates the KernelSU-Next environment to the latest tagged version."
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

# Sets up or update KernelSU-Next environment
setup_kernelsu() {
    echo "[+] Setting up $REPO..."
    # 如果目录不存在就 clone 
    if [ ! -d "$GKI_ROOT/$REPO" ]; then 
        git clone -b legacy "https://github.com/$OWNER/$REPO" "$GKI_ROOT/$REPO"
        echo "[+] Repository cloned." 
    fi 
    
    cd "$GKI_ROOT/$REPO"
    # 清理现场 
    git stash && echo "[-] Stashed current changes."
    git pull origin legacy && echo "[+] Repository updated." 
    
    # 强制切换到 legacy 分支 
    git checkout legacy && echo "[-] Checked out legacy branch."

    # === 应用补丁逻辑 === 
    # # 补丁文件名叫 legacy4.4.patch
    # PATCH_FILE="$GKI_ROOT/$REPO/legacy_4.4.patch"
    # if [ -f "$PATCH_FILE" ]; then
    #     echo "[+] Applying patch: $PATCH_FILE"
    #     if git apply "$PATCH_FILE"; then 
    #         echo "[+] Patch applied successfully."
    #     else 
    #         echo "[!] git apply failed, trying with patch command..." 
    #         patch -p1 < "$PATCH_FILE" 
    #     fi 
    # else echo "[!] No patch file found at $PATCH_FILE"
    # fi 
    # # =====================

    cd "$DRIVER_DIR"
    ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$GKI_ROOT/$REPO/kernel")" "kernelsu" && echo "[+] Symlink created."

    # Add entries in Makefile and Kconfig if not already existing
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
