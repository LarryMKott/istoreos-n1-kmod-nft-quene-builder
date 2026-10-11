#!/bin/sh
# =============================================================================
#  在 iStoreOS (Phicomm N1) 上安装 nft_queue.ko
#
#  用法：
#     ./install-on-n1.sh nft_queue.ko
#     ./install-on-n1.sh kmod-nft-queue-*.apk      # 若拿到的是安装包
#
#  做的事：
#     1. 校验 vermagic 与当前内核一致
#     2. 校验依赖符号是否可解析（insmod 试加载，失败则明确报错）
#     3. 安装到 /lib/modules/$(uname -r)/
#     4. 写 /etc/modules.d/ 使开机自动加载
#     5. 用 nft 实测 queue 语句是否可用
# =============================================================================
set -e

KVER="$(uname -r)"
MODDIR="/lib/modules/$KVER"
SRC="$1"

die() { echo "[x] $*" >&2; exit 1; }
info() { echo "[i] $*"; }
ok() { echo "[✓] $*"; }

[ -n "$SRC" ] || die "用法: $0 <nft_queue.ko 或 kmod-nft-queue 安装包>"
[ -f "$SRC" ] || die "文件不存在: $SRC"

# ---------------------------------------------------------------------------
# 情况 A：拿到的是 apk / ipk 安装包
# ---------------------------------------------------------------------------
case "$SRC" in
  *.apk)
        info "检测到 apk 包，使用 apk add 安装"
        # iStoreOS 25.12 起使用 apk
        apk add --allow-untrusted "$SRC" || die "apk 安装失败"
        ok "apk 安装完成"
        ;;
  *.ipk)
        # iStoreOS 25.12 起默认使用 apk；旧版本才需要 opkg
        if command -v apk >/dev/null 2>&1; then
            info "系统使用 apk，改用 apk 安装 ipk"
            apk add --allow-untrusted "$SRC" || die "apk 安装失败"
        elif command -v opkg >/dev/null 2>&1; then
            info "检测到 ipk 包，使用 opkg 安装"
            opkg install "$SRC" || die "opkg 安装失败"
        else
            die "系统既无 apk 也无 opkg，无法安装 $SRC"
        fi
        ok "包安装完成"
        ;;
  *.ko)
        # -------------------------------------------------------------------
        # 情况 B：裸 .ko 文件
        # -------------------------------------------------------------------
        info "当前内核: $KVER"
        info "目标模块: $SRC"

        # 1. vermagic 校验
        WANT="$(strings "$SRC" | grep -m1 '^vermagic=' | cut -d= -f2-)"
        [ -n "$WANT" ] || die "无法从 $SRC 读出 vermagic（不是合法 .ko？）"
        info "模块 vermagic : $WANT"

        # 本机内核的 vermagic 由 uname -r + 配置决定，直接比较前缀
        case "$WANT" in
          "$KVER"*) ok "vermagic 匹配当前内核 $KVER" ;;
          *) die "vermagic 不匹配！
    模块: $WANT
    本机: $KVER
    两者内核版本不一致，此模块无法加载。请用对应版本重新编译。" ;;
        esac

        # 2. 依赖模块检查
        info "检查依赖（nft_queue 依赖 nf_tables / nfnetlink_queue）"
        for dep in nf_tables nfnetlink_queue; do
            if ls "$MODDIR"/kernel/net/netfilter/"$dep".ko* >/dev/null 2>&1; then
                ok "  $dep 存在"
            else
                # 也可能是内建（built-in）
                if grep -q "^CONFIG_$(echo "$dep" | tr 'a-z' 'A-Z')=" /proc/config.gz 2>/dev/null || \
                   zcat /proc/config.gz 2>/dev/null | grep -qE "CONFIG_$(echo "$dep" | tr 'a-z' 'A-Z')=[ym]"; then
                    ok "  $dep 已内建或存在"
                else
                    echo "  [!] $dep 未找到（若是内建可忽略）"
                fi
            fi
        done

        # 3. 试加载（不持久化）
        info "试加载（insmod）..."
        if insmod "$SRC" 2>/tmp/nftq_err; then
            ok "insmod 成功"
            lsmod | grep -E '^nft_queue' || true
        else
            ERR="$(cat /tmp/nftq_err)"
            if echo "$ERR" | grep -q 'Unknown symbol'; then
                echo
                die "加载失败：Unknown symbol（符号版本/配置不匹配）
$ERR

  可能原因：
    a) 目标内核未编译该符号（如需 CONFIG_NF_TABLES 等）
    b) 双方 CONFIG_MODVERSIONS 状态不一致
    c) 模块来自不同内核版本
  排查：
    grep NF_TABLES /proc/config.gz 确认内核侧配置
    modinfo $SRC 查看 depends 字段
  本机关键配置：
$(zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(MODVERSIONS|MODULE_SIG|NF_TABLES|NETFILTER)' || echo '  (无法读取 /proc/config.gz)')"
            else
                die "insmod 失败：$ERR"
            fi
        fi

        # 4. 持久化安装
        info "安装到 $MODDIR/extra/"
        mkdir -p "$MODDIR/extra"
        cp -f "$SRC" "$MODDIR/extra/nft_queue.ko"
        sync
        ok "已复制到 $MODDIR/extra/nft_queue.ko"

        # 重建依赖索引，使 modprobe 能按名找到
        if command -v depmod >/dev/null 2>&1; then
            depmod -a "$KVER" 2>/dev/null && ok "depmod 已更新依赖索引" || echo "[!] depmod 执行失败（不影响 insmod）"
        fi

        # 5. 开机自动加载
        mkdir -p /etc/modules.d /etc/modules-boot.d 2>/dev/null || true
        echo "nft_queue" > /etc/modules.d/60-nft-queue
        ok "已写 /etc/modules.d/60-nft-queue（开机自动加载）"
        ;;
  *)
        die "未知文件类型: $SRC"
        ;;
esac

# ---------------------------------------------------------------------------
# 通用：验证 nft queue 语句可用
# ---------------------------------------------------------------------------
echo
info "验证 nftables queue 语句..."
if command -v nft >/dev/null 2>&1; then
    if nft add table inet testq 2>/dev/null && \
       nft add chain inet testq c '{ type filter hook output priority 0 ; }' 2>/dev/null && \
       nft add rule inet testq c queue num 1 2>/dev/null; then
        ok "nft queue 语句可用"
        nft flush table inet testq 2>/dev/null || true
        nft delete table inet testq 2>/dev/null || true
    else
        echo "[!] nft queue 语句测试失败，请手动执行："
        echo "    nft add table inet testq"
        echo "    nft add chain inet testq c '{ type filter hook output priority 0; }'"
        echo "    nft add rule inet testq c queue num 1"
        nft delete table inet testq 2>/dev/null || true
    fi
else
    echo "[!] 系统未找到 nft 命令，跳过验证"
fi

echo
ok "安装完成。模块列表："
lsmod | grep -E 'nft_queue|nfnetlink_queue' || echo "  (未加载)"
