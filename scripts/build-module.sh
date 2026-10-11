#!/bin/bash
# =============================================================================
#  iStoreOS kmod-nft-queue 交叉编译主脚本
#
#  在容器内执行（WORKDIR=/build），完整流程：
#    1. 浅克隆 iStoreOS 源码（指定分支）
#    2. feeds update / install
#    3. 种子 .config + make defconfig   ← 只能这么做，命令行传 CONFIG_TARGET_* 无效
#    4. 打开内核 CONFIG_NFT_QUEUE=m，并打开 BTF（必须！否则 insmod 段错误）
#    5. 编译 OpenWrt 自带 pahole 1.31（BTF 生成的前提工具）
#    6. make download / toolchain/install / target/linux/compile / package/kernel/linux/compile
#    7. 收集 nft_queue.ko 与 apk/ipk 包到 /build/out
#
#  环境变量（全部可选，有默认值）：
#    BRANCH        iStoreOS 分支        默认 istoreos-25.12
#    TARGET        target 名            默认 amlogic
#    SUBTARGET     subtarget 名         默认 meson
#    KERNEL_CONFIG target 内核配置文件  默认 config-6.12
#    NPROC         并行度               默认 nproc
#    BUILD_PROXY   http 代理            默认空（GitHub Actions 上不需要）
#    OUT_DIR       产物输出目录         默认 /build/out
#
#  ★ BTF 说明（本项目最关键的坑，见 README「坑 11」）
#    iStoreOS 官方内核开启了 CONFIG_DEBUG_INFO_BTF。内核在 load_module 时会读模块的
#    .BTF 段，若模块没有 BTF 或 BTF 非法，会在 caches_clean_inval_pou 处 Oops
#    （dmesg: "module has no kallsyms" + 段错误）。
#    因此必须让模块编出 .BTF，三个条件缺一不可：
#      (a) 顶层 .config: KERNEL_DEBUG_INFO_REDUCED 关 + KERNEL_DEBUG_INFO_BTF=y
#      (b) 种子文件 target/linux/generic/config-<ver>: CONFIG_DEBUG_INFO_BTF=y
#      (c) 用 OpenWrt 自带 pahole 1.31（tools/dwarves，CONFIG_DWARVES=y）
# =============================================================================
set -euo pipefail

BRANCH="${BRANCH:-istoreos-25.12}"
TARGET="${TARGET:-amlogic}"
SUBTARGET="${SUBTARGET:-meson}"
KERNEL_CONFIG="${KERNEL_CONFIG:-config-6.12}"
NPROC="${NPROC:-$(nproc)}"
OUT_DIR="${OUT_DIR:-/build/out}"
SRC_DIR="${SRC_DIR:-/build/istoreos}"
KERNEL_MODULE="nft_queue"          # 产出的 .ko 名
PKG_NAME="kmod-nft-queue"
ENABLE_BTF="${ENABLE_BTF:-1}"      # 设为 0 可跳过 BTF（不推荐）

# ---------------------------------------------------------------------------
# 代理（仅在国内自建环境需要；GitHub Actions 留空即可）
# ---------------------------------------------------------------------------
if [ -n "${BUILD_PROXY:-}" ]; then
    export http_proxy="$BUILD_PROXY"  https_proxy="$BUILD_PROXY"
    export HTTP_PROXY="$BUILD_PROXY"  HTTPS_PROXY="$BUILD_PROXY"
    export no_proxy="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.local"
    export NO_PROXY="$no_proxy"
    git config --global http.proxy  "$BUILD_PROXY" || true
    git config --global https.proxy "$BUILD_PROXY" || true
    echo "[i] 已启用代理: $BUILD_PROXY"
fi

# 以 root 跑构建的必要开关（GNU tar/autoconf 的 root 检查）
export FORCE_UNSAFE_CONFIGURE=1

step() { echo; echo "==================== $* ===================="; }

# ---------------------------------------------------------------------------
# Kconfig 文件读写小工具
# ---------------------------------------------------------------------------
kcfg_set() {   # kcfg_set <file> <KEY> <val>
    local f="$1" k="$2" v="$3"
    [ -f "$f" ] || return 0
    if grep -qE "^# ?${k} is not set" "$f"; then
        sed -i "s|^# ?${k} is not set|${k}=${v}|" "$f"
    elif grep -qE "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    else
        echo "${k}=${v}" >> "$f"
    fi
}
kcfg_unset() { # kcfg_unset <file> <KEY>
    local f="$1" k="$2"
    [ -f "$f" ] || return 0
    if grep -qE "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|# ${k} is not set|" "$f"
    elif ! grep -qE "^# ?${k} is not set" "$f"; then
        echo "# ${k} is not set" >> "$f"
    fi
}

# ---------------------------------------------------------------------------
# 1. 取源码
# ---------------------------------------------------------------------------
step "1/7 克隆 iStoreOS 源码 (branch=$BRANCH)"
mkdir -p /build
if [ -d "$SRC_DIR/.git" ]; then
    echo "[i] 源码已存在，更新中"
    git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
else
    git clone --depth=1 -b "$BRANCH" \
        https://github.com/istoreos/istoreos.git "$SRC_DIR"
fi
git -C "$SRC_DIR" log --oneline -1
echo "[i] HEAD=$(git -C "$SRC_DIR" rev-parse HEAD)"

cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# 2. feeds
# ---------------------------------------------------------------------------
step "2/7 更新并安装 feeds"
./scripts/feeds update -a 2>&1 | tail -15
./scripts/feeds install -a 2>&1 | tail -10

# ---------------------------------------------------------------------------
# 3. 种子 .config + defconfig
#    ⚠️ 坑：`make defconfig CONFIG_TARGET_amlogic=y` 不生效，
#       必须写种子 .config 再 make defconfig。
# ---------------------------------------------------------------------------
step "3/7 生成 .config（种子配置 + defconfig）"
[ -f .config ] && cp .config ".config.bak.$(date +%s)" || true
rm -f .config

cat > .config <<EOF
CONFIG_TARGET_${TARGET}=y
CONFIG_TARGET_${TARGET}_${SUBTARGET}=y
CONFIG_PACKAGE_${PKG_NAME}=m
CONFIG_PACKAGE_kmod-nft-core=m
CONFIG_PACKAGE_kmod-nfnetlink-queue=m
EOF

if [ "$ENABLE_BTF" = "1" ]; then
    # ★ 关键：BTF 必须用 KERNEL_ 前缀在顶层 .config 打开。
    #   iStoreOS 顶层用 CONFIG_KERNEL_* 映射到内核 CONFIG_DEBUG_INFO_*；
    #   依赖链要求 KERNEL_DEBUG_INFO_REDUCED 必须先关（见 config/Config-kernel.in）。
    cat >> .config <<'EOF'
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
CONFIG_DWARVES=y
EOF
    # 预填 6.12 新增 choice，避免 syncconfig 在新项上卡死（同 README 坑 8）
    echo "CONFIG_KERNEL_TRANSPARENT_HUGEPAGE_NEVER=y" >> .config
fi

# ★ 关键：struct module 布局必须与目标内核一致（见 README「坑 12」）。
#   目标内核开了 tracing/perf/kprobes/bpf-events，这些会在 struct module 里
#   加约 512 字节的字段。缺了它们，insmod 会静默死循环（进程永远 S 态）。
cat >> .config <<'EOF'
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_FTRACE=y
CONFIG_KERNEL_KPROBES=y
CONFIG_KERNEL_BPF_EVENTS=y
EOF

make defconfig 2>&1 | tail -12

# ⚠️ make defconfig 有时会把上面这些 KERNEL_* 重置回 not set，再补一次并核对
restore_kernel_opts() {
    local f=".config" k
    for k in CONFIG_KERNEL_PERF_EVENTS CONFIG_KERNEL_FTRACE \
             CONFIG_KERNEL_KPROBES CONFIG_KERNEL_BPF_EVENTS; do
        sed -i "s|^# *${k} is not set|${k}=y|" "$f"
    done
    if [ "$ENABLE_BTF" = "1" ]; then
        sed -i 's|^# *CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set|CONFIG_KERNEL_DEBUG_INFO_REDUCED=|' "$f"
        sed -i 's|^CONFIG_KERNEL_DEBUG_INFO_REDUCED=.*|# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set|' "$f"
        for k in CONFIG_KERNEL_DEBUG_INFO_BTF CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES CONFIG_DWARVES; do
            sed -i "s|^# *${k} is not set|${k}=y|" "$f"
        done
    fi
}
restore_kernel_opts

echo "[i] target 检查:"
grep -E "^CONFIG_TARGET_${TARGET}|^CONFIG_TARGET_BOARD|^CONFIG_TARGET_SUBTARGET|^CONFIG_TARGET_ARCH" .config || true
echo "[i] 包检查:"
grep -E "CONFIG_PACKAGE_${PKG_NAME}|CONFIG_PACKAGE_kmod-nft-core|CONFIG_PACKAGE_kmod-nfnetlink-queue" .config || true
echo "[i] BTF 检查（顶层）:"
grep -E "CONFIG_KERNEL_DEBUG_INFO|CONFIG_DWARVES" .config || true
echo "[i] N1 设备定义:"
grep -E "DEVICE_phicomm_n1" .config || echo "(未自动选中，不影响内核模块编译)"

# ---------------------------------------------------------------------------
# 4. 打开内核 NFT_QUEUE + BTF（改「种子文件」，这是 defconfig 之后仍会被内核采用的路径）
#    ⚠️ 坑：KernelPackage/nft-queue 在 netfilter.mk 里存在，但被 KCONFIG 关掉，
#       必须手工把 CONFIG_NFT_QUEUE=m 写进 target/linux/<t>/<s>/config-<ver>。
#    ⚠️ 坑：BTF 同理 —— 必须改 target/linux/generic/config-<ver>，只改顶层 .config 不够。
# ---------------------------------------------------------------------------
step "4/7 启用内核 CONFIG_NFT_QUEUE + BTF"

KCFG="target/linux/${TARGET}/${SUBTARGET}/${KERNEL_CONFIG}"
if [ ! -f "$KCFG" ]; then
    echo "[!] 找不到 $KCFG，尝试自动探测"
    KCFG="$(ls target/linux/${TARGET}/${SUBTARGET}/config-* 2>/dev/null | tail -1 || true)"
fi
if [ -z "${KCFG:-}" ] || [ ! -f "$KCFG" ]; then
    echo "[x] 无法定位内核 config 文件，退出"; exit 1
fi
echo "[i] target 内核配置文件: $KCFG"

if grep -qE '^CONFIG_NFT_QUEUE=' "$KCFG"; then
    sed -i 's/^CONFIG_NFT_QUEUE=.*/CONFIG_NFT_QUEUE=m/' "$KCFG"
    echo "[i] 已把 CONFIG_NFT_QUEUE 改为 m"
else
    echo "CONFIG_NFT_QUEUE=m" >> "$KCFG"
    echo "[i] 已追加 CONFIG_NFT_QUEUE=m"
fi
grep -n 'CONFIG_NFT_QUEUE' "$KCFG"

# BTF：改 generic 与 target 两份种子文件
GENCFG="target/linux/generic/${KERNEL_CONFIG}"
if [ "$ENABLE_BTF" = "1" ]; then
    for f in "$GENCFG" "$KCFG"; do
        [ -f "$f" ] || continue
        echo "[i] 写入 BTF 配置到 $f"
        kcfg_set   "$f" CONFIG_DEBUG_INFO y
        kcfg_unset "$f" CONFIG_DEBUG_INFO_NONE
        kcfg_unset "$f" CONFIG_DEBUG_INFO_REDUCED
        kcfg_set   "$f" CONFIG_DEBUG_INFO_BTF y
        kcfg_set   "$f" CONFIG_DEBUG_INFO_BTF_MODULES y
        kcfg_set   "$f" CONFIG_MODULE_ALLOW_BTF_MISMATCH y
        kcfg_set   "$f" CONFIG_DEBUG_INFO_COMPRESSED_NONE y
        kcfg_unset "$f" CONFIG_DEBUG_INFO_COMPRESSED_ZLIB
        kcfg_unset "$f" CONFIG_DEBUG_INFO_COMPRESSED_ZSTD
        kcfg_set   "$f" CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT y
        kcfg_unset "$f" CONFIG_DEBUG_INFO_SPLIT
        # 预填 6.12 新增 choice，彻底避免 syncconfig 死锁
        kcfg_set   "$f" CONFIG_TRANSPARENT_HUGEPAGE_NEVER y
        kcfg_unset "$f" CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS
        kcfg_unset "$f" CONFIG_TRANSPARENT_HUGEPAGE_MADVISE
        echo "[i]   $f ->"
        grep -nE 'DEBUG_INFO_BTF|DEBUG_INFO_REDUCED|^CONFIG_DEBUG_INFO=|TRANSPARENT_HUGEPAGE' "$f" | sed 's/^/      /'
    done
else
    echo "[i] ENABLE_BTF=0，跳过 BTF（产出的模块可能无法 insmod）"
fi

# 确认包定义确实在源码里
echo "[i] KernelPackage/nft-queue 定义位置:"
grep -n 'define KernelPackage/nft-queue' package/kernel/linux/modules/netfilter.mk || true

# ---------------------------------------------------------------------------
# 4.5 内核种子文件：补齐 tracing/perf/kprobes/bpf-events（struct module 布局对齐）
#     ⚠️ 坑 12：目标内核这些项 =y，会在 struct module 里多出 ~512 字节字段。
#        缺失 → insmod 静默死循环。这里直接在种子文件里写内核级 CONFIG_*。
# ---------------------------------------------------------------------------
step "4.5/7 对齐 struct module 布局（tracing / perf / kprobes / bpf-events）"
TRACE_OPTS='
CONFIG_PERF_EVENTS=y
CONFIG_HW_PERF_EVENTS=y
CONFIG_FTRACE=y
CONFIG_TRACING=y
CONFIG_TRACEPOINTS=y
CONFIG_EVENT_TRACING=y
CONFIG_DYNAMIC_EVENTS=y
CONFIG_TRACING_SUPPORT=y
CONFIG_GENERIC_TRACER=y
CONFIG_TRACE_CLOCK=y
CONFIG_CONTEXT_SWITCH_TRACER=y
CONFIG_STACKTRACE=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KRETPROBES=y
CONFIG_BPF_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
'
for f in "$GENCFG" "${KCFG:-}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    echo "[i] 写入 tracing 配置到 $f"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%%=*}"; val="${line#*=}"
        kcfg_set "$f" "$key" "$val"
    done <<EOF
$TRACE_OPTS
EOF
done
echo "[i] 校验 generic 种子文件:"
grep -nE '^CONFIG_(PERF_EVENTS|FTRACE|TRACING|TRACEPOINTS|EVENT_TRACING|KPROBES|KPROBE_EVENTS|BPF_EVENTS)=' "$GENCFG" 2>/dev/null | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
# 4.6 强制内核 .config 重新生成
#     ⚠️ 不能直接 rm 内核 build_dir 的 .config —— OpenWrt 会报
#        "No rule to make target '.../.config'"。删 .configured 标记即可。
# ---------------------------------------------------------------------------
step "4.6/7 触发内核 .config 重新生成"
KDIR_PRE="$(ls -d "$SRC_DIR"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -1)"
if [ -n "$KDIR_PRE" ]; then
    rm -f "$KDIR_PRE/.configured" "$KDIR_PRE/.config.prev" 2>/dev/null || true
    echo "[i] 已删除 $KDIR_PRE/.configured"
else
    echo "[i] 内核目录尚未建立（首次编译），跳过"
fi

# ---------------------------------------------------------------------------
# 5. 编译 OpenWrt 自带 pahole（BTF 生成工具，1.31 与内核 PAHOLE_VERSION 对齐）
#    ⚠️ 坑：Debian 自带的 pahole 只有 1.24，低于内核对 CONFIG_PAHOLE_VERSION=131
#       的期望。必须用 tools/dwarves 自己编一份，否则 BTF 生成会告警/失败。
# ---------------------------------------------------------------------------
if [ "$ENABLE_BTF" = "1" ]; then
    step "5/7 编译 BTF 工具 pahole (tools/dwarves 1.31)"
    set +e
    make -j"$NPROC" tools/dwarves/compile > /build/pahole.log 2>&1
    rc=$?
    set -e
    tail -10 /build/pahole.log
    if [ "$rc" -ne 0 ]; then
        echo "[x] pahole 编译失败 (rc=$rc)，完整日志 /build/pahole.log"; exit 1
    fi
    export PATH="$SRC_DIR/staging_dir/host/bin:$PATH"
    echo "[i] $(command -v pahole) -> $(pahole --version)"
else
    step "5/7 跳过 pahole（ENABLE_BTF=0）"
fi

# ---------------------------------------------------------------------------
# 6. 编译
# ---------------------------------------------------------------------------
step "6/7 开始编译 (NPROC=$NPROC)"

# ⚠️ 注意：下面每步都显式捕获 make 的退出码。
#     不要写成 `make ... | tail -N` 后检查 $? —— 那取到的是 tail 的退出码，恒为 0，
#     会掩盖真实失败（本项目实测踩过这个坑）。
run_make() {
    local label="$1"; shift
    local logf="/build/${label//\//_}.log"
    echo "--- $label ---"
    set +e
    make "$@" > "$logf" 2>&1
    local rc=$?
    set -e
    tail -25 "$logf"
    if [ "$rc" -ne 0 ]; then
        echo "!!! $label 失败 (rc=$rc)，完整日志: $logf"
        echo "!!! 末 60 行："
        tail -60 "$logf"
        BUILD_FAILED=1
    fi
    return $rc
}

BUILD_FAILED=0
run_make "6.1 download" -j"$NPROC" download || true
run_make "6.2 toolchain/install" -j"$NPROC" toolchain/install || { echo "[x] toolchain 失败，后续无法继续"; exit 1; }
run_make "6.3 target/linux/compile" -j"$NPROC" target/linux/compile || { echo "[x] 内核编译失败，无法产出模块"; exit 1; }
run_make "6.4 package/kernel/linux/compile" -j"$NPROC" package/kernel/linux/compile || true

# ---------------------------------------------------------------------------
# 7. 收集产物 + BTF 校验
# ---------------------------------------------------------------------------
step "7/7 收集产物 → $OUT_DIR"
mkdir -p "$OUT_DIR"

echo "[i] 搜索 ${KERNEL_MODULE}.ko ..."
find "$SRC_DIR/build_dir" -name "${KERNEL_MODULE}.ko" -print -exec cp -v {} "$OUT_DIR/" \; 2>/dev/null || true

echo "[i] 搜索 ${PKG_NAME} apk/ipk ..."
find "$SRC_DIR/bin" -name "*${PKG_NAME}*" -print -exec cp -v {} "$OUT_DIR/" \; 2>/dev/null || true

# iStoreOS 25.12 用 apk（新版）也可能产出 ipk，两个都收
find "$SRC_DIR/bin/packages" -name '*nft*queue*' -exec cp -v {} "$OUT_DIR/" \; 2>/dev/null || true

echo
echo "==================== 产物清单 ===================="
ls -la "$OUT_DIR" 2>/dev/null || echo "(空)"
echo
echo "nft_queue.ko 详情（vermagic 必须与 N1 内核一致；BTF 段必须存在）:"
for f in "$OUT_DIR"/*.ko; do
    [ -f "$f" ] || continue
    echo "  $f"
    strings "$f" 2>/dev/null | grep -E '^vermagic=' || true
    if [ "$ENABLE_BTF" = "1" ]; then
        btf_size="$(readelf -S -W "$f" 2>/dev/null | awk '$2==".BTF"{print $6; fnd=1} END{if(!fnd) print "NONE"}')"
        echo "    .BTF = $btf_size"
        if [ "$btf_size" = "NONE" ]; then
            echo "    [x] 缺少 .BTF！该模块在 iStoreOS 上 insmod 会 Oops"
        fi
    fi
    # struct module 大小（必须等于目标内核的 1216；704 说明 tracing 选项没打开）
    tm="$(readelf -sW "$f" 2>/dev/null | awk '$NF=="__this_module"{print $3; fnd=1} END{if(!fnd) print "NONE"}')"
    echo "    __this_module size = $tm   (目标内核应为 1216)"
    if [ "$tm" != "NONE" ] && [ "$tm" -lt 1216 ] 2>/dev/null; then
        echo "    [x] struct module 布局偏小 → tracing/perf/kprobes/bpf-events 未对齐，insmod 会静默挂死"
    fi
done
echo
echo "关键内核配置（内核 build_dir 的 .config）:"
_kdir="$(ls -d "$SRC_DIR"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -1)"
if [ -n "$_kdir" ] && [ -f "$_kdir/.config" ]; then
    grep -E '^CONFIG_(TRACEPOINTS|TRACING|EVENT_TRACING|FTRACE|KPROBES|KPROBE_EVENTS|BPF_EVENTS|PERF_EVENTS|DEBUG_INFO_BTF|DEBUG_INFO_REDUCED|PAHOLE_VERSION)=' \
        "$_kdir/.config" | sed 's/^/  /'
fi

if ! ls "$OUT_DIR"/*.ko >/dev/null 2>&1; then
    echo
    echo "[x] 未找到 ${KERNEL_MODULE}.ko —— 编译可能失败，请检查上面 6.4 的输出"
    exit 1
fi

if [ "$BUILD_FAILED" -ne 0 ]; then
    echo
    echo "[!] 有步骤返回非零，请检查上面日志"
    exit 1
fi

echo
echo "[✓] 完成 $(date)"
