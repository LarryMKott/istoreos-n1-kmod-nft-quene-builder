#!/bin/bash
# =============================================================================
#  iStoreOS kmod-nft-queue 交叉编译主脚本
#
#  在容器内执行（WORKDIR=/build），完整流程：
#    1. 浅克隆 iStoreOS 源码（指定分支）
#    2. feeds update / install
#    3. 种子 .config + make defconfig   ← 只能这么做，命令行传 CONFIG_TARGET_* 无效
#    4. 给 target 内核 config 追加 CONFIG_NFT_QUEUE=m
#    5. make download / toolchain/install / target/linux/compile / package/kernel/linux/compile
#    6. 收集 nft_queue.ko 与 apk/ipk 包到 /build/out
#
#  环境变量（全部可选，有默认值）：
#    BRANCH        iStoreOS 分支        默认 istoreos-25.12
#    TARGET        target 名            默认 amlogic
#    SUBTARGET     subtarget 名         默认 meson
#    KERNEL_CONFIG target 内核配置文件  默认 config-6.12
#    NPROC         并行度               默认 nproc
#    BUILD_PROXY   http 代理            默认空（GitHub Actions 上不需要）
#    OUT_DIR       产物输出目录         默认 /build/out
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
# 1. 取源码
# ---------------------------------------------------------------------------
step "1/6 克隆 iStoreOS 源码 (branch=$BRANCH)"
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
step "2/6 更新并安装 feeds"
./scripts/feeds update -a 2>&1 | tail -15
./scripts/feeds install -a 2>&1 | tail -10

# ---------------------------------------------------------------------------
# 3. 种子 .config + defconfig
#    ⚠️ 坑：`make defconfig CONFIG_TARGET_amlogic=y` 不生效，
#       必须写种子 .config 再 make defconfig。
# ---------------------------------------------------------------------------
step "3/6 生成 .config（种子配置 + defconfig）"
[ -f .config ] && cp .config ".config.bak.$(date +%s)" || true
rm -f .config

cat > .config <<EOF
CONFIG_TARGET_${TARGET}=y
CONFIG_TARGET_${TARGET}_${SUBTARGET}=y
CONFIG_PACKAGE_${PKG_NAME}=m
CONFIG_PACKAGE_kmod-nft-core=m
CONFIG_PACKAGE_kmod-nfnetlink-queue=m
EOF

make defconfig 2>&1 | tail -12

echo "[i] target 检查:"
grep -E "^CONFIG_TARGET_${TARGET}|^CONFIG_TARGET_BOARD|^CONFIG_TARGET_SUBTARGET|^CONFIG_TARGET_ARCH" .config || true
echo "[i] 包检查:"
grep -E "CONFIG_PACKAGE_${PKG_NAME}|CONFIG_PACKAGE_kmod-nft-core|CONFIG_PACKAGE_kmod-nfnetlink-queue" .config || true
echo "[i] N1 设备定义:"
grep -E "DEVICE_phicomm_n1" .config || echo "(未自动选中，不影响内核模块编译)"

# ---------------------------------------------------------------------------
# 4. 给 target 内核 config 打开 NFT_QUEUE
#    ⚠️ 坑：KernelPackage/nft-queue 在 netfilter.mk 里存在，但被 KCONFIG 关掉，
#       必须手工把 CONFIG_NFT_QUEUE=m 追加进 target/linux/<t>/<s>/config-<ver>。
# ---------------------------------------------------------------------------
step "4/6 启用内核 CONFIG_NFT_QUEUE"
KCFG="target/linux/${TARGET}/${SUBTARGET}/${KERNEL_CONFIG}"
if [ ! -f "$KCFG" ]; then
    echo "[!] 找不到 $KCFG，尝试自动探测"
    KCFG="$(ls target/linux/${TARGET}/${SUBTARGET}/config-* 2>/dev/null | tail -1 || true)"
fi
if [ -z "${KCFG:-}" ] || [ ! -f "$KCFG" ]; then
    echo "[x] 无法定位内核 config 文件，退出"; exit 1
fi
echo "[i] 内核配置文件: $KCFG"

if grep -qE '^CONFIG_NFT_QUEUE=' "$KCFG"; then
    sed -i 's/^CONFIG_NFT_QUEUE=.*/CONFIG_NFT_QUEUE=m/' "$KCFG"
    echo "[i] 已把 CONFIG_NFT_QUEUE 改为 m"
else
    echo "CONFIG_NFT_QUEUE=m" >> "$KCFG"
    echo "[i] 已追加 CONFIG_NFT_QUEUE=m"
fi
grep -n 'CONFIG_NFT_QUEUE' "$KCFG"

# 确认包定义确实在源码里
echo "[i] KernelPackage/nft-queue 定义位置:"
grep -n 'define KernelPackage/nft-queue' package/kernel/linux/modules/netfilter.mk || true

# ---------------------------------------------------------------------------
# 4.5 让内核配置一次性稳定（关键！见 README「坑 8」）
#
# ⚠️ 坑：iStoreOS 的 config-<ver> 是给旧内核准备的。当源码树内核版本较新时
#     （如 6.12.94 新增了 CONFIG_TRANSPARENT_HUGEPAGE_NEVER 这个 choice 成员），
#     内核 syncconfig 会在非交互环境遇到 NEW 项，卡在
#         "Restart config...  choice[1-3?]: "
#     读不到 stdin 而报错退出：
#         scripts/kconfig/Makefile:85: syncconfig Error 1
#         Makefile:769: include/config/auto.conf.cmd: No such file or directory
#     表现为 target/linux/compile 与 package/kernel/linux/compile 双双"秒退"失败。
#
#     修复：用默认值补齐所有 NEW 项（olddefconfig）。
#     注意 olddefconfig 需要内核 build_dir 已存在 —— 而它由 target/linux/compile
#     首次创建。所以流程是：先试跑 target/linux → 生成内核目录 → olddefconfig → 重跑。
# ---------------------------------------------------------------------------
step "4.5/6 稳定内核配置（补齐 NEW 项，避免 syncconfig 卡死）"

prepare_kernel_dir() {
    # 试跑 target/linux/compile 以生成内核构建目录（预期可能在此失败）
    set +e
    make -j"$NPROC" target/linux/compile >/tmp/kprep.log 2>&1
    set -e
    ls -d "$SRC_DIR"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -1
}

fix_kernel_config() {
    local kdir="$1"
    [ -n "$kdir" ] && [ -d "$kdir" ] || return 1

    local tc_bin
    tc_bin="$(ls -d "$SRC_DIR"/staging_dir/toolchain-*/bin 2>/dev/null | head -1)"
    [ -n "$tc_bin" ] && export PATH="$tc_bin:$SRC_DIR/staging_dir/host/bin:$PATH"

    if ! command -v aarch64-openwrt-linux-musl-gcc >/dev/null 2>&1; then
        echo "[!] 工具链不在 PATH，无法执行 olddefconfig"
        return 1
    fi

    echo "[i] 内核构建目录: $kdir"
    echo "[i] 工具链: $(aarch64-openwrt-linux-musl-gcc --version | head -1)"
    # yes "" 提供空行，使任何残留交互提示都取默认值
    set +e
    ( cd "$kdir" && yes "" | make ARCH=arm64 \
        CROSS_COMPILE=aarch64-openwrt-linux-musl- olddefconfig 2>&1 | tail -10 )
    local rc=$?
    set -e
    echo "[i] olddefconfig rc=$rc，关键项校验:"
    ( cd "$kdir" && grep -nE '^CONFIG_(NFT_QUEUE|TRANSPARENT_HUGEPAGE)' .config ) || true
    return $rc
}

KDIR="$(ls -d "$SRC_DIR"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -1)"
if [ -z "$KDIR" ]; then
    echo "[i] 内核目录不存在，先试跑一次 target/linux/compile 生成它"
    KDIR="$(prepare_kernel_dir)"
fi

if [ -n "$KDIR" ]; then
    fix_kernel_config "$KDIR" || echo "[!] 内核配置稳定化未成功，5.3 可能失败"
else
    echo "[!] 仍无法定位内核目录，跳过（5.3 若报 syncconfig 错误即为此因）"
fi

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
step "5/6 开始编译 (NPROC=$NPROC)"

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
run_make "5.1 download" -j"$NPROC" download || true
run_make "5.2 toolchain/install" -j"$NPROC" toolchain/install || { echo "[x] toolchain 失败，后续无法继续"; exit 1; }
run_make "5.3 target/linux/compile" -j"$NPROC" target/linux/compile || echo "[!] target/linux 失败，仍尝试 package/kernel"
run_make "5.4 package/kernel/linux/compile" -j"$NPROC" package/kernel/linux/compile || true

# ---------------------------------------------------------------------------
# 6. 收集产物
# ---------------------------------------------------------------------------
step "6/6 收集产物 → $OUT_DIR"
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
echo "nft_queue.ko 详情（vermagic 必须与 N1 内核一致）:"
for f in "$OUT_DIR"/*.ko; do
    [ -f "$f" ] || continue
    echo "  $f"
    strings "$f" 2>/dev/null | grep -E '^vermagic=' || true
done

if ! ls "$OUT_DIR"/*.ko >/dev/null 2>&1; then
    echo
    echo "[x] 未找到 ${KERNEL_MODULE}.ko —— 编译可能失败，请检查上面 5.4 的输出"
    exit 1
fi

echo
echo "[✓] 完成 $(date)"
