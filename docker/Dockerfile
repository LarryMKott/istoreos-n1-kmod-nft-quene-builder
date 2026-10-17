# syntax=docker/dockerfile:1
#
# iStoreOS / OpenWrt aarch64 交叉编译环境
# 目标产物：kmod-nft-queue (nft_queue.ko) for Phicomm N1 (amlogic/meson)
#
# 构建（需要代理时把 ARG 传进来，见 README）：
#   docker build --network host \
#     --build-arg http_proxy=http://user:pass@host:7890 \
#     --build-arg https_proxy=http://user:pass@host:7890 \
#     -t istoreos-builder:25.12 -f docker/Dockerfile .
#
# ★ 关键坑（实测）：debian:12-slim 里**没有 ca-certificates**。
#   如果直接把 /etc/apt/sources.list 换成 https:// 镜像源，第一条 RUN 就会挂在
#     Certificate verification failed: The certificate is NOT trusted
#   GitHub Actions 上表现为「本地构建镜像」这一步 20 秒内失败。
#   因此这里统一走 http 源（apt 本身有 GPG 签名校验，安全性不受影响），
#   并在同一层里把 ca-certificates 装上。
#
FROM debian:12-slim

ARG http_proxy=""
ARG https_proxy=""
ARG TARGET_BRANCH="istoreos-25.12"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    FORCE_UNSAFE_CONFIGURE=1

# ---------------------------------------------------------------------------
# 1) apt 换源（多源回退）+ 基础 CA
#    注意：不要用 https 源，slim 镜像没有 CA 证书
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -n "$http_proxy" ]; then \
        printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_proxy" "$https_proxy" \
            > /etc/apt/apt.conf.d/95proxy; \
    fi; \
    printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/98-retry; \
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true; \
    write_sources() { \
        printf 'deb %s bookworm main contrib non-free non-free-firmware\n' "$1" >  /etc/apt/sources.list; \
        printf 'deb %s bookworm-updates main contrib non-free non-free-firmware\n' "$1" >> /etc/apt/sources.list; \
        printf 'deb %s bookworm-security main contrib non-free non-free-firmware\n' "$2" >> /etc/apt/sources.list; \
    }; \
    ok=0; \
    for pair in \
        "http://mirrors.tuna.tsinghua.edu.cn/debian|http://mirrors.tuna.tsinghua.edu.cn/debian-security" \
        "http://deb.debian.org/debian|http://deb.debian.org/debian-security" \
        "http://mirrors.aliyun.com/debian|http://mirrors.aliyun.com/debian-security" \
        "http://mirrors.cloud.tencent.com/debian|http://mirrors.cloud.tencent.com/debian-security" ; do \
        main="${pair%%|*}"; sec="${pair##*|}"; \
        echo "[i] 尝试 apt 源: $main"; \
        write_sources "$main" "$sec"; \
        if apt-get update; then ok=1; echo "[i] 采用 apt 源: $main"; break; fi; \
        echo "[!] 该源不可用，切换下一个"; \
    done; \
    [ "$ok" = "1" ] || { echo "[x] 所有 apt 源都不可用"; exit 1; }; \
    apt-get install -y --no-install-recommends ca-certificates; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2) OpenWrt 官方 build-dep 清单（debian 变体）
#    额外加入 BTF 相关工具链依赖：
#      cmake / ninja-build  → 编 OpenWrt 自带 pahole (tools/dwarves)
#      libdw-dev            → pahole 依赖 elfutils/libdw
#    注：不要用 Debian 的 dwarves 包（pahole 1.24 太旧），内核期望 PAHOLE_VERSION=131。
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential ccache ecj fastjar file g++ gawk gettext git \
        java-propose-classpath libelf-dev libncurses5-dev libncursesw5-dev \
        libssl-dev python3 python3-distutils python3-ply python3-pip python3-setuptools \
        python3-dev python3-venv rsync subversion swig time unzip wget zlib1g-dev \
        quilt patch bzip2 xz-utils cpio bc flex bison autoconf automake libtool pkg-config \
        gperf zip kmod libfuse-dev fakeroot sudo less vim-tiny ca-certificates \
        device-tree-compiler u-boot-tools \
        cmake ninja-build libdw-dev; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# OpenWrt 期望 python 可执行文件存在
RUN set -eux; \
    if [ ! -e /usr/bin/python ]; then ln -s /usr/bin/python3 /usr/bin/python; fi; \
    git config --system http.postBuffer 524288000; \
    git config --system core.compression 0; \
    git config --system advice.detachedHead false

WORKDIR /build
VOLUME ["/build"]

CMD ["/bin/bash"]
