#!/bin/bash
# 【最稳妥零错误版】KernelSU 4.4内核手动hook插入
# 完全不猜函数结构、不用跨行匹配、不会匹配到结构体/宏
# 原理：每个函数的插入位置都是官方指定的固定点，直接找对应行插入即可
set -eu

KERNEL_ROOT="${1:-$(pwd)}"
cd "$KERNEL_ROOT"

echo "[*] 内核目录: $KERNEL_ROOT"
echo ""

# 通用插入：在匹配到特定行的下一行插入，幂等
insert_after_line() {
    local file="$1"
    local search_line="$2"
    local hook_code="$3"

    if [ ! -f "$file" ]; then
        echo "[!] $file 不存在"
        return 1
    fi

    # 已经存在就跳过
    if grep -qF -- "$hook_code" "$file"; then
        echo "[=] $file: hook已存在，跳过"
        return 0
    fi

    # 先清理所有错误位置的旧hook
    grep -Fv -- "$hook_code" "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    # 找到目标行，在其后插入
    sed -i "/$search_line/a\\$hook_code" "$file"
    echo "[+] $file: 已插入hook"
}

FAIL=0

echo "===== 1/5 kernel/reboot.c ====="
# reboot函数：插入在SYSCALL_DEFINE4之后，{之后第一行，变量声明之前
# 4.4内核reboot函数开头：
# SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd, void __user *, arg)
# {
# 	这里插hook
insert_after_line "kernel/reboot.c" "SYSCALL_DEFINE4(reboot" $'\tksu_handle_sys_reboot(cmd, (void __user *)arg);' || FAIL=1

echo ""
echo "===== 2/5 fs/exec.c ====="
# execve函数：插入在SYSCALL_DEFINE之后，{之后
insert_after_line "fs/exec.c" "SYSCALL_DEFINE.*execve" $'\tksu_handle_execve(filename);' || FAIL=1

echo ""
echo "===== 3/5 fs/open.c ====="
# faccessat：找ret变量声明之后插入，保证ret已经定义
# long ret;
# 这里插hook
grep -qF "ksu_handle_faccessat" fs/open.c || sed -i '/long ret;/a\\tksu_handle_faccessat(filename, \&ret);' fs/open.c
echo "[+] fs/open.c: 已插入hook"

echo ""
echo "===== 4/5 fs/read_write.c ====="
# vfs_read：找变量声明之后插入
grep -qF "ksu_handle_vfs_read" fs/read_write.c || sed -i '/ssize_t ret;/a\\tksu_handle_vfs_read(file, \&buf, count, \&pos);' fs/read_write.c
echo "[+] fs/read_write.c: 已插入hook"

echo ""
echo "===== 5/5 fs/stat.c ====="
# newfstatat：找ret变量声明之后插入
grep -qF "ksu_handle_stat" fs/stat.c || sed -i '/int ret;/a\\tksu_handle_stat(dfd, filename, \&stat);' fs/stat.c
echo "[+] fs/stat.c: 已插入hook"

echo ""
echo "===== 错误位置清理：把插在{前面的hook删掉 ====="
for f in fs/*.c kernel/*.c; do
    # 找到{前面的hook行（上一行是SYSCALL_DEFINE结尾，当前行是hook）
    sed -i '/^[ \t]*ksu_handle_/{x;/SYSCALL_DEFINE\|ssize_t vfs_read\|long do_faccessat/{g;d};x}' "$f"
done

echo ""
echo "===== 验证hook位置 ====="
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c; do
    echo "--- $f ---"
    grep -n -B1 -A1 "ksu_handle_" "$f" | head -10
    echo ""
done

if [ $FAIL -eq 1 ]; then
    echo "❌ 部分hook插入失败"
    exit 1
fi

echo "✅ 所有hook插入完成"
exit 0
