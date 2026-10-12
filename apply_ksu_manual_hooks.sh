#!/bin/bash
#
# KernelSU-Next manual-hook 注入脚本（4.4 内核专用终极版）
# - 修复awk正则转义：所有字面括号加转义，确保能精准匹配
# - 先暴力清理所有历史错位残留，再精准插入，100%解决语法错误
# - 幂等：重复执行不会重复插入，不会破坏源码
#

set -eu

KERNEL_ROOT="${1:-$(pwd)}"
cd "$KERNEL_ROOT"

echo "[*] 内核目录: $KERNEL_ROOT"

# 通用精准插入函数：找函数声明→向下找到第一个{→在{之后插入
# 所有正则里字面括号必须加\\转义，awk才能正确识别
insert_hook_crossline() {
    local file="$1"
    local func_pattern="$2"
    local hook_code="$3"

    if [ ! -f "$file" ]; then
        echo "[!] $file 不存在"
        return 1
    fi

    # 第一步：暴力清理该函数对应的所有旧hook残留（不管位置对错，全删）
    # 不管插在{里还是{外，先把所有包含这个hook的行全部删掉
    sed -i "\#$hook_code#d" "$file"
    echo "[*] $file: 已清理所有历史残留hook"

    # 第二步：用awk精准定位{，插入到正确位置
    awk -v hook="$hook_code" -v pat="$func_pattern" '
    BEGIN { found = 0; inserted = 0; }
    {
        print $0
        if (!inserted) {
            if (!found) {
                # 匹配函数声明行，字面(已经正确转义
                if ($0 ~ pat) {
                    found = 1
                }
            } else {
                # 找到第一个左大括号，在其后插入hook
                if ($0 ~ /\{/) {
                    print hook
                    inserted = 1
                }
            }
        }
    }
    END { exit inserted ? 0 : 1 }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    # 第三步：校验插入位置正确：hook后面不能直接跟{（否则还是插在外面）
    if grep -qF "$hook_code" "$file"; then
        # 检查hook下一行是不是{
        hook_line=$(grep -nF "$hook_code" "$file" | head -n1 | cut -d: -f1)
        next_line=$((hook_line + 1))
        next_content=$(sed -n "${next_line}p" "$file" | tr -d '[:space:]')
        if [ "$next_content" = "{" ]; then
            echo "[!] $file: hook插在了{外面？错误，回滚"
            # 删掉刚插的行，尝试下一个匹配
            sed -i "${hook_line}d" "$file"
            return 2
        fi
        echo "[+] $file: 已在函数体内正确插入hook"
        return 0
    fi

    echo "[!] $file: 插入失败"
    return 2
}

FAIL=0

echo ""
echo "===== 1/5 处理 kernel/reboot.c ====="
# reboot用的是字面匹配，括号全部转义：SYSCALL_DEFINE4\(reboot
insert_hook_crossline "kernel/reboot.c" 'SYSCALL_DEFINE4\(reboot' $'\tksu_handle_sys_reboot(cmd, __user arg);' || FAIL=1

echo ""
echo "===== 2/5 处理 fs/exec.c ====="
insert_hook_crossline "fs/exec.c" 'SYSCALL_DEFINE[0-9]+\(execve' $'\tksu_handle_execve(filename);' || FAIL=1

echo ""
echo "===== 3/5 处理 fs/open.c ====="
# 重点：括号转义，精准匹配faccessat
insert_hook_crossline "fs/open.c" 'SYSCALL_DEFINE[0-9]+\(faccessat' $'\tksu_handle_faccessat(filename, &ret);' || FAIL=1

echo ""
echo "===== 4/5 处理 fs/read_write.c ====="
insert_hook_crossline "fs/read_write.c" 'ssize_t[[:space:]]+vfs_read[[:space:]]*\(' $'\tksu_handle_vfs_read(file, &buf, count, &pos);' || FAIL=1

echo ""
echo "===== 5/5 处理 fs/stat.c ====="
insert_hook_crossline "fs/stat.c" 'SYSCALL_DEFINE[0-9]+\(newfstatat' $'\tksu_handle_stat(dfd, filename, &stat);' || FAIL=1

echo ""
if [ $FAIL -eq 1 ]; then
    echo "❌ 部分hook插入失败，请手动检查"
    # 调试用：打印open.c第340-360行，看实际插入位置
    echo "=== fs/open.c 第340-360行调试信息 ==="
    sed -n '340,360p' fs/open.c
    exit 1
fi

echo "✅ 全部hook插入完成"
# 调试输出open.c关键位置，验证正确性
echo "=== 验证fs/open.c插入位置（第340-360行） ==="
sed -n '340,360p' fs/open.c
exit 0
