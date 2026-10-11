# istoreos-n1-kmod-nft-queue-builder

为 **斐讯 N1（Phicomm N1，amlogic/meson 平台，ARM64）** 上运行的 **iStoreOS 25.12** 交叉编译 `nft_queue.ko` 内核模块的自动化构建工程。

> 目标：让 nftables 的 **`queue` 语句**（NFQUEUE 到用户态）在 iStoreOS 上可用。

---

## 为什么需要这个项目

iStoreOS 官方仓库**没有** `kmod-nft-queue` 这个包，内核里 `CONFIG_NFT_QUEUE` 也是关闭的：

| 检查项 | 结果 |
| --- | --- |
| `apk search kmod-nft-queue`（索引 10571 个包） | 无此包 |
| `zcat /proc/config.gz \| grep NFT_QUEUE` | `# CONFIG_NFT_QUEUE is not set` |
| `find /lib/modules/$(uname -r) -name 'nft_queue*'` | 无 |

但**源码里其实是有定义的** —— `package/kernel/linux/modules/netfilter.mk` 的 `define KernelPackage/nft-queue`，只是被 KCONFIG 关掉了。所以可以自己编。

### 三个 NFQUEUE 相关的东西，别搞混

| 模块 | 作用 | iStoreOS 现状 |
| --- | --- | --- |
| `nfnetlink_queue.ko` | NFQUEUE 基础设施（内核↔用户态队列通信） | ✅ 已装 |
| `xt_NFQUEUE.ko` | **iptables** 的 `-j NFQUEUE` target | ✅ 已装，但缺用户态 `libxt_NFQUEUE.so` |
| `nft_queue.ko` | **nftables** 的 `queue` 语句 | ❌ **未编译（本项目要造的）** |

> 如果你的下游软件（如某些透明代理、流量整形工具）用的是 nftables 语法，那必须要 `nft_queue.ko`，光有 `xt_NFQUEUE` 不够。

---

## 工作原理

```
GitHub Actions (ubuntu-22.04, x86_64)
        │
        ├─ docker build  →  istoreos-builder:25.12  (debian:12-slim + OpenWrt 全套依赖)
        │
        └─ docker run --network host
                 │
                 └─ /build/build-module.sh
                        ├─ git clone --depth=1 -b istoreos-25.12  (iStoreOS 源码)
                        ├─ scripts/feeds update -a && install -a
                        ├─ 种子 .config + make defconfig        ← 见下方「坑」
                        ├─ 向 config-6.12 追加 CONFIG_NFT_QUEUE=m
                        ├─ make download
                        ├─ make toolchain/install               ← 交叉工具链 aarch64
                        ├─ make target/linux/compile            ← 内核（含符号表）
                        ├─ make package/kernel/linux/compile    ← nft_queue.ko
                        └─ cp 产物 → out/
                               │
                               ▼
                        upload-artifact
                               │
                               ▼
                     下载 → scp 到 N1 → install-on-n1.sh
```

**关键点**：容器跑在 x86_64 上完全没问题 —— OpenWrt 的构建系统本身就是「x86_64 主机 + aarch64 交叉工具链」，不需要 ARM 机器或 QEMU。

---

## 快速开始

### 方式 A：用 GitHub Actions（推荐）

1. **Fork / Clone 本仓库**

2. **首次**：让 Actions 构建好编译镜像
   - 打开 `Actions` → `Publish builder image to GHCR` → `Run workflow`
   - 等它跑完（约 5~8 分钟），镜像会推到 `ghcr.io/<你的用户名>/istoreos-n1-kmod-nft-queue-builder/istoreos-builder:25.12`
   - 如果跳过这步也没关系，`build.yml` 会检测不到镜像并**本地构建**

3. **编译模块**
   - `Actions` → `Build kmod-nft-queue for iStoreOS (Phicomm N1)` → `Run workflow`
   - 参数：
     - `istoreos_branch`: `istoreos-25.12`（默认）
     - `nproc`: `4`（GitHub runner 建议 4，再高容易 OOM）
     - `use_prebuilt_image`: `true`
   - **首次全量编译需要 2~4 小时**（要编整个 aarch64 toolchain），之后有 dl 缓存会快一些
   - 完成后在 `Artifacts` 下载 `kmod-nft-queue-istoreos-25.12-<run_number>`

4. **装到 N1**：见下方

### 方式 B：本地 / 自建服务器跑

```bash
# 1. 构建镜像（需要代理时传 ARG）
docker build --network host \
  --build-arg http_proxy=http://user:pass@192.168.31.20:7890 \
  --build-arg https_proxy=http://user:pass@192.168.31.20:7890 \
  -f docker/Dockerfile -t istoreos-builder:25.12 .

# 2. 起容器（务必 --network host：bridge 网络下 apt/下载会因 DNS 劫持失败）
mkdir -p build out
cp scripts/build-module.sh build/
docker run -d --name oc-builder --network host \
  -e NPROC=8 \
  -e BUILD_PROXY=http://user:pass@192.168.31.20:7890 \
  -v "$PWD/build:/build" \
  istoreos-builder:25.12 sleep infinity

# 3. 编译（长任务，务必 setsid 后台跑，否则 SSH 断开就被 SIGTERM 杀掉）
docker exec oc-builder bash -c \
  'setsid bash -c "bash /build/build-module.sh > /build/build.log 2>&1" < /dev/null > /dev/null 2>&1 &'

# 4. 看进度
docker exec oc-builder tail -f /build/build.log

# 5. 取产物
ls -la build/out/
```

---

## 装到 N1 上

```bash
# 在 N1 上（替换为你的实际路径）
./install-on-n1.sh nft_queue.ko
```

脚本会做：

1. **vermagic 校验** —— 模块的 vermagic 必须以本机 `uname -r` 开头，不一致直接拒绝
2. **依赖检查** —— `nf_tables` / `nfnetlink_queue` 是否存在或内建
3. **试加载** —— `insmod` 一次，若报 `Unknown symbol` 会打印详细排查指引
4. **持久化** —— 复制到 `/lib/modules/$(uname -r)/extra/`
5. **开机自加载** —— 写 `/etc/modules.d/60-nft-queue`
6. **实测** —— 用 `nft` 真的建一条 `queue num 1` 规则验证

### 手动安装（不想用脚本）

```bash
KVER=$(uname -r)
mkdir -p /lib/modules/$KVER/extra
cp nft_queue.ko /lib/modules/$KVER/extra/
insmod /lib/modules/$KVER/extra/nft_queue.ko
echo nft_queue > /etc/modules.d/60-nft-queue

# 验证
nft add table inet testq
nft add chain inet testq c '{ type filter hook output priority 0; }'
nft add rule inet testq c queue num 1
nft delete table inet testq
```

---

## 已验证的环境事实（踩坑记录）

这些是本项目在真机上实测得出的结论，直接决定了脚本为什么这么写。

### 1. `make defconfig CONFIG_TARGET_amlogic=y` 无效

命令行传 `CONFIG_TARGET_*` **不会**被 `defconfig` 采纳，`.config` 里仍然是 `# CONFIG_TARGET_amlogic is not set`。

**必须**先写一个种子 `.config` 再跑 `make defconfig`：

```bash
rm -f .config
cat > .config <<'SEED'
CONFIG_TARGET_amlogic=y
CONFIG_TARGET_amlogic_meson=y
CONFIG_PACKAGE_kmod-nft-queue=m
SEED
make defconfig
```

这样会自动展开完整依赖，并且**顺带选中 `CONFIG_TARGET_amlogic_meson_DEVICE_phicomm_n1=y`**（源码里自带 N1 设备定义）。

### 2. 容器以 root 跑 ⇒ 必须 `FORCE_UNSAFE_CONFIGURE=1`

否则 `tools/tar` 编译时：

```
checking whether mknod can create fifo without root privileges...
configure: error: you should not run configure as root
                 (set FORCE_UNSAFE_CONFIGURE=1 in environment to bypass this check)
make[2]: *** [.../build_dir/host/tar-1.35/.configured] Error 1
    ERROR: tools/tar failed to build.
```

这个失败会连锁导致 `toolchain/install` → `target/linux/compile` → `package/kernel/linux/compile` **全部报错**，看起来像灾难，其实根因只有这一个。

本项目的 Dockerfile 已用 `ENV FORCE_UNSAFE_CONFIGURE=1` 固化。

### 3. Docker bridge 网络下 apt 会失败

```
Unable to locate package build-essential
```

原因：bridge 网络的 DNS 被 Docker 劫持 + NAT 走得不对，容器内 apt 根本连不出去。
**解决**：`docker build` 和 `docker run` 都加 `--network host`。

### 4. Docker 29 的代理配置要写两处

只配 `/etc/docker/daemon.json` 的 `proxies` 字段**不够**（Docker 29 已切到 containerd 做镜像拉取），必须同时配 systemd：

```
/etc/systemd/system/docker.service.d/http-proxy.conf
/etc/systemd/system/containerd.service.d/http-proxy.conf
```

两处都要：

```ini
[Service]
Environment="HTTP_PROXY=http://user:pass@host:7890"
Environment="HTTPS_PROXY=http://user:pass@host:7890"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,.local"
```

### 5. 通过 SSH 起长任务必须 `setsid`

```bash
# ❌ SSH 断开后进程被 SIGTERM
nohup bash build.sh &

# ✅ 脱离会话
setsid bash -c 'bash build.sh > build.log 2>&1' < /dev/null > /dev/null 2>&1 &
```

### 6. 内核 config 要手工打开

`KernelPackage/nft-queue` 在 `netfilter.mk` 里存在，但被 KCONFIG 关掉。必须向
`target/linux/amlogic/meson/config-6.12` 追加：

```
CONFIG_NFT_QUEUE=m
```

脚本会自动做这件事（幂等）。

### 7. 为什么 vermagic 会匹配

N1 上的目标内核：

| 配置 | 值 | 影响 |
| --- | --- | --- |
| `CONFIG_MODVERSIONS` | **off** | 不需要符号 CRC 校验，模块间符号直接按名字解析 |
| `CONFIG_MODULE_SIG` | **off** | 不需要签名 |
| `CONFIG_LOCALVERSION` | `""` | vermagic 中没有 `+xxx` 后缀 |
| 内核版本 | `6.12.94` | 必须与源码分支一致 |

vermagic 形如 `6.12.94 SMP mod_unload aarch64`。只要用 `istoreos-25.12` 分支编出来的，就是匹配的。

> ⚠️ **唯一的残余风险**：`Unknown symbol`（模块引用了目标内核没编进去的符号）。这个只能在 N1 上 `insmod` 那一刻才知道，所以 `install-on-n1.sh` 里专门做了友好报错。

---

## 仓库结构

```
.
├── .github/workflows/
│   ├── build.yml              # 主流程：编译 nft_queue.ko
│   └── publish-image.yml      # 预构建编译镜像并推到 GHCR
├── docker/
│   └── Dockerfile             # debian:12-slim + OpenWrt 全套 build 依赖
├── scripts/
│   ├── build-module.sh        # 容器内编译主脚本（6 步流程）
│   └── install-on-n1.sh       # N1 端安装 + 校验 + 验证
└── README.md
```

---

## 可调参数

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `BRANCH` | `istoreos-25.12` | iStoreOS 源码分支 |
| `TARGET` | `amlogic` | OpenWrt target |
| `SUBTARGET` | `meson` | OpenWrt subtarget |
| `KERNEL_CONFIG` | `config-6.12` | 目标内核配置文件 |
| `NPROC` | `nproc` | 并行度（GitHub runner 用 4） |
| `BUILD_PROXY` | 空 | 国内自建时填 N1 的 http 代理 |
| `OUT_DIR` | `/build/out` | 产物输出目录 |

---

## 常见问题

**Q: 编译要多久？**
首次 2~4 小时（toolchain 占大头）。有 dl 缓存 + 只重编 package 时会快很多。

**Q: 能只编模块不编整个内核吗？**
不能。`make package/kernel/linux/compile` 依赖 `target/linux/compile` 产出的内核头文件与符号表。

**Q: 换个 N1 固件版本还能用吗？**
不能直接用。必须把 `BRANCH` / `KERNEL_CONFIG` 换成对应版本重新编译，vermagic 必须一致。

**Q: GitHub runner 磁盘不够怎么办？**
`build.yml` 里已经加了「释放磁盘空间」步骤，删掉 dotnet / android SDK / GHC 等约 20G。全量构建需要 25G+。

---

## License

MIT。脚本与配置仅供学习与自用；iStoreOS 源码版权归其上游所有。
