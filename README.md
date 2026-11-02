# 一加 9 Pro (SM8350 / lemonadep) → OpenWrt 5G CPE

把一加 9 Pro 保留为一部正常的 Android 手机，同时让它承担 5G CPE / 软路由的职责：

- **Android 宿主**：基带、5G 数据、显示、相机、音频、内部 WiFi、指纹、充电全部留在原厂系统；
- **自定义 5.4 内核**：只做 KABI 安全的最小改动，补上 `PID_NS`、`DEVTMPFS`、`MACVLAN`、内置 `r8152 2.5G` 等容器/网络必需能力；
- **OpenWrt**：以 `unshare + chroot` 的 OS 级容器运行，负责 USB LAN、DHCP/DNS/RA、LuCI、SSH，并提供防火墙与代理的运行环境；
- **USB 网卡**：用 network namespace **直通**给 OpenWrt，成为容器的 `eth0`；
- **5G WAN**：不直通，留在 Android，通过 `veth` + 宿主 `iptables` NAT / 策略路由给容器使用；
- **IPv6**：运营商 `/64` 原生共享，**不做 NAT66**。

> **项目状态：可用，持续验证中。**
> 最后一次上机验证：2026-10-27。Android 关键功能、内核、容器、IPv4/IPv6、LuCI 中文均已通过。
> 尚未完成：拔掉 USB 数据线、插上 2.5G 网卡后的完整冷启动验收。

---

## 1. 一句话架构

```text
Android 宿主 + namespace/chroot 容器 + USB 网卡 netns 直通 + 5G 宿主 NAT
```

不是虚拟机，不是 Docker，不是把整机刷成 OpenWrt 固件，也不是把 5G 基带直通给 OpenWrt。

```text
┌──────────────────── Android 宿主 (OOS 14 / LE2120_14.0.0.1901) ────────────────────┐
│  zygote / system_server / 显示 / 相机 / 音频 / 内部 WiFi / RIL / 指纹              │
│                                                                                    │
│  ┌──────────────── OpenWrt 容器 (mount/UTS/net/PID ns + chroot) ─────────────────┐  │
│  │ procd(PID 1) · netifd · dnsmasq · odhcpd · dropbear · uhttpd · LuCI(zh-cn)   │  │
│  │                                                                               │  │
│  │  eth0 192.168.2.1/24   ← USB 2.5G/1G 网卡（netns 直通）                       │  │
│  │  veth-owrt 10.200.1.2/30                                                      │  │
│  └───────────────────────────────────┬───────────────────────────────────────────┘  │
│                                      │ veth                                       │
│                         veth-host 10.200.1.1/30                                    │
│                         iptables MASQUERADE · ip rule 90/100/101                   │
│                         table 100 (IPv4) / table 200,201 (IPv6)                    │
│                                      │                                             │
│                              rmnet_dataX (5G)                                     │
└──────────────────────────────────────┼─────────────────────────────────────────────┘
                                       ▼
                                   运营商 5G
```

---

## 2. 当前状态

### 2.1 设备与系统基线

| 项目 | 值 |
| :--- | :--- |
| 机型 | OnePlus 9 Pro / `lemonadep` / LE2120（国行） |
| Android | OOS 14 `LE2120_14.0.0.1901` |
| Bootloader | 已解锁 |
| AVB / dm-verity | A 槽已关闭，`vbmeta_a` flags = `0x3` |
| Root | Magisk 30.7 |
| 内核 | Linux `5.4.254-qgki-gd2a1055adeb0`（自定义，GitHub Actions run4，build `40346641157`） |
| KABI | **1,607 / 1,607** 导出符号 CRC 与原厂 99 个 `.ko` 完全匹配 |
| `Image` | 48,421,376 字节，SHA256 `732343e0…194ff09b` |
| 当前 boot | `artifacts/kernel_run4/new-boot-custom-v3.img`，SHA256 `3c6de08d…48335141` |
| 原厂 Root 回滚 boot | `magisk_patch/magisk_patched_boot_v30.7.img`，SHA256 `a7fb4a0a…0161b4d3d` |
| OpenWrt | 21.02.7 `armvirt/64`，`fw3` + `iptables-legacy` |
| 容器形式 | `unshare -m -u -n -p -f` + `chroot`，`procd` 是容器内 PID 1 |
| LAN | `eth0` = `192.168.2.1/24`（USB 2.5G/1G 网卡） |
| WAN | `veth-owrt` = `10.200.1.2/30` → 宿主 `veth-host` = `10.200.1.1/30` → 5G |

### 2.2 已验证能力

| 能力 | 结果 | 说明 |
| :--- | :---: | :--- |
| Android 正常开机 / 图形界面 | ✅ | 1440×3216 120Hz，触控正常 |
| 5G 数据 | ✅ | `rmnet_dataX` 获取 IPv4，容器内 ping `223.5.5.5` 0% 丢包 |
| 原厂模块兼容 | ✅ | 99 个 `.ko` 的 1,607 个符号需求全部满足；`msm_drm` / `wlan` / `camera` / 音频实际加载正常 |
| 指纹 | ✅ | `fps_hal=running`、`/dev/goodix_fp`、TEE `goodixfp` 正常 |
| 音频 / 相机 / 内部 WiFi | ✅ | 均保持 Android 原生功能 |
| USB 2.5G 网卡 | ✅ | `r8152 v2.22.1` 已内置内核，Magisk 模块已移除 |
| `PID_NS` | ✅ | `unshare -p -f` 内 PID=1，`procd` 不会误杀 Android |
| OpenWrt 服务 | ✅ | `procd` / `ubusd` / `uhttpd` / `dropbear` / `dnsmasq` / `odhcpd` |
| LAN DHCP | ✅ | PC 曾获得 `192.168.2.227` |
| LuCI | ✅ | 中文界面，`http://192.168.2.1/` 与 `http://10.200.1.2/` 均可访问 |
| IPv4 NAT | ✅ | LAN → veth → 宿主 MASQUERADE → 5G |
| 原生 IPv6 | ✅ | PC 获得运营商 `/64` 地址，可 ping 容器 `::1` 与外网 |
| 电源守护 | ✅ | `cpu7=0`、A55 1.32GHz、A78 1.44GHz、60% 停充 / 50% 恢复 |
| 开机自启 | ⚠️ | WAN-only 路径已验证；插网卡冷启动待验收 |

详细的测试过程、缺陷与修复记录见 **[`TEST_REPORT.md`](TEST_REPORT.md)**。

---

## 3. 关键设计决策

### 3.1 为什么是容器，不是 VM / 整机 OpenWrt

- 5G 基带依赖 Android 的 RIL/QMI、厂商 modem 固件和 Android telephony 栈，OpenWrt 没有这套东西；
- 保留 Android 才能继续使用相机、显示、音频、内部 WiFi、指纹和快充；
- 容器共享宿主内核，没有 VM 的 CPU/内存开销，也不需要给 OpenWrt 单独编内核；
- `procd` 需要独立 PID namespace 才能安全地当 PID 1，否则它会按宿主 PID 误杀 `zygote` / `system_server`。

### 3.2 为什么必须自定义内核

原厂内核缺几样关键能力：

| 能力 | 原厂 | 自定义 | 用途 |
| :--- | :---: | :---: | :--- |
| `CONFIG_PID_NS` | ❌ | ✅ | 容器内 `procd` 安全当 PID 1 |
| `CONFIG_DEVTMPFS` | ❌ | ✅ | 容器 `/dev` 正常 |
| `CONFIG_MACVLAN` | ❌ | ✅ | 备用网络方案 |
| 内置 `r8152 v2.22.1` | 旧驱动 | ✅ | RTL8156/B 2.5G |
| OPlus 指纹驱动 | 原厂名 | ✅ | 修复 `fps_hal` 崩溃与开机弹窗 |

为了不破坏原厂 99 个 `.ko` 的 ABI，自定义内核坚持 **最小 KABI 变更**：

- 开启：`PID_NS`、`DEVTMPFS`、`MACVLAN`、`IP6_NF_NAT`、`VETH`、`BRIDGE`、`TUN`、`OVERLAY_FS`、`TPROXY`、`SOCKET`、`r8152` 等；
- 保持关闭：`NF_TABLES`、`BRIDGE_NETFILTER`、`VLAN_8021Q`、`SYSVIPC`、`USER_NS` 等会改变结构体布局/CRC 的选项；
- 显式 `CONFIG_RELR=n`，保持原厂 RELA 重定位格式；
- 构建流程在打包前执行 **1,607 个符号 CRC 硬闸门**，不匹配直接失败，不会产出可刷入的 boot。

### 3.3 为什么是 OpenWrt 21.02

内核 `CONFIG_NF_TABLES=n`，而 22.03+ 默认 `fw4` + nftables。21.02 是最后一个默认 `fw3` + `iptables-legacy` 的版本，和当前内核能力完全对齐。

不是“5.4 内核跑不了新 OpenWrt”。23.05 的 arm64 用户态可以在 5.4 上运行，但必须禁用 `fw4`，且脚本要适配 `option device` 等差异。24.10 还改用 `apk`，迁移成本更高。

### 3.4 为什么 5G 和内部 WiFi 都不直通

- **5G**：`rmnet_dataX` 背后是 Android RIL/QMI + 厂商 modem 固件，OpenWrt 没有拨号栈；直通 netdev 也拨不了号。正确做法是 Android 做 WAN，容器通过 veth + NAT 使用它。
- **内部 WiFi**：`qcacld-3.0` / `cnss2` 是厂商驱动，AP 模式依赖厂商 `hostapd`、BDF 校准数据（`/mnt/vendor/persist`）和 `cnss-daemon`。把 `wlan0/wlan2` 移进容器会直接打断 Android WiFi/热点，且容器里没有 BDF 和厂商 hostapd，AP 起不来。

如果要让 OpenWrt 自己发 WiFi，现实路径是 **USB WiFi 网卡**（MT76 / RTW88 等 upstream 驱动），把驱动编进内核，再把 netdev 移进容器。内部 WiFi 不在考虑范围内。

### 3.5 USB 网卡 netns 直通

```bash
/data/adb/magisk/busybox ip link set eth0 netns <container-pid>
```

- 只有 USB 网卡被直通，容器拿到真实 LAN 口；
- 容器内统一改名为 `eth0`，配置 `192.168.2.1/24`；
- 宿主不再参与 LAN 侧 DHCP/NAT，避免双层 NAT；
- 网卡热插拔由 `04` 的重新探测 + 自启看门狗兜底。

### 3.6 IPv6

采用和 Android 热点相同的模型：**运营商 `/64` 同时用于上游和 LAN，按地址转发，不做 NAT66**。详见 **[`IPV6_NOTES.md`](IPV6_NOTES.md)**。

---

## 4. 目录结构

### 4.1 仓库

```text
sm8350_lahaina/
├── .github/workflows/          # 云端内核构建 + KABI 校验
├── configs/                    # 原厂 config、1,607 符号 CRC 黄金表
├── drivers/r8152/              # Realtek v2.22.1 驱动源码
├── firmware/rtl_nic/           # RTL8156 固件
├── anykernel/                  # AnyKernel3 配置
├── magisk/                     # r8152 兜底 Magisk 模块模板
├── scripts/                    # 03/04/05b/06、备份、KABI 校验
├── artifacts/                  # 构建产物（本地，不提交）
├── magisk_patch/               # 原厂 Root 回滚 boot（本地，不提交）
├── full_backup_.../            # 手机原始分区备份（本地，不提交）
├── backup_merged_.../          # 合并后的恢复集（本地，不提交）
├── firmware_.../               # 官方固件解包（本地，不提交）
├── openwrt_rootfs/             # OpenWrt rootfs tar.gz（本地，不提交）
└── *.md                        # 文档
```

### 4.2 手机运行目录（硬性规则）

OpenWrt 相关的包、软件、配置、脚本、镜像、状态、日志**只允许**放在 `/data/openwrt/`：

```text
/data/openwrt/
├── rootfs/      # OpenWrt 系统：软件包、二进制、/etc/config 配置
├── scripts/     # 03/04/05b、自启、守护脚本
├── packages/    # .ipk 包（如 luci-base）
├── images/      # rootfs tar.gz
├── run/         # container.pid / power_guard.pid
└── logs/        # autorun / power_guard / network / init 日志
```

Magisk 只保留一个入口：

```text
/data/adb/service.d/00_openwrt.sh   # 一行 exec，指向 /data/openwrt/scripts/service_openwrt_autorun.sh
```

不得再创建 `/data/adb/openwrt/`，也不要把 OpenWrt 脚本/包放到 `/sdcard`、`/data/local/tmp`。

---

## 5. 文档索引

| 文档 | 内容 |
| :--- | :--- |
| [`README_BUILD.md`](README_BUILD.md) | 内核构建、KABI 配置、刷机、OpenWrt 部署、验证与排错 |
| [`TEST_REPORT.md`](TEST_REPORT.md) | 已完成的测试、实验、缺陷与修复记录 |
| [`IPV6_NOTES.md`](IPV6_NOTES.md) | 原生 `/64` 共享、策略路由、NAT66 取舍与实测 |
| [`MASTER_PLAN.md`](MASTER_PLAN.md) | 总计划、阶段执行记录、决策与剩余工作 |
| [`RECOVERY_AND_ROLLBACK.md`](RECOVERY_AND_ROLLBACK.md) | 备份清单、Fastboot / 9008 回滚、软故障恢复 |
| [`AVB_DISABLED.md`](AVB_DISABLED.md) | AVB / dm-verity 关闭记录与注意事项 |

---

## 6. 快速开始

### 6.1 构建内核

GitHub Actions → **Build OnePlus 9 Pro 5.4 Kernel (OpenWrt + RTL8156B)** → Run workflow。

构建完成后必须看到：

```text
SUCCESS: 100% KABI CRC match with all 99 stock phone modules!
```

### 6.2 刷入

推荐用 **Kernel Flasher** 刷 `AnyKernel3-OnePlus9Pro-OpenWrt-5.4.zip`（保留 Magisk ramdisk）；也可以直接 fastboot 刷已打包好的 `new-boot-custom-v3.img`。详见 `README_BUILD.md` 第四节。

### 6.3 部署 OpenWrt

```bash
adb shell su -c "sh /data/openwrt/scripts/03_setup_openwrt_rootfs.sh"
adb shell su -c "sh /data/openwrt/scripts/04_start_openwrt_and_network.sh"
```

### 6.4 访问

| 来源 | 地址 |
| :--- | :--- |
| 电脑接 USB 网卡（LAN） | `http://192.168.2.1/` |
| 手机浏览器（宿主走 veth WAN） | `http://10.200.1.2/` |
| SSH（LAN） | `ssh root@192.168.2.1` |

> 容器有独立 network namespace，手机浏览器的 `localhost` 访问不到容器；必须用 `10.200.1.2`。

---

## 7. 三个备份文件夹

| 文件夹 | 是什么 | 文件数 | 大小 | 用途 |
| :--- | :--- | :---: | :---: | :--- |
| `full_backup_LE2120_14.0.0.1901/` | **手机原始全量备份**：117 个分区 `.img` + `by-name.txt` / `getprop.txt` / `FILELIST.txt` / `SHA256SUMS.txt` | 123 | 14.29 GiB | 原始证据、phone-only 分区来源 |
| `backup_merged_LE2120_14.0.0.1901/` | **合并后的最终恢复集**：117 个 `.img`，其中 60 个物理分区用官方固件镜像（按手机分区大小补齐），57 个 phone-only 分区来自原始备份；附 `MANIFEST.md` + `SHA256SUMS.txt` | 119 | 14.29 GiB | **日常回滚/恢复用这一套** |
| `firmware_LE2120_14.0.0.1901/` | 官方 OTA 解包出来的 43 个镜像（`boot.img`、`vendor_boot.img`、`modem.img` 等） | 43 | 8.84 GiB | 构建/对比的官方源材料，不是备份 |

**结论：需要恢复手机分区时，用 `backup_merged_LE2120_14.0.0.1901/`。**

它合并的原因是：`boot`、`vendor_boot`、`modem`、`xbl` 等 60 个物理分区直接取官方固件镜像更干净，避免把手机运行期的动态内容写回去；`modemst1/2`、`fsg`、`persist` 等 57 个 phone-only 分区必须保留手机原始数据。

---

## 8. 已知限制

1. **21.02 已 EOL**：feed 冻结；换 23.05 需要禁用 `fw4`，换 24.10 还要处理 `apk`。
2. **容器里的防火墙没有实际运行**：`fw3` 未启动，NAT/WAN 防火墙在 Android 宿主侧；容器内 `INPUT` 为空。不要把它当成安全边界。
3. **没有 user namespace / cgroup 隔离**：容器 root 就是宿主 root。
4. **Android 必须先启动**：容器由 Magisk `service.d` 在 Android 起来后拉起，不是独立双系统。
5. **5G 对 OpenWrt 不可见**：没有 QMI/MBIM，WAN 依赖 Android 数据连接。
6. **内部 WiFi 不能直通**：热点仍是 Android 的 AP，其客户端在 `192.168.69.0/24`，与容器 LAN 隔离。
7. **IPv6 前缀变化不会自动刷新**：重拨后运营商 `/64` 可能变化，需要重跑 `04` 或重启；脚本目前只处理 `/64`。
8. **Android OTA 会覆盖 `boot` / `vbmeta`**：升级后要重新验证 KABI 并重新刷内核。
9. **USB 网卡冷启动待验收**：当前只验证了 WAN-only 自启路径。
10. **AG / Clash 未预装**：容器具备 `TPROXY` / `TUN` / iptables 能力，但需要自行部署，且只能用 iptables，不能用 nftables。

---

## 9. 附录：官方内核源码调研

一加官方在 [OnePlusOSS](https://github.com/OnePlusOSS) 下开源 SM8350 代码。一加 9 Pro 全生命周期基于 Linux 5.4（高通 GKI v1），Android 14 对应分支：

| 系统版本 | 分支 | 内核 |
| :--- | :--- | :--- |
| Android 14 (OOS/ColorOS 14) | `oneplus/sm8350_u_14.0.0_oneplus9` | 5.4.254 |
| Android 13.1 | `oneplus/sm8350_t_13.1.0_oneplus9` | 5.4.210 |
| Android 13.0 | `oneplus/sm8350_t_13.0.0_op9` | 5.4.147 |
| Android 12.1 | `oneplus/sm8350_s_12.1_op9` | 5.4.147 |
| Android 12.0 | `oneplus/SM8350_S_12.0_9Pro` | 5.4.86 |
| Android 11 | `oneplus/SM8350_R_11.0` | 5.4.61 |

主内核仓库：`android_kernel_oneplus_sm8350`；厂商驱动/设备树：`android_kernel_modules_and_devicetree_oneplus_sm8350`。SM8350 不在新版 `kernel_manifest` 中，仍使用 `build/build.sh` 体系。`kernel_manifest` 只覆盖 SM8450 及更新平台。

---

## 10. 许可

本项目代码以 **GPL-2.0** 发布，详见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。Realtek 固件遵循其原始许可证。
