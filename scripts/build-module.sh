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
# 5. 编译
# ---------------------------------------------------------------------------
step "5/6 开始编译 (NPROC=$NPROC)"
echo "--- 5.1 download ---"
make -j"$NPROC" download 2>&1 | tail -15

echo "--- 5.2 toolchain/install ---"
make -j"$NPROC" toolchain/install 2>&1 | tail -30

echo "--- 5.3 target/linux/compile ---"
make -j"$NPROC" target/linux/compile 2>&1 | tail -30

echo "--- 5.4 package/kernel/linux/compile ---"
make -j"$NPROC" package/kernel/linux/compile 2>&1 | tail -50

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
