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
   - 等它跑完（约 5~8 分钟），镜像会推到 `ghcr.io/<你的用户名全小写>/istoreos-n1-kmod-nft-quene-builder/istoreos-builder:25.12`
     （镜像名必须全小写，见「坑 13」；workflow 会自动把仓库名转成小写）
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

### 8. 内核 `syncconfig` 卡死（本项目第二个致命坑）

**症状**：`target/linux/compile` 和 `package/kernel/linux/compile` **双双在 1 秒内秒退**，日志末尾是：

```
* Restart config...
* Transparent Hugepage Support
Transparent Hugepage Support (TRANSPARENT_HUGEPAGE) [Y/n/?] y
    3. never (TRANSPARENT_HUGEPAGE_NEVER) (NEW)
  choice[1-3?]: make[7]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
make[6]: *** [Makefile:691: syncconfig] Error 2
Makefile:769: include/config/auto.conf.cmd: No such file or directory
    ERROR: target/linux failed to build.
```

**根因**：iStoreOS 的 `target/linux/amlogic/meson/config-6.12` 是给**旧版内核**准备的。源码树里的内核是 **6.12.94**，比该配置更新，新增了 `CONFIG_TRANSPARENT_HUGEPAGE_NEVER` 这个 choice 成员。kconfig 在 `syncconfig` 阶段发现 NEW 项，非交互环境下读不到 stdin 就报错退出。

> 注意：**不是** `CONFIG_NFT_QUEUE=m` 引起的。任何触发 `.config` 重算的改动（包括修好 `FORCE_UNSAFE_CONFIGURE` 后第一次能跑到这一步）都会暴露它。

**修复**：编译前用默认值补齐所有 NEW 项：

```bash
cd build_dir/target-*/linux-*/linux-*/
export PATH="$PWD/../../../staging_dir/toolchain-*/bin:$PWD/../../../staging_dir/host/bin:$PATH"
yes "" | make ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- olddefconfig
```

- `yes ""` 提供空行，使任何残留的交互提示都取默认值
- 必须先把**交叉工具链 bin 与 host bin 放进 PATH**，否则报
  `scripts/Kconfig.include:40: C compiler 'aarch64-openwrt-linux-musl-gcc' not found`
- 修复后 `CONFIG_TRANSPARENT_HUGEPAGE_NEVER is not set` 被补上，`CONFIG_NFT_QUEUE=m` 保留

`build-module.sh` 的 **4.5 步**自动做这件事（幂等，可重复执行）。

### 9. `make ... | tail -N` 会掩盖失败退出码

```bash
# ❌ $? 取到的是 tail 的退出码，恒为 0 —— 失败被静默吞掉
make -j8 target/linux/compile 2>&1 | tail -40
echo "rc=$?"          # 永远打印 rc=0

# ✅ 显式捕获 make 的退出码
make -j8 target/linux/compile > build.log 2>&1
rc=$?
tail -25 build.log
```

本项目实测踩过：第一次跑完后日志显示 `### 3 rc=0 ###`，看起来一切正常，实际上
`target/linux` 已经失败了。**排查这类问题时务必用 `V=s` 单独复现，不要只看批量日志。**

### 10. 观察长时间编译的正确姿势

`make ... | tail -N` 会把输出缓冲到命令结束，所以**编译过程中 log 尾部看不到任何细节**。
要看真实进度必须直接读文件系统：

```bash
# 内核编译进度（目标文件数会持续增长）
find build_dir/target-*/linux-*/linux-*/ -name '*.o' | wc -l
# netfilter 目录（nft_queue.c 在这里编译）
ls build_dir/target-*/linux-*/linux-*/net/netfilter/*.o | wc -l
# 工具链产出
ls staging_dir/toolchain-*/bin | wc -l
# 子步骤目录按时间排序，可看出编到哪一步
ls -lt build_dir/toolchain-*/
```

工具链子步骤的固定顺序：
`binutils` → `gcc-initial` → `gdb` → `kernel-headers` → `musl` → `gcc-final`
（`gcc-final` 最耗时，8 核约 30–50 分钟）

### 11. ★ 模块必须带 `.BTF`，否则 `insmod` 段错误（本项目第一致命坑）

**这是我们踩得最深的一个坑，v0.1 的模块 vermagic 完全正确却装不上，原因就在这里。**

iStoreOS 官方内核编译时开启了 BTF 调试信息（`CONFIG_DEBUG_INFO_BTF=y`）。内核在
`load_module()` 里会解析模块的 `.BTF` 段；如果模块**没有** `.BTF`（或 BTF 为空/非法），
就会在 `caches_clean_inval_pou` 里对一个非法地址范围做 cache 清理 → Oops / 段错误。

#### 症状

模块 vermagic 完全匹配，`modinfo` 也正常，但：

```console
# insmod nft_queue.ko
Segmentation fault
```

```console
# dmesg | tail
nft_queue: module has no kallsyms
pc : caches_clean_inval_pou+0x30/0x84
lr : load_module+0xef0/0x1b54
Call trace:
 caches_clean_inval_pou+0x30/0x84
 __do_sys_init_module
Code: d2800084 9ac52084 d1000485 8a250042 (d50b7b22)   # dc civac
```

`caches_clean_inval_pou` + `dc civac`（data cache clean and invalidate）是关键线索：
内核对一个**空/非法** BTF 缓冲区做 cache 操作。

#### 诊断方法（决定性证据）

N1 内核配置（权威来源 `/proc/config.gz`）：

```
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set      ← 关键
CONFIG_PAHOLE_VERSION=131
```

N1 上存在 `/sys/kernel/btf/vmlinux`（约 5 MB）。
抽样 `/lib/modules/6.12.94/` 下 **25/25 个系统模块都带 `.BTF` 段**。
（N1 是 busybox，没有 `readelf`；把 `.ko` 拷到编译容器里查即可。）

对比我们产出的模块，用 `readelf -S -W`：

```
# 系统模块 nft_quota.ko
[27] .BTF  PROGBITS  off=000cf1  size=001a9d     ← 有

# 我们编的 nft_queue.ko
（没有 .BTF 段）                                  ← 没有 ⇒ insmod 必崩
```

#### 根因：三层配置缺一不可

**① iStoreOS 顶层 `.config` 用 `CONFIG_KERNEL_*` 前缀，不是裸 `CONFIG_DEBUG_INFO_*`**

裸写 `CONFIG_DEBUG_INFO_BTF=y` 会被 `make defconfig` 直接清掉。必须写：

```
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
CONFIG_DWARVES=y
CONFIG_KERNEL_TRANSPARENT_HUGEPAGE_NEVER=y
```

**② 依赖链决定了必须先关 `REDUCED`**

`config/Config-kernel.in`：

```
config KERNEL_DEBUG_INFO_BTF
        bool "Enable BTF debug information"
        depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED
config KERNEL_DEBUG_INFO_BTF_MODULES
        depends on KERNEL_DEBUG_INFO_BTF
```

iStoreOS 默认 `CONFIG_KERNEL_DEBUG_INFO_REDUCED=y`，所以在结构上 **BTF 不可能被选中**。
必须先把 `REDUCED` 关掉。

**③ 还要改内核「种子文件」，只改顶层不够**

`target/linux/generic/config-6.12` 里显式写死了 `# CONFIG_DEBUG_INFO_BTF is not set`，
这个文件在内核 `make defconfig` 时会被直接采用。所以必须同时改：

```bash
# target/linux/generic/config-6.12 与 target/linux/amlogic/config-6.12
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
# CONFIG_DEBUG_INFO_REDUCED is not set
# CONFIG_DEBUG_INFO_NONE is not set
```

#### ④ `pahole` 必须是 OpenWrt 自带那份（1.31）

BTF 由 `pahole` 生成。内核期望 `CONFIG_PAHOLE_VERSION=131`，即 **1.31**。
Debian bookworm 仓库里只有 **1.24**，偏低。正确做法是用
`tools/dwarves`（`PKG_VERSION:=1.31`，由 `CONFIG_DWARVES=y` 触发）：

```bash
make -j"$(nproc)" tools/dwarves/compile
export PATH="$SRC_DIR/staging_dir/host/bin:$PATH"
pahole --version     # → v1.31
```

`tools/dwarves/Makefile` 编译需要宿主机具备：`cmake`、`ninja-build`、`libdw-dev`
（本项目的 Dockerfile 已包含）。

#### 清理步骤

改完配置后**必须删掉内核 build_dir 的 `.config`**，否则旧的（无 BTF 的）配置会被复用：

```bash
KDIR=$(ls -d build_dir/target-*/linux-*/linux-* | head -1)
rm -f "$KDIR/.config" "$KDIR/.config.old"
make -j"$(nproc)" target/linux/compile
```

验证生效：

```bash
grep -E 'DEBUG_INFO_BTF|DEBUG_INFO_REDUCED|PAHOLE_VERSION' "$KDIR/.config"
# 期望：
#   CONFIG_PAHOLE_VERSION=131
#   # CONFIG_DEBUG_INFO_REDUCED is not set
#   CONFIG_DEBUG_INFO_BTF=y
#   CONFIG_DEBUG_INFO_BTF_MODULES=y
```

最终产物校验（`build-module.sh` 第 7 步已内置）：

```bash
readelf -S -W out/nft_queue.ko | grep '\.BTF'
# 必须出现，例如：[27] .BTF PROGBITS ... size=001a9d
```

#### 顺带解决：`syncconfig` 死锁

在种子文件里预填 `CONFIG_TRANSPARENT_HUGEPAGE_NEVER=y`（并 unset
`ALWAYS`/`MADVISE`），可以一并消除坑 8 描述的
`choice[1-3?]:` + `syncconfig Error 1` 死锁 —— 因为 6.12 新增的这个 choice
成员已经在种子文件里有值了，不再算 NEW。

### 12. ★ `struct module` 布局必须与目标内核一致，否则 `load_module` 静默死循环

**这是比 BTF 更根本的一个坑。** 即使模块带了正确的 `.BTF`，只要 `struct module`
布局不一致，`insmod` 仍会**静默挂死**（进程永远处于 `S` 状态，无 dmesg、无返回、
系统负载正常）。

#### 症状

```console
# insmod nft_queue.ko
（无任何输出，命令永不返回）
```

```console
# ps | grep insmod
17714 root  1656 S  insmod /tmp/nftq2/btf_nft_queue.ko    ← 永远 S 状态
# cat /proc/loadavg
0.02 0.08 0.08 1/303                                ← 系统完全健康
# dmesg | tail
（没有任何新行）
```

多次尝试会**累积多个卡死的 insmod 进程**，必须手工 `kill -9` 清理，否则干扰后续诊断。

#### 诊断方法

`struct module` 在目标内核里的实际大小 vs 我们编出来的：

```bash
# 目标内核的 struct module 大小（可从任意系统模块读出）
readelf -sW /lib/modules/6.12.94/nft_quota.ko | awk '$NF=="__this_module"{print $3}'
#   → 1216

# 我们模块的
readelf -sW out/nft_queue.ko | awk '$NF=="__this_module"{print $3}'
#   → 704        ← 差 512 字节！
```

也可以直接读用我们的内核编出的模块的 `.gnu.linkonce.this_module` 段大小：
`1216`（0x4c0）vs `704`（0x2c0）。

#### 根因：一批 tracing / perf / kprobe / BPF 选项缺失

`struct module` 里有大量 `#ifdef` 字段（见 `include/linux/module.h`）。以下选项
在目标（iStoreOS 官方）内核里是 `=y`，而我们默认构建里 **完全没有或为 n**：

| 选项 | N1 内核 | 默认构建 | 贡献的 `struct module` 字段 |
|---|---|---|---|
| `CONFIG_TRACEPOINTS` | y | — | `tracepoints[]` 数组 |
| `CONFIG_TRACING` | y | — | — |
| `CONFIG_EVENT_TRACING` | y | — | — |
| `CONFIG_FTRACE` | y | **n** | `ftrace_callsites` 等 |
| `CONFIG_KPROBES` | y | **n** | kprobe 数组 |
| `CONFIG_KPROBE_EVENTS` | y | — | — |
| `CONFIG_BPF_EVENTS` | y | — | BPF event 字段 |
| `CONFIG_PERF_EVENTS` | y | **n** | perf event 字段 |

内核在 `load_module` 里按**它自己的** `struct module` 布局读我们模块的
`__this_module`（在 `.gnu.linkonce.this_module` 段里，由模块在**编译时**按
**自己的**布局填好）。布局不一致 → 读到垃圾的 `num_tracepoints`/`num_kprobes`
→ 在这些数组上无限循环 → 静默挂死。

`CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` 只容忍 BTF 不匹配，**不管 struct 布局**。

#### 修复

**① 顶层 `.config`（`CONFIG_KERNEL_*` 前缀）**

```bash
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_FTRACE=y
CONFIG_KERNEL_KPROBES=y
CONFIG_KERNEL_BPF_EVENTS=y
```

用 `./scripts/config` 或直接 `sed` 改最稳；`make defconfig` 之后这 4 项会保留
（因为它们被彼此 `select` 成一组，不会全部落空）。

⚠️ 注意：**不要**把它们只写进 `target/linux/generic/config-6.12` 就以为够了 ——
顶层 `.config` 才是 OpenWrt 的权威来源；两处都写最保险。

**② 内核种子文件（可选双保险）**

`target/linux/generic/config-6.12`：

```
CONFIG_PERF_EVENTS=y
CONFIG_HW_PERF_EVENTS=y
CONFIG_FTRACE=y
CONFIG_TRACING=y
CONFIG_TRACEPOINTS=y
CONFIG_EVENT_TRACING=y
CONFIG_DYNAMIC_EVENTS=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KRETPROBES=y
CONFIG_BPF_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_GENERIC_TRACER=y
CONFIG_TRACE_CLOCK=y
CONFIG_STACKTRACE=y
```

**③ 触发内核重新生成 `.config`**

不要直接 `rm` 内核 build_dir 的 `.config`（OpenWrt 的 `target/linux/compile`
会因为 `.config` 缺失而报 `No rule to make target '.../linux-6.12.94/.config'`）。
正确做法是删除它的**标记文件**：

```bash
KDIR=$(ls -d build_dir/target-*/linux-*/linux-* | head -1)
rm -f "$KDIR/.configured"
make -j"$(nproc)" target/linux/compile
```

#### 验证

```bash
# 内核侧
grep -E '^CONFIG_(TRACEPOINTS|TRACING|EVENT_TRACING|FTRACE|KPROBES|KPROBE_EVENTS|BPF_EVENTS|PERF_EVENTS)=' "$KDIR/.config"
# 期望全部 =y

# 模块侧（700 → 1216 才是对的）
readelf -sW out/nft_queue.ko | awk '$NF=="__this_module"{print "this_module =",$3}'
```

本项目实测：补齐这 8 项后，`__this_module` 从 **704 → 1216**，与目标内核完全一致。

---

### 13. CI 上两个「秒挂」的坑（镜像名大小写 / slim 镜像没有 CA 证书）

这两个都不属于编译逻辑错误，但会让 GitHub Actions 在 20 秒内红掉。

#### (a) Docker 镜像名必须全小写

`${{ github.repository }}` 保留仓库的**原始大小写**（本仓库是 `LarryMKott/...`），
直接拼到 tag 上会被 registry 拒绝：

```
ERROR: failed to build: invalid tag "ghcr.io/LarryMKott/istoreos-n1-kmod-nft-quene-builder/istoreos-builder:25.12":
repository name must be lowercase
```

正确做法是在 workflow 里先算小写名：

```yaml
- id: img
  run: echo "image=ghcr.io/${GITHUB_REPOSITORY,,}/istoreos-builder" >> "$GITHUB_OUTPUT"
```

#### (b) `debian:12-slim` 里没有 `ca-certificates`

`slim` 镜像不带 CA 根证书，把 apt 源换成 `https://` 后第一条 `RUN` 就会挂：

```
Certificate verification failed: The certificate is NOT trusted.
```

表现：`本地构建镜像` 这一步 20 秒内失败，日志里连 apt 包列表都没开始装。
修法（本项目 Dockerfile 已采用）：**apt 源统一走 `http://`**（apt 有 GPG 签名校验，
不依赖 TLS），并在同一层里装 `ca-certificates`；同时保留清华/官方/阿里/腾讯多源回退。

> 附带一个坑：GHCR 包默认是 **private**，`build.yml` 里如果匿名 `docker pull` 会 401。
> 本项目已加 `permissions: packages: read` + `GITHUB_TOKEN` 登录步骤。

#### (c) 容器 `/build` 是宿主 `build/`，产物不会出现在 `out/`

`docker run -v "$PWD/build:/build"` 意味着容器里的 `/build/out` 其实是宿主 `build/out`，
而 workflow 的 `upload-artifact` 找的是仓库根目录的 `out/` —— 结果就是
**编译成功、日志里明明列着 `nft_queue.ko 551432 字节`，上传却报 `No files were found with the provided path: out/*`**。

修法：给容器额外显式挂一层 `-v "$PWD/out:/build/out"`，让 `/build/out` 直接落在宿主 `out/`。

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
