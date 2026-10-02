#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
小米6(sagit) 4.4.153 内核 Clang 构建补丁（必须在"内核源码根目录"下执行）。

A) 把 4 处 GCC 专有"嵌套函数"(nested function) 提升为文件级 static 函数。
   Clang 不支持在函数体内定义函数，否则报
   "error: function definition is not allowed here" + 找不到该回调符号。
     - drivers/media/platform/msm/vidc/msm_vidc.c        : close_helper
     - drivers/media/platform/msm/vidc/msm_vidc_common.c : put_inst_helper
     - drivers/media/platform/msm/vidc/msm_vidc_res_parse.c : is_compatible
     - drivers/media/platform/msm/vidc/msm_vidc_res_parse.c : cmp

B) lib/string.c 补齐 bcmp / stpcpy。
   Clang 12+ 的 libcall 优化会把 memcmp 降级成 bcmp、把 sprintf(dest,"%s",str)
   降级成 stpcpy；4.4 内核的 lib/string.c 里没有这两个符号，链接 vmlinux 时报
   "undefined reference to `bcmp' / `stpcpy'"。实现照抄上游提交：
     - commit 5f074f3e192f  "lib/string.c: implement a basic bcmp"
     - commit 1e1b6d63d634  "lib/string.c: implement stpcpy"

所有改动都带幂等判断，可重复执行；任何一处没打上都会以非 0 退出码报错。
"""
import os
import re
import sys

FAIL = 0
VIDC = os.path.join('drivers', 'media', 'platform', 'msm', 'vidc')


def read_text(path):
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fp:
        return fp.read()


def write_text(path, text):
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fp:
        fp.write(text)


def patch(path, pattern, new_text, tag, marker):
    """marker 已存在 => 已修复（幂等）；否则按 pattern 定位整段替换。"""
    global FAIL
    if not os.path.exists(path):
        print('[x] %s：文件不存在 %s' % (tag, path))
        FAIL = 1
        return
    src = read_text(path)
    if marker in src:
        print('[i] %s：已是修复后状态，跳过' % tag)
        return
    m = re.search(pattern, src, re.S)
    if m is None:
        print('[x] %s：未匹配到待修复代码 %s' % (tag, path))
        FAIL = 1
        return
    write_text(path, src[:m.start()] + new_text + src[m.end():])
    print('[v] %s：已修复 %s' % (tag, path))


# ------------------------------------------------------------------ A1
P1 = (r'int msm_vidc_close\(void \*instance\)\n\{\n'
      r'\tvoid close_helper\(struct kref \*kref\)\n'
      r'\t\{\n'
      r'\t\tstruct msm_vidc_inst \*inst = container_of\(kref,\n'
      r'\t\t\t\tstruct msm_vidc_inst, kref\);\n'
      r'\n'
      r'\t\tmsm_vidc_destroy\(inst\);\n'
      r'\t\}\n'
      r'\n')
N1 = ('static void close_helper(struct kref *kref)\n'
      '{\n'
      '\tstruct msm_vidc_inst *inst = container_of(kref,\n'
      '\t\t\tstruct msm_vidc_inst, kref);\n'
      '\n'
      '\tmsm_vidc_destroy(inst);\n'
      '}\n'
      '\n'
      'int msm_vidc_close(void *instance)\n'
      '{\n')

# ------------------------------------------------------------------ A2
P2 = (r'static void put_inst\(struct msm_vidc_inst \*inst\)\n\{\n'
      r'\tvoid put_inst_helper\(struct kref \*kref\)\n'
      r'\t\{\n'
      r'\t\tstruct msm_vidc_inst \*inst = container_of\(kref,\n'
      r'\t\t\t\tstruct msm_vidc_inst, kref\);\n'
      r'\n'
      r'\t\tmsm_vidc_destroy\(inst\);\n'
      r'\t\}\n'
      r'\n')
N2 = ('static void put_inst_helper(struct kref *kref)\n'
      '{\n'
      '\tstruct msm_vidc_inst *inst = container_of(kref,\n'
      '\t\t\tstruct msm_vidc_inst, kref);\n'
      '\n'
      '\tmsm_vidc_destroy(inst);\n'
      '}\n'
      '\n'
      'static void put_inst(struct msm_vidc_inst *inst)\n'
      '{\n')

# ------------------------------------------------------------------ A3
P3 = (r'static inline enum imem_type read_imem_type\(struct platform_device \*pdev\)\n\{\n'
      r'\tbool is_compatible\(char \*compat\)\n'
      r'\t\{\n'
      r'\t\treturn !!of_find_compatible_node\(NULL, NULL, compat\);\n'
      r'\t\}\n'
      r'\n')
N3 = ('static inline bool is_compatible(char *compat)\n'
      '{\n'
      '\treturn !!of_find_compatible_node(NULL, NULL, compat);\n'
      '}\n'
      '\n'
      'static inline enum imem_type read_imem_type(struct platform_device *pdev)\n'
      '{\n')

# ------------------------------------------------------------------ A4
P4 = (r'static int msm_vidc_load_freq_table\(struct msm_vidc_platform_resources \*res\)\n\{\n'
      r'\tint rc = 0;\n'
      r'\tint num_elements = 0;\n'
      r'\tstruct platform_device \*pdev = res->pdev;\n'
      r'\n'
      r'\t/\* A comparator to compare loads \(needed later on\) \*/\n'
      r'\tint cmp\(const void \*a, const void \*b\)\n'
      r'\t\{\n'
      r'\t\t/\* want to sort in reverse so flip the comparison \*/\n'
      r'\t\treturn \(\(struct load_freq_table \*\)b\)->load -\n'
      r'\t\t\t\(\(struct load_freq_table \*\)a\)->load;\n'
      r'\t\}\n'
      r'\n')
N4 = ('static int cmp(const void *a, const void *b)\n'
      '{\n'
      '\t/* want to sort in reverse so flip the comparison */\n'
      '\treturn ((struct load_freq_table *)b)->load -\n'
      '\t\t((struct load_freq_table *)a)->load;\n'
      '}\n'
      '\n'
      'static int msm_vidc_load_freq_table(struct msm_vidc_platform_resources *res)\n'
      '{\n'
      '\tint rc = 0;\n'
      '\tint num_elements = 0;\n'
      '\tstruct platform_device *pdev = res->pdev;\n'
      '\n')

# ------------------------------------------------------------------ B
# 注意：bcmp / stpcpy 必须追加到 lib/string.c 的"文件末尾"（顶层作用域）。
# 不能插到 EXPORT_SYMBOL(memcmp); 后面，因为 arm64 的 asm/string.h 已定义
# __HAVE_ARCH_MEMCMP，那个位置整块都在 #ifndef __HAVE_ARCH_MEMCMP 守卫内，
# 插进去会被整体屏蔽掉，等于没补。文件末尾顶层则不受任何守卫影响。
# memcmp 本身可用：arch/arm64/include/asm/string.h 有
#   #define __HAVE_ARCH_MEMCMP
#   extern int memcmp(const void *, const void *, size_t);
LIBC = os.path.join('lib', 'string.c')
LIBC_MARK = 'mi6build:'
LIBC_ADD = ('/* mi6build: Clang 12+ 的 libcall 优化会把 memcmp 降级成 bcmp，\n'
            ' * 4.4 内核 lib/string.c 里没有该符号，按上游 commit 5f074f3e192f 补齐。\n'
            ' */\n'
            '#ifndef __HAVE_ARCH_BCMP\n'
            'int bcmp(const void *a, const void *b, size_t len)\n'
            '{\n'
            '\treturn memcmp(a, b, len);\n'
            '}\n'
            'EXPORT_SYMBOL(bcmp);\n'
            '#endif\n'
            '\n'
            '/* mi6build: Clang 12+ 会把 sprintf(dest, "%s", str) 降级成 stpcpy，\n'
            ' * 4.4 内核 lib/string.c 里没有该符号，按上游 commit 1e1b6d63d634 补齐。\n'
            ' */\n'
            '#ifndef __HAVE_ARCH_STPCPY\n'
            'char *stpcpy(char *dest, const char *src)\n'
            '{\n'
            '\twhile ((*dest++ = *src++) != 0)\n'
            '\t\t;\n'
            '\treturn dest - 1;\n'
            '}\n'
            'EXPORT_SYMBOL(stpcpy);\n'
            '#endif\n')

# 嵌套函数特征：行首 1 个制表符 + 函数签名 + 下一非空行是单独的 {
NESTED = re.compile(r'^\t(?:static\s+|inline\s+|const\s+|unsigned\s+|signed\s+)?'
                    r'[A-Za-z_][A-Za-z0-9_ \t\*]*[ \t\*]([A-Za-z_][A-Za-z0-9_]*)\s*\([^;]*\)\s*$')

print('=== A. 消除 Clang 不支持的嵌套函数 ===')
patch(os.path.join(VIDC, 'msm_vidc.c'), P1, N1,
      'nested-function close_helper', 'static void close_helper(struct kref *kref)')
patch(os.path.join(VIDC, 'msm_vidc_common.c'), P2, N2,
      'nested-function put_inst_helper', 'static void put_inst_helper(struct kref *kref)')
patch(os.path.join(VIDC, 'msm_vidc_res_parse.c'), P3, N3,
      'nested-function is_compatible', 'static inline bool is_compatible(char *compat)')
patch(os.path.join(VIDC, 'msm_vidc_res_parse.c'), P4, N4,
      'nested-function cmp', 'static int cmp(const void *a, const void *b)')

print('=== B. lib/string.c 补齐 bcmp / stpcpy ===')
if not os.path.exists(LIBC):
    print('[x] lib/string.c：文件不存在 %s' % LIBC)
    FAIL = 1
else:
    _src = read_text(LIBC)
    if LIBC_MARK in _src:
        print('[i] lib/string.c：已是修复后状态，跳过')
    else:
        if not _src.endswith('\n'):
            _src += '\n'
        write_text(LIBC, _src + '\n' + LIBC_ADD)
        print('[v] lib/string.c：已在文件末尾补齐 bcmp / stpcpy')

print('=== C. 复查：vidc 目录已无嵌套函数 ===')
_left = 0
for _root, _dirs, _files in os.walk(VIDC):
    for _fn in _files:
        if not _fn.endswith('.c'):
            continue
        _fp = os.path.join(_root, _fn)
        _lines = read_text(_fp).split('\n')
        for _i, _ln in enumerate(_lines):
            if NESTED.match(_ln):
                _j = _i + 1
                while _j < len(_lines) and _lines[_j].strip() == '':
                    _j += 1
                if _j < len(_lines) and _lines[_j].strip() == '{':
                    print('[x] 仍存在嵌套函数 %s:%d %s' % (_fp, _i + 1, _ln.strip()))
                    _left += 1
if _left:
    FAIL = 1
else:
    print('[v] vidc 目录内已无嵌套函数')

print('=== 结果 ===')
if FAIL:
    print('[x] 补丁未全部生效，请把上面报错发回排查')
    sys.exit(1)
print('[v] 全部补丁生效：嵌套函数已提升，bcmp / stpcpy 已补齐')
