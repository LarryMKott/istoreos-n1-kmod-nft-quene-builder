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
FROM debian:12-slim

ARG http_proxy=""
ARG https_proxy=""
ARG TARGET_BRANCH="istoreos-25.12"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    # 关键：容器内以 root 运行，GNU tar / gmp 等工具的 configure 会拒绝 root，
    #      必须设置此变量，否则 toolchain 第一步就失败：
    #      "you should not run configure as root (set FORCE_UNSAFE_CONFIGURE=1 ...)"
    FORCE_UNSAFE_CONFIGURE=1

# ---- apt 换源（清华，国内直连可用；GitHub Actions 上也稳定）----
RUN set -eux; \
    if [ -n "$http_proxy" ]; then \
        printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_proxy" "$https_proxy" \
            > /etc/apt/apt.conf.d/95proxy; \
    fi; \
    printf 'deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware\n' \
        > /etc/apt/sources.list; \
    printf 'deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware\n' \
        >> /etc/apt/sources.list; \
    printf 'deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware\n' \
        >> /etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true

# ---- OpenWrt 官方 build-dep 清单（debian 变体）----
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential ccache ecj fastjar file g++ gawk gettext git \
        java-propose-classpath libelf-dev libncurses5-dev libncursesw5-dev \
        libssl-dev python3 python3-distutils python3-ply python3-pip python3-setuptools \
        python3-dev python3-venv rsync subversion swig time unzip wget zlib1g-dev \
        quilt patch bzip2 xz-utils cpio bc flex bison autoconf automake libtool pkg-config \
        gperf zip kmod libfuse-dev fakeroot sudo less vim-tiny ca-certificates \
        device-tree-compiler u-boot-tools; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# OpenWrt 期望 python 可执行文件存在
RUN set -eux; \
    if [ ! -e /usr/bin/python ]; then ln -s /usr/bin/python3 /usr/bin/python; fi

# git 大仓库友好设置
RUN git config --system http.postBuffer 524288000 && \
    git config --system core.compression 0 && \
    git config --system advice.detachedHead false

WORKDIR /build
VOLUME ["/build"]

CMD ["/bin/bash"]
