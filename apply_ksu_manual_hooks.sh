#!/bin/bash
# ============================================================
#  apply_ksu_manual_hooks.sh
#  为 KernelSU-Next 4.x 老内核插入 5 处手动 hook 调用点
#  (手动 hook 是 kprobe/syscall-table hook 之外唯一在 4.4 可工作的模式)
#
#  幂等：重复执行不会重复插入；签名与 v3.4.0-legacy 源码一致。
# ============================================================
set -eu

usage() {
    cat <<EOF
Usage:
    bash $0 <kernel_source_root>

示例:
    bash $0 $GITHUB_WORKSPACE/kernel_workspace/android-kernel
EOF
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 1
fi

KROOT="$1"
shift || true

if [ ! -f "$KROOT/Makefile" ]; then
    echo "[✗] $KROOT 不是一个内核源码目录(找不到 Makefile)"
    exit 1
fi

# --------- 1 个原子插入工具：在“某函数定义附近，找到首个 '{' 之后”插入代码 ---------
# 用法：insert_after_func_open <file> <func_pattern> <code_line> [unique_marker]
insert_after_func_open() {
    local file="$1" func_pat="$2" code="$3" marker="${4:-$code}"
    if grep -qF "$marker" "$file"; then
        echo "[=] $(basename "$file"): 已包含 hook 标记，跳过"
        return 0
    fi
    # 注意：变量名不能叫 'func' —— gawk 中 'func' 是内置关键字
    awk -v funcpat="$func_pat" -v code="$code" '
        BEGIN { in_func=0; inserted=0; brace_found=0 }
        {
            if (!inserted) {
                if (!in_func && $0 ~ funcpat) { in_func=1 }
                if (in_func) {
                    # 跳过参数跨行的行，直到找到真正的 { 开括号
                    if ($0 ~ /\{/) {
                        brace_found=1
                    }
                }
            }
            print
            if (inserted) next
            if (brace_found) {
                print code
                inserted=1
                in_func=0; brace_found=0
            }
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    if grep -qF "$marker" "$file"; then
        echo "[+] $(basename "$file"): 已插入 hook"
    else
        echo "[!] $(basename "$file"): 自动插入失败，需要手动插：$code"
        return 1
    fi
}

# --------- 插入点 1: kernel/reboot.c —— reboot 入口（Kbuild 硬性要求） ---------
F1="$KROOT/kernel/reboot.c"
if [ -f "$F1" ]; then
    # 不同 4.4 版本的 reboot syscall 函数名不完全一致，尝试最常见的几种
    hook_inserted=0
    if grep -q "SYSCALL_DEFINE4(reboot" "$F1"; then
        insert_after_func_open "$F1" "SYSCALL_DEFINE4[[:space:]]*\\(reboot" \
            "\tksu_handle_sys_reboot(cmd, __user arg);" \
            "ksu_handle_sys_reboot(cmd" && hook_inserted=1
    fi
    if [ "$hook_inserted" = "0" ] && grep -qE '^[[:space:]]*(asmlinkage[[:space:]]+)?(long|SYSCALL_DEFINE[^)]*)[[:space:]]*sys_reboot' "$F1"; then
        insert_after_func_open "$F1" "sys_reboot" \
            "\tksu_handle_sys_reboot(cmd, __user arg);" \
            "ksu_handle_sys_reboot(cmd" && hook_inserted=1
    fi
    if [ "$hook_inserted" = "0" ]; then
        echo "[!] $F1 中未找到 reboot syscall，请手动插入 ksu_handle_sys_reboot"
        return 1
    fi
else
    echo "[!] 缺失 $F1"
fi

# --------- 插入点 2: fs/exec.c —— do_execveat_common / do_execve ---------
F2="$KROOT/fs/exec.c"
if [ -f "$F2" ]; then
    if grep -q "static int do_execveat_common" "$F2"; then
        # legacy 分支 4.x 兼容代码要求这里调用 ksu_handle_execve(filename)
        insert_after_func_open "$F2" "do_execveat_common" \
            "\tksu_handle_execve(filename);" \
            "ksu_handle_execve(filename)"
    elif grep -q "do_execve(" "$F2"; then
        insert_after_func_open "$F2" "do_execve(" \
            "\tksu_handle_execve(filename);" \
            "ksu_handle_execve(filename)"
    else
        echo "[!] $F2 未找到 do_execve/do_execveat_common，请手动处理"
    fi
fi

# --------- 插入点 3: fs/open.c —— faccessat / do_faccessat ---------
F3="$KROOT/fs/open.c"
if [ -f "$F3" ]; then
    # legacy 期望签名：ksu_handle_faccessat(filename, &ret)
    # 插在 ret 返回处之前 —— 这里用最直接的方法：在 return 前插
    if grep -q "SYSCALL_DEFINE2\\(faccessat" "$F3" || grep -q "SYSCALL_DEFINE3\\(faccessat" "$F3"; then
        if ! grep -q "ksu_handle_faccessat" "$F3"; then
            # 在第一个出现 "long ret" 后的函数体内，return 之前插入（最常见于 4.4）
            # 使用 sed：定位 SYSCALL_DEFINE.*faccessat 的 { 后，在其 return 语句之前插入
            python3 - "$F3" <<'PYEOF'
import sys, re
p=sys.argv[1]
s=open(p).read()
# 匹配 faccessat syscall 的函数体，并在其最后一个 return 前插入
marker="ksu_handle_faccessat(filename, &ret);"
if marker in s:
    sys.exit(0)
# 找到 faccessat 相关 SYSCALL_DEFINE 开始位置
m=re.search(r'(SYSCALL_DEFINE[234]\(faccessat[^{]*\{)', s)
if not m:
    print("[!] 未找到 faccessat syscall，请手动插入 ksu_handle_faccessat")
    sys.exit(0)
start=m.end()
depth=1; i=start
while i<len(s) and depth>0:
    if s[i]=='{': depth+=1
    elif s[i]=='}': depth-=1
    i+=1
body=s[start:i-1]
# 在最后一个 return 之前插入 hook
last_ret=body.rfind("return ")
if last_ret>=0:
    # 向前找到该行开头
    line_start=body.rfind("\n",0,last_ret)+1
    indent=body[line_start:last_ret]
    new_body=body[:line_start]+indent+marker+"\n"+body[line_start:]
    s=s[:start]+new_body+s[i-1:]
    open(p,'w').write(s)
    print("[+] fs/open.c: 已插入 ksu_handle_faccessat(filename, &ret);")
else:
    print("[!] fs/open.c: 在 faccessat 中未找到 return，请手动插入")
PYEOF
        else
            echo "[=] fs/open.c: 已包含 hook，跳过"
        fi
    else
        echo "[!] $F3 未找到 faccessat syscall"
    fi
fi

# --------- 插入点 4: fs/read_write.c —— vfs_read ---------
F4="$KROOT/fs/read_write.c"
if [ -f "$F4" ]; then
    # legacy 分支真实签名（4 参）：ksu_handle_vfs_read(file, &buf, count, &pos)
    if grep -q "^ssize_t vfs_read" "$F4" || grep -q "ssize_t vfs_read(" "$F4"; then
        insert_after_func_open "$F4" "^ssize_t vfs_read" \
            "\tksu_handle_vfs_read(file, &buf, count, &pos);" \
            "ksu_handle_vfs_read(file, &buf, count, &pos)"
    else
        echo "[!] $F4 未找到 vfs_read，请手动插入 ksu_handle_vfs_read(file, &buf, count, &pos);"
    fi
fi

# --------- 插入点 5: fs/stat.c —— newfstatat ---------
F5="$KROOT/fs/stat.c"
if [ -f "$F5" ]; then
    if grep -q "SYSCALL_DEFINE[24]\\(newfstatat" "$F5"; then
        if ! grep -q "ksu_handle_stat" "$F5"; then
            python3 - "$F5" <<'PYEOF'
import sys, re
p=sys.argv[1]
s=open(p).read()
marker='ksu_handle_stat('
if marker in s:
    sys.exit(0)
m=re.search(r'(SYSCALL_DEFINE[24]\(newfstatat[^{]*\{)', s)
if not m:
    print("[!] 未找到 newfstatat syscall，请手动插入 ksu_handle_stat")
    sys.exit(0)
start=m.end()
depth=1; i=start
while i<len(s) and depth>0:
    if s[i]=='{': depth+=1
    elif s[i]=='}': depth-=1
    i+=1
body=s[start:i-1]
# 选择插入到 error 返回前；简单起见：在第一个 return 之前
ret_pos=body.find("return ")
if ret_pos>=0:
    line_start=body.rfind("\n",0,ret_pos)+1
    indent=body[line_start:ret_pos]
    hook=indent+"ksu_handle_stat(dfd, filename, &stat);\n"
    new_body=body[:line_start]+hook+body[line_start:]
    s=s[:start]+new_body+s[i-1:]
    open(p,'w').write(s)
    print("[+] fs/stat.c: 已插入 ksu_handle_stat(dfd, filename, &stat);")
else:
    print("[!] fs/stat.c: 在 newfstatat 中未找到 return，请手动插入")
PYEOF
        else
            echo "[=] fs/stat.c: 已包含 hook，跳过"
        fi
    else
        echo "[!] $F5 未找到 newfstatat syscall"
    fi
fi

echo ""
echo "================================================================"
echo "[✓] 手动 hook 插入流程执行完成。请在编译日志中确认没有 "
echo "    \"Please add manual hooks for KernelSU\" 错误。"
echo "[!] 注意：insert_after_func_open 基于函数首个 '{' 后插入，若"
echo "    内核源码与常见 4.4 布局差异较大，请手工检查上述 5 个调用点。"
echo "================================================================"
