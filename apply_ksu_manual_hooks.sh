#!/bin/bash
#
# KernelSU-Next manual-hook 注入脚本（4.4 内核专用）
# - 幂等：重复执行不会重复插入
# - 修复：所有awk/sed正则用单引号包裹，完全避开bash转义，括号不匹配问题彻底解决
# - 修复：所有return严格在函数体内
#

set -eu

KERNEL_ROOT="${1:-$(pwd)}"
cd "$KERNEL_ROOT"

echo "[*] 内核目录: $KERNEL_ROOT"

# 通用插入函数：
# 1. 先检查目标hook是否已存在，存在就直接跳过
# 2. 在匹配模式的下一行插入hook代码
# 参数：文件  正则模式  要插入的行
insert_hook_after_line() {
    local file="$1"
    local eregex="$2"
    local hook_code="$3"

    if [ ! -f "$file" ]; then
        echo "[!] $file 不存在"
        return 1
    fi

    # 幂等检查
    if grep -qF -- "$hook_code" "$file"; then
        echo "[=] $file: hook已存在，跳过"
        return 0
    fi

    # 用sed插入：-E使用扩展正则，括号是字面字符不需要转义
    # 正则用单引号传给grep/sed，bash完全不碰里面的字符
    if grep -qE -- "$eregex" "$file"; then
        sed -i -E -- "/$eregex/a\\$hook_code" "$file"
        echo "[+] $file: 已插入 hook"
        return 0
    fi

    echo "[!] $file: 未找到匹配模式 $eregex"
    return 1
}

# 特殊处理reboot：SYSCALL_DEFINE4(reboot, ...)参数跨多行，{在下一行
# 策略：找到包含"SYSCALL_DEFINE4"和"reboot"的行，然后向下找到第一个{，在{之后插入
insert_hook_reboot() {
    local file="kernel/reboot.c"
    local hook_code=$'\tksu_handle_sys_reboot(cmd, __user arg);'

    if [ ! -f "$file" ]; then
        echo "[!] $file 不存在"
        return 1
    fi

    # 幂等检查
    if grep -qF -- "$hook_code" "$file"; then
        echo "[=] $file: hook已存在，跳过"
        return 0
    fi

    # awk脚本**全程单引号包裹**，bash完全不解析里面内容——彻底解决转义坑
    # 字面括号直接写，不需要任何反斜杠
    awk '
    BEGIN { found = 0; inserted = 0; }
    {
        print $0
        if (!inserted) {
            if (!found) {
                # 匹配SYSCALL_DEFINE4(reboot 或 sys_reboot
                if ($0 ~ /SYSCALL_DEFINE4[[:space:]]*\(reboot/ || $0 ~ /sys_reboot/) {
                    found = 1
                }
            } else {
                # 已经找到函数声明行，现在找第一个左大括号，在其后插入
                if ($0 ~ /\{/) {
                    print "\tksu_handle_sys_reboot(cmd, __user arg);"
                    inserted = 1
                }
            }
        }
    }
    END {
        exit inserted ? 0 : 1
    }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    if grep -qF -- "$hook_code" "$file"; then
        echo "[+] $file: 已插入 hook"
        return 0
    fi

    echo "[!] $file: 自动插入失败，需要手动插：$hook_code"
    return 2
}

FAIL=0

echo ""
echo "===== 1/5 处理 kernel/reboot.c ====="
insert_hook_reboot || FAIL=1

echo ""
echo "===== 2/5 处理 fs/exec.c ====="
# 匹配：SYSCALL_DEFINE3(execve 或 SYSCALL_DEFINE2(execve 等，execve之前是SYSCALL_DEFINE+数字
insert_hook_after_line "fs/exec.c" 'SYSCALL_DEFINE[0-9]+\(execve' $'\tksu_handle_execve(filename);' || FAIL=1

echo ""
echo "===== 3/5 处理 fs/open.c ====="
insert_hook_after_line "fs/open.c" 'SYSCALL_DEFINE[0-9]+\(faccessat' $'\tksu_handle_faccessat(filename, &ret);' || FAIL=1

echo ""
echo "===== 4/5 处理 fs/read_write.c ====="
# 4.4 内核里vfs_read函数不是syscall开头，直接匹配vfs_read函数定义
insert_hook_after_line "fs/read_write.c" 'ssize_t[[:space:]]+vfs_read[[:space:]]*\(' $'\tksu_handle_vfs_read(file, &buf, count, &pos);' || FAIL=1

echo ""
echo "===== 5/5 处理 fs/stat.c ====="
insert_hook_after_line "fs/stat.c" 'SYSCALL_DEFINE[0-9]+\(newfstatat' $'\tksu_handle_stat(dfd, filename, &stat);' || FAIL=1

echo ""
if [ $FAIL -eq 1 ]; then
    echo "❌ 部分hook插入失败，请手动检查"
    exit 1
fi

echo "✅ 全部hook插入完成"
exit 0

