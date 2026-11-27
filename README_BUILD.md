# 构建、刷机、部署与验证

本文档记录当前固件的完整落地流程：**自定义 KABI 安全内核 → 刷入 boot → 部署 OpenWrt 21.02.7 容器 → 网络/自启 → 验证**。

> **当前基线（2026-11-27）**
> - Android：OOS 14 `LE2120_14.0.0.1901`，Magisk 31.1（`31.1:MAGISK:R`）
> - 内核：`5.4.254-qgki-gd2a1055adeb0`（`#1 SMP PREEMPT Fri Nov 27 06:15:42 UTC 2026`），GitHub Actions build `45950059781`（run6），已合入 0-KABI 补丁 `fix_oplus_warp_probe.patch`（`/sys/module/oplus_chg/parameters/disable_warp_probe=Y`，`0644`，实测 25 次拦截、0 次 `switch1_gpio:1`）
> - KABI：1,607 / 1,607 符号 CRC 匹配（开机实载 61 个原厂模块，`fps_hal=running`）
> - OpenWrt：21.02.7 `armvirt/64`（`fw3` + `iptables-legacy`）
> - `Image`：48,421,376 字节，SHA256 `aa9bcca8f875851778b371b28ed4bac5f0f1ce94f0cee0ef201f33c3f97a8575`
> - 当前 boot：`artifacts/kernel_run6/new-boot-custom-v4-magisk31.1.img`（201,326,592 字节，SHA256 `eadf3cf37bde2ea5402756eef01d68290be809d0d84bfd480a88fd22ed1b73d7`）
>
> 旧的“原厂内核 + r8152 Magisk 模块”路线仅作为**零刷机兜底/回滚参考**，不再是主路线。

---

## 1. 构建产物

| 产物 | 说明 |
| :--- | :--- |
| `AnyKernel3-OnePlus9Pro-OpenWrt-5.4.zip` | 给 Kernel Flasher 用；保留当前 boot 的 ramdisk（含 Magisk） |
| `Image` | 裸内核，48,421,376 字节（SHA256 `aa9bcca8…97a8575`）；**不能直接 fastboot 刷** |
| `Module.symvers` | 本次构建的导出符号 CRC，用于 KABI 审计与新固件对比 |
| `artifacts/kernel_run6/new-boot-custom-v4-magisk31.1.img` | 本地打包好的完整 boot（Magisk 31.1 ramdisk + Run #6 内核，201,326,592 字节），可直接刷 `boot_a` |
| `r8152_2p5g.ko` | 原厂内核兜底模块（由 `build_kernel.yml` 同步产出，当前已不使用） |
| `r8152-2.5G-Magisk-Module.zip` | 原厂内核 + Magisk 的免刷机方案（由 `build_kernel.yml` 同步产出，备用） |
| `stock-config-used.txt` | 本次实际使用的内核配置 |

关键事实：

| 项目 | 值 |
| :--- | :--- |
| 源码 | OnePlusOSS `oneplus/sm8350_u_14.0.0_oneplus9`（Linux 5.4.254） |
| 配置基线 | 从官方 `LE2120_14.0.0.1901` 的 `boot.img` 提取的真实运行配置 |
| 编译器 | Android Clang 11.0.2 `r383902b1` + GCC 4.9 交叉工具链 |
| 2.5G 驱动 | Realtek `r8152` v2.22.1，内置（`CONFIG_USB_RTL8152=y`） |
| localversion | `-qgki-gd2a1055adeb0`，与原厂模块 vermagic 对齐 |
| 重定位格式 | `CONFIG_RELR=n`（保持原厂 RELA） |
| KABI 闸门 | 1,607 个符号，99 个原厂模块，100% 匹配才允许打包 |

---

## 2. 内核配置：为什么这样选

### 2.1 硬约束：KABI

手机里有 99 个预编译厂商模块（`vendor_dlkm`、`vendor_boot` 等），它们用 `__versions` 记录每个导出符号的 CRC。内核只要改动结构体布局或导出符号集合，CRC 就会变化，模块会报：

```text
disagrees about version of symbol ...
Unknown symbol ...
```

因此本项目把 **1,607 个符号 CRC** 作为硬闸门。`scripts/verify_kabi_crc.py` 在 GitHub Actions 里执行，任何缺失/不匹配都会让构建失败。

黄金表：`configs/phone_kabi_crc.json`。

### 2.2 开启的选项（KABI 安全）

```text
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_PID_NS=y            # 容器内 procd 当 PID 1
CONFIG_NET_NS=y            # 已有
CONFIG_DEVTMPFS=y          # 容器 /dev
CONFIG_MACVLAN=y           # 备用网络方案
CONFIG_VETH=y              # 已有
CONFIG_BRIDGE=y            # 已有
CONFIG_TUN=y               # Clash TUN 等
CONFIG_OVERLAY_FS=y        # 已有
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_NAT=y        # 开启但当前不用于 NAT66
CONFIG_NETFILTER_XT_TARGET_TPROXY=y
CONFIG_NETFILTER_XT_MATCH_SOCKET=y
CONFIG_USB_RTL8152=y       # 内置 2.5G
CONFIG_USB_NET_CDC_NCM=y
CONFIG_USB_NET_AQC111=y
CONFIG_USB_NET_AX88179_178A=y
CONFIG_OPLUS_FINGERPRINT*=y
```

### 2.3 保持关闭的选项（会动 ABI / 当前不需要）

| 选项 | 状态 | 原因 |
| :--- | :---: | :--- |
| `CONFIG_NF_TABLES` | ❌ | 会改动 netfilter 相关结构，且 21.02 用 `fw3` 不需要 |
| `CONFIG_BRIDGE_NETFILTER` | ❌ | 改动 `sk_buff` / bridge 结构，KABI 风险 |
| `CONFIG_VLAN_8021Q` | ❌ | 当前不用 VLAN，避免结构体变化 |
| `CONFIG_SYSVIPC` | ❌ | 会引入 `IPC_NS` 相关布局变化 |
| `CONFIG_USER_NS` | ❌ | 不需要，且增加攻击面 |
| `CONFIG_RELR` | ❌ | 原厂用 RELA，开了会导致模块重定位不兼容 |

> `CONFIG_IP6_NF_NAT=y` 只是保留了能力；当前 IPv6 方案是原生 `/64` 共享，**没有 NAT66**。

### 2.4 原厂内核 vs 自定义内核

| 能力 | 原厂 | 自定义 |
| :--- | :---: | :---: |
| `PID_NS` | ❌ | ✅ |
| `DEVTMPFS` | ❌ | ✅ |
| `MACVLAN` | ❌ | ✅ |
| `IP6_NF_NAT` | ❌ | ✅（未使用） |
| 原生 IPv6 `/64` | ✅ | ✅ |
| RTL8156 2.5G | ❌（旧 r8152） | ✅ 内置 v2.22.1 |
| OPlus 指纹驱动 | ✅（旧命名） | ✅（`OPLUS_*` 命名） |
| OPLUS WARP D+/D- 探测开关 | ❌（充电时易切 `switch1_gpio:1` 断网卡） | ✅（`fix_oplus_warp_probe.patch`，默认 `disable_warp_probe=1`，可运行时切换） |
| `NF_TABLES` / `fw4` | ❌ | ❌ |
| KABI 兼容原厂模块 | — | ✅ 1,607/1,607 |

> **`fix_oplus_warp_probe.patch` 说明（0 KABI 变更）**：在 `drivers/power/oplus_chg/oplus_charger.c` 的 `oplus_chg_fast_switch_check()` 中增加模块参数 `/sys/module/oplus_chg/parameters/disable_warp_probe`（默认 `1`），跳过 OPLUS WARP/VOOC D+/D- 开关探测，避免带电扩展坞充电时硬件 mux `switch1_gpio:1` 抢占 D+/D- 导致 USB 网卡 `error -71` 掉线，同时完全保留普通 5V / USB-PD 充电。不改动任何结构体或导出符号（1,607 KABI CRC 保持 100% 一致）；直插原装快充头时可执行 `echo 0 > /sys/module/oplus_chg/parameters/disable_warp_probe` 运行时恢复。

---

## 3. 云端构建

GitHub Actions → **Build OnePlus 9 Pro 5.4 Kernel (OpenWrt + RTL8156B)** → **Run workflow**。

工作流会：

1. 下载 Clang `r383902b1` + GCC 4.9 工具链；
2. 克隆 OnePlusOSS 内核与 `modules_and_devicetree`，覆盖 `vendor` / `techpack` / `device`；
3. 用 `drivers/r8152/` 替换内核里的旧 `r8152.c`，随后通过 `git apply --check -p1` / `git apply -p1` 应用 `fix_oplus_warp_probe.patch`（0-KABI WARP 探测开关）并校验 `disable_warp_probe` 落位；
4. 以 `configs/stock_le2120_1901.config` 为基线，打开第 2 节的选项；
5. 强制检查关键 `CONFIG_*`，缺一个就失败；
6. 编译 `Image`；
7. **执行 KABI CRC 校验**，失败即终止；
8. 额外编译 `r8152_2p5g.ko` 兜底模块；
9. 打包 AnyKernel3 与 Magisk 模块。

必须看到：

```text
KABI check: vmlinux exports=..., required by phone modules=1607
  matched   : 1607/1607
  missing   : 0
  mismatched: 0
SUCCESS: 100% KABI CRC match with all 99 stock phone modules!
```

产物在 Actions 运行页最下方 **Artifacts**。

---

## 4. 刷入自定义内核

### 4.1 推荐：Kernel Flasher + AnyKernel3

1. 把 `AnyKernel3-OnePlus9Pro-OpenWrt-5.4.zip` 传到手机；
2. 打开 **Kernel Flasher**；
3. 选择 zip → 刷入 → 重启。

AnyKernel3 会：

- 识别 A/B 槽位（`IS_SLOT_DEVICE=1`）；
- `dump_boot` 解包当前 boot；
- 只替换 kernel；
- `write_boot` 重新打包并写回。

**它保留原 boot 的 ramdisk，所以 Magisk 不会掉。**

### 4.2 直接 fastboot 刷完整 boot

如果已经有打包好的 `new-boot-custom-v4-magisk31.1.img`（Magisk ramdisk + 自定义内核）：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb getvar current-slot
& $fb flash boot_a artifacts\kernel_run6\new-boot-custom-v4-magisk31.1.img
& $fb reboot
```

> **不要** `fastboot flash boot Image`：`Image` 只是裸内核，不是 boot 镜像。
> **不要** `fastboot flash boot AnyKernel3-*.zip`：zip 不是分区镜像。

### 4.3 刷完验证

```bash
adb shell uname -a
# 期望：Linux localhost 5.4.254-qgki-gd2a1055adeb0 #1 SMP PREEMPT Fri Nov 27 06:15:42 UTC 2026 aarch64 Toybox

adb shell su -c "cat /sys/module/oplus_chg/parameters/disable_warp_probe"
# 期望：Y（权限 0644；如需直插原装快充头临时恢复，可执行 echo 0 > ...）
adb shell su -c "dmesg | grep -E 'disable_warp_probe|switch1_gpio:1|warp mode'"
# 期望：仅有 disable_warp_probe,return，零 switch1_gpio:1 / warp mode

adb shell su -c "lsmod | wc -l"
# 期望：62（61 个已加载原厂模块 + 表头）

adb shell su -c "dmesg | grep -i r8152"
adb shell su -c "grep r8152 /proc/kallsyms | head"
adb shell su -c "lsusb"
adb shell su -c "ip -br link"

# PID namespace
adb shell su -c "/data/adb/magisk/busybox unshare -p -f sh -c 'echo pid_inside_ns=\$\$'"
# 期望：pid_inside_ns=1

# 指纹
adb shell getprop init.svc.fps_hal
# 期望：running
adb shell dumpsys fingerprint | head -20
adb shell ls -l /dev/goodix_fp
```

插上 2.5G 网卡后，`ip -br link` 应出现 `eth0`，`dmesg` 应打印：

```text
Realtek RTL8152/RTL8153 Based USB Ethernet Adapters v2.22.1
```

---

## 5. 原厂内核兜底（可选，非当前路线）

如果只想零刷机验证，可用原厂内核 + `r8152-2.5G-Magisk-Module.zip`：

1. GitHub Actions → **Build OnePlus 9 Pro 5.4 Kernel (OpenWrt + RTL8156B)**（`.github/workflows/build_kernel.yml` 会同步产出 `r8152_2p5g.ko` 与 `r8152-2.5G-Magisk-Module.zip`）；
2. 下载 zip → Magisk App → 模块 → 从本地安装；
3. 重启，检查 `lsmod | grep r8152`。

模块里的驱动名是 `r8152_2p5g`，避免和原厂内置 `r8152` 冲突。

限制：

- 原厂内核没有 `PID_NS`，`procd` 不能安全当 PID 1；只能做降级的 mount/net/UTS chroot，或者用别的 init；
- 原厂内核没有 `DEVTMPFS`，需要 bind-mount `/dev`；
- 仍然没有 `NF_TABLES`，只能用 21.02 `fw3`；
- 模块依赖 vermagic / 符号 CRC 完全匹配，`insmod` 报 `disagrees about version of symbol` 就说明不匹配。

当前手机已改用内置 `r8152` 的自定义内核，Magisk 模块已卸载。

---

## 6. 部署 OpenWrt

### 6.1 选择 rootfs

| rootfs | 防火墙 | 状态 |
| :--- | :--- | :--- |
| `openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz` | `fw3` + `iptables-legacy` | ✅ **当前使用** |
| `openwrt-22.03.7-armvirt-64-default-rootfs.tar.gz` | `fw4` + nftables | ❌ 内核无 `NF_TABLES`，默认不可用 |
| `openwrt-23.05.5-armsr-armv8-rootfs.tar.gz` | `fw4` + nftables | ⚠️ 需禁用 `fw4` 并改用 `option device`，未正式采用 |
| OpenWrt 24.10+ | `fw4` + `apk` | ⚠️ 需改包管理，未验证 |

> 22.03+ 不是“内核版本不兼容”，而是 **默认防火墙栈不兼容**。要上 23.05，必须 `fw4` 不启动，LAN 侧防火墙/NAT 继续由宿主或 iptables 承担。

### 6.2 推送到手机

`/data/openwrt` 是 root 目录，不能直接 `adb push`；先推到 `/data/local/tmp`，再用 `su` 归位。

```powershell
# 1) 推送到临时目录
adb push openwrt_rootfs\openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz /data/local/tmp/
adb push scripts\03_setup_openwrt_rootfs.sh /data/local/tmp/03_setup_openwrt_rootfs.sh
adb push scripts\04_start_openwrt_and_network.sh /data/local/tmp/04_start_openwrt_and_network.sh
adb push scripts\05b_cpu_charge_guard.sh /data/local/tmp/05b_cpu_charge_guard.sh
adb push scripts\05_headless_power_control.sh /data/local/tmp/05_headless_power_control.sh
adb push service_openwrt_autorun.sh /data/local/tmp/service_openwrt_autorun.sh
adb push service_power_guard.sh /data/local/tmp/service_power_guard.sh

# 2) 归位到唯一目录
adb shell su -c "mkdir -p /data/openwrt/scripts /data/openwrt/packages /data/openwrt/images /data/openwrt/run /data/openwrt/logs"
adb shell su -c "mv /data/local/tmp/openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz /data/openwrt/images/"
adb shell su -c "mv /data/local/tmp/03_setup_openwrt_rootfs.sh /data/openwrt/scripts/"
adb shell su -c "mv /data/local/tmp/04_start_openwrt_and_network.sh /data/openwrt/scripts/"
adb shell su -c "mv /data/local/tmp/05b_cpu_charge_guard.sh /data/openwrt/scripts/"
adb shell su -c "mv /data/local/tmp/05_headless_power_control.sh /data/openwrt/scripts/"
adb shell su -c "mv /data/local/tmp/service_openwrt_autorun.sh /data/openwrt/scripts/"
adb shell su -c "mv /data/local/tmp/service_power_guard.sh /data/openwrt/scripts/"
adb shell su -c "chmod 755 /data/openwrt/scripts/*.sh"

# 3) 唯一 Magisk 入口（必须清掉 Magisk BusyBox ash 的 ASH_STANDALONE，交给 /system/bin/sh）
adb shell su -c "printf '#!/system/bin/sh\nunset ASH_STANDALONE\nexec /system/bin/sh /data/openwrt/scripts/service_openwrt_autorun.sh\n' > /data/adb/service.d/00_openwrt.sh"
adb shell su -c "chmod 755 /data/adb/service.d/00_openwrt.sh"
```

### 6.3 部署 rootfs

```bash
adb shell su -c "sh /data/openwrt/scripts/03_setup_openwrt_rootfs.sh"
```

`03` 会：

- 解压到 `/data/openwrt/rootfs`（**会先清空该目录**，升级前备份 `/etc/config` 和 `packages/`）；
- 自动识别 21.02 / 23.05，选择 `option ifname` 或 `option device`；
- 写入 `lan`（`192.168.2.1/24`）、`wan`（`10.200.1.2/30`，网关 `10.200.1.1`）；
- 写入 `firewall`（LAN→WAN 转发 + masq）和 `dhcp`（含 `config dnsmasq`、`odhcpd` RA）；
- 添加 `Allow-Host-UI` 规则：只允许 `10.200.1.1` 访问容器 80/443；
- 把 `uhttpd.rfc1918_filter` 设为 `0`，否则宿主从 veth 访问会被当公网地址拒绝；
- 用假 `modprobe` 绕过 OpenWrt 的 kmod 依赖（驱动已编进内核）；
- 修补 dropbear init 的 `mktemp -d` 缺陷（否则会 `mv /* /etc/dropbear` 搬空 rootfs）；
- **禁用容器 RTC/NTP 时间处理**：删除 `sysfixtime` / `sysntpd` 的 rc 链接，替换 `sysfixtime` 为 no-op，注释 `hwclock --systz`，关闭容器 NTP client。Android 拥有系统时钟，容器绝不能读写 `/dev/rtc0`。

### 6.4 启动容器与网络

```bash
adb shell su -c "sh /data/openwrt/scripts/04_start_openwrt_and_network.sh"
```

`04` 会：

1. 校验 `PID_NS`，没有就直接拒绝启动（避免 `procd` 在宿主 PID namespace 里当前 PID 1）；
2. `unshare -m -u -n -p -f`，`chroot` 到 `/data/openwrt/rootfs`，启动 `/sbin/init`；
3. bind-mount `/dev`、`/dev/pts`、`/sys`，挂载独立 `/proc`；
4. 把 USB 网卡（`eth0` / `usb0` / `eth1`）移进容器 netns，改名为 `eth0`；
5. 创建 `veth-host` ↔ `veth-owrt`，配置 `10.200.1.1/30` ↔ `10.200.1.2/30`；
6. 容器默认路由 `via 10.200.1.1`；
7. 宿主开启 `ip_forward` / IPv6 forwarding，关闭相关 `rp_filter`；
8. 宿主 `iptables` MASQUERADE + FORWARD；
9. 建 IPv4 表 100：

```text
default via <5G网关> dev <rmnet>        # 5G 默认
10.200.1.0/30 dev veth-host            # 直连，必须存在
```

10. 策略路由：

```text
90:  to 10.200.1.0/30 lookup main      # 宿主访问容器（LuCI/SSH）
100: from 10.200.1.0/30 lookup 100     # 容器出站走 5G
101: iif <rmnet> to 10.200.1.0/30 lookup main   # 回程
```

11. IPv6：
    - 从 `rmnet` 读取全局 `/64`；
    - 容器 `eth0` 配 `::1/64`；
    - `veth-host` `fe80::1`，`veth-owrt` `fe80::2`，容器默认 `via fe80::1 dev veth-owrt onlink`；
    - 宿主 table 200：`<prefix>/64 via fe80::2 dev veth-host onlink`（必须指定 `via fe80::2`，避免 Android 在 `veth-host` 上对 LAN 客户端发 NDP 解析失败）；rule `iif <rmnet> lookup 200 pref 1000`；
    - 宿主 table 201：5G IPv6 默认；rule `from <prefix> lookup 201 pref 1001`；
    - 容器内 `odhcpd` 发 RA，客户端 SLAAC。
12. 在 `netifd` / IPv6 全部稳定后，于 `04` 末尾重启 `/etc/init.d/firewall` 并校验 `zone_wan_postrouting`（`MASQUERADE`）与 `zone_wan_input`（`Allow-Host-UI`），不完整则重试一次。

补充的可靠性措施：

- **三层清除 Magisk `ASH_STANDALONE=1`**：`00_openwrt.sh`、`service_openwrt_autorun.sh`、`04_start_openwrt_and_network.sh` 入口均 `unset ASH_STANDALONE` 并重执 `/system/bin/sh`（mksh），防止 Magisk BusyBox ash 独立模式忽略 `PATH` 导致 BusyBox `ip`/`ps` 失效；
- 启动前按 `/proc/<pid>/root` 清理整个容器进程树（若仍有 `procd` 残留则走全 `/proc` 回退清理），避免失败启动泄漏 PID/netns；
- `04` 用目录锁串行化，autorun 与手动执行不会并发创建 veth；
- 严格用 `pgrep -P "$UNSHARE_PID"`（回退 `ps -A -o PID,PPID`）定位新容器 init PID，绝不回退匹配任意 rootfs 进程；
- veth 用 toybox `ip link add name ... peer name ...`，并校验 peer 存在；
- `ensure_usb_host_mode()` 严守 `mode=peripheral` 不碰 PC 数据线，支持 `data_role=[host]` 及带电非 PD 扩展坞热插（`mode=none` + `data_role=[device]` + `USB_DCP`）；在 `mode=none` 或 `mode=host` 且无 xHCI 设备时，按缓存 `/data/openwrt/run/usb3_orient` 优先探测 `/sys/devices/platform/soc/a600000.ssusb/orientation`（`A`/`B`），锁定 **USB 3.0 SuperSpeed 5000 Mbps（`usb 3-1`）** 边充边用（Run #6 `disable_warp_probe=Y` 时无需暂关 `mmi_charging_enable`，仅在旧内核回退时暂关；纯墙充无网卡时恢复 `mode=none` 并在看门狗里退避 5 分钟 = `60 × 5s`）；
- 容器 init 与 reload 全部完成后把 `/dev/rtc0` / `/dev/rtc` 覆盖成 `/dev/null`；
- 5G PDN 抖动时 `04` 重试 30 秒；autorun 等待 180 秒；
- 找 5G 接口用 `ip -4 route show table all`，不依赖 Wi-Fi 可能占据的系统默认路由。

> 时钟细节见 [`TIME_NOTES.md`](TIME_NOTES.md)。

### 6.5 开机自启

唯一入口：

```text
/data/adb/service.d/00_openwrt.sh
```

内容（必须先 `unset ASH_STANDALONE`，再由 `/system/bin/sh` 启动）：

```sh
#!/system/bin/sh
unset ASH_STANDALONE
exec /system/bin/sh /data/openwrt/scripts/service_openwrt_autorun.sh
```

自启脚本会：

1. 先以 `/system/bin/sh` 启动电源守护（cpu7 离线、50–60% 停充）；
2. 等 `sys.boot_completed=1`（最多 180 秒）；
3. 通过 `find_rmnet_wan()` 等 5G 活跃路由（最多 180 秒）；
4. 调用 `ensure_usb_host_mode()` 并等 USB 网卡（`eth0`/`usb0`/`eth1`，最多 30 秒）；
5. 容器没跑就以 `/system/bin/sh` 执行 `04`；
6. **快速 5 秒看门狗 + 30 秒周期检查（每第 6 拍）**：
   - 每 **5 秒**：
     - 检查容器存活，挂了立即重跑 `04`；
     - 若容器缺少 LAN（`! container_has_lan`），调用 `ensure_usb_host_mode()`（支持 `data_role=[host]` 与 `USB_DCP` 非 PD 坞热插，探测并缓存 `orientation` A/B 至 `/data/openwrt/run/usb3_orient` 锁定 USB 3.0 5000 Mbps；纯墙充退避 5 分钟 = `60 × 5s`）；
     - 检测到宿主出现 USB 网卡（`host_has_lan`）时，优先调用 **`attach_lan_inplace()` 原地热挂**：直接把网卡移入运行中容器 netns（不重启 `procd`、不断 `10.200.1.2`），配置 `eth0` IPv4 + 重配运营商原生 IPv6 `/64` + 宿主 `table 200`（`via fe80::2 onlink`）+ 重启 `dnsmasq`/`odhcpd` + 校验 `fw3`，实测断连至恢复仅 **11 秒**；仅在原地热挂失败时回退完整 `04` 重启；
   - 每 **30 秒（第 6 拍）**：
     - `ensure_wan()`：重断言 `ip_forward` / IPv6 forwarding、table 100、rule 90/100/101，以及宿主 `iptables` `MASQUERADE` / `FORWARD` 规则；
     - 调用 `service_power_guard.sh` 保活电源守护；
     - 调用 `ensure_container_fw()` 校验并自愈容器 `fw3`（`zone_wan_postrouting` `MASQUERADE` 与 `zone_wan_input`），**LAN 与 WAN-only 双模式均执行**。

临时禁用自启（不删入口）：

```bash
adb shell su -c "touch /data/openwrt/disable_autorun"
```

恢复：

```bash
adb shell su -c "rm -f /data/openwrt/disable_autorun"
```

### 6.6 访问地址

| 来源 | 地址 |
| :--- | :--- |
| 电脑接 USB 网卡（LAN） | `http://192.168.2.1/` |
| 手机浏览器（veth WAN） | `http://10.200.1.2/` |
| SSH（LAN） | `ssh root@192.168.2.1` |

> 容器的 `localhost` 和 Android 的 `localhost` 不是同一个 netns；手机浏览器不能用 `localhost:443`。

---

## 7. 验证清单

### 7.1 宿主

```bash
adb shell su -c "cat /proc/sys/net/ipv4/ip_forward"          # 1
adb shell su -c "ip rule | head -8"                          # 90/100/101
adb shell su -c "ip route show table 100"                    # 5G default + veth link
adb shell su -c "ip -6 rule | head -8"                       # pref 1000/1001
adb shell su -c "ip -6 route show table 200"                 # via fe80::2 dev veth-host onlink
adb shell su -c "iptables -t nat -S POSTROUTING | grep 10.200.1"
adb shell su -c "cat /sys/devices/platform/soc/a600000.ssusb/mode"
adb shell su -c "cat /sys/module/oplus_chg/parameters/disable_warp_probe" # 含 WARP 补丁内核期望 Y
```

### 7.2 容器

```bash
P=$(cat /data/openwrt/run/container.pid)
BB=/data/adb/magisk/busybox
$BB nsenter -t "$P" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c '
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  ps | head
  ip -4 addr show eth0
  ip -4 addr show veth-owrt
  ip -6 addr show eth0
  ip route
  ip -6 route
  ping -c 2 223.5.5.5
'
```

### 7.3 宿主导航到 LuCI

```bash
/data/adb/magisk/busybox wget -O - http://10.200.1.2/ | head
```

应返回 200 和跳转到 `cgi-bin/luci/` 的页面。

### 7.4 生产环境 USB 3.0（5000 Mbps）验证指南

判断 USB 网卡是否真正以 **USB 3.0 SuperSpeed（5000 Mbps）** 协商的**权威检查项**：

1. `/sys/bus/usb/devices/3-[1-9]*/speed` = **`5000`**（Mbps，挂在 `usb3` 总线）且 `version` = `3.00` / `3.20`；若被降级到 USB 2.0，设备会出现在 `2-1`，`speed` = **`480`**；
2. `/sys/devices/platform/soc/a600000.ssusb/orientation` 为 `A` 或 `B`（与 `/data/openwrt/run/usb3_orient` 缓存一致）；
3. `/sys/module/oplus_chg/parameters/disable_warp_probe` = **`Y`**，且充电时 `power_role` 包含 `[sink]`。

> **不要用以下两个指标误判 USB 3.0**：
> - `/sys/devices/platform/soc/a600000.ssusb/speed` 输出 `super-speed` 只代表控制器**最大硬件能力**，即使外设掉到 USB 2.0 它也依然显示 `super-speed`；
> - `eth0` 的 RJ45 链路速率（`1000` / `2500` Mbps）只代表网线/交换机侧协商速率，**不能证明 USB 总线跑在 5000 Mbps**。

一行核验命令：

```bash
adb shell su -c 'for d in /sys/bus/usb/devices/[23]-[1-9]*; do [ -f "$d/idVendor" ] && echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) speed=$(cat $d/speed)Mbps usb=$(cat $d/version | tr -d " ") $(cat $d/product 2>/dev/null)"; done; echo "mode=$(cat /sys/devices/platform/soc/a600000.ssusb/mode) orient=$(cat /sys/devices/platform/soc/a600000.ssusb/orientation) warp_dis=$(cat /sys/module/oplus_chg/parameters/disable_warp_probe) power=$(cat /sys/class/typec/port0/power_role)"'
```

---

## 8. 实测缺陷与修复

| 现象 | 根因 | 修复 |
| :--- | :--- | :--- |
| 容器启动后 rootfs 被搬空 | BusyBox `mktemp -d` 无模板，`tdir` 为空，dropbear init 执行 `mv /* /etc/dropbear` | `03` 强制 `mktemp -d /tmp/dropbear.XXXXXX` 并给 `mv` 加保护 |
| dnsmasq 不启动 | `/etc/config/dhcp` 只有 `config dhcp`，缺 `config dnsmasq` | `03` 补全 dnsmasq 全局段 |
| IPv6 LAN 地址刚加就被刷掉 | `network reload` 异步执行，随后 flush | `04` 等 netifd 稳定后再加地址，并 `sleep 2` |
| `ip addr replace` 报错 | Android toybox `ip` 不支持 `replace` | 改用 `ip addr add` |
| 重启容器时找不到 eth0 | 旧容器还持有 netns，探测过早 | 先停旧容器，再重新探测网卡 |
| `ip_forward` 被重置 | Android netd 在网络变化时重置 | 自启看门狗每 30 秒重新断言 |
| 宿主能 ping 容器但 TCP 不通 | table 100 缺 `10.200.1.0/30 dev veth-host` 直连路由 | `04` 显式添加 |
| 宿主访问 `10.200.1.2` 走 5G | 默认路由优先，`from 10.200.1.0/30` 规则匹配不到宿主自身流量 | 增加 `ip rule add to 10.200.1.0/30 lookup main pref 90` |
| 手机浏览器打不开 LuCI | uhttpd 的 RFC1918 过滤把 veth 私网当公网拒绝 | `rfc1918_filter=0` + 仅允许 `10.200.1.1` 的防火墙规则 |
| LuCI 中文装不上 | opkg 索引架构文件名不匹配 | 手工安装 `luci-base` / `luci-i18n-*-zh-cn`，设置 `luci.main.lang=zh-cn` |
| 电源守护不生效 | PID 文件跨重启残留，PID 被复用 | 校验 `/proc/<pid>/cmdline` 确实是守护进程 |
| 迁移路径后新守护不启动 | 旧守护仍以已删除路径运行，PID 文件有效 | 杀掉旧进程、清 pid、重启守护 |
| 看门狗只拉容器不拉守护 | 自启循环缺守护检查 | 每 30 秒调用 `service_power_guard.sh` |
| 开机“设备内部出现问题” | 内核缺 `CONFIG_OPLUS_FINGERPRINT*`，`fps_hal` 崩溃循环 | 打开 OPlus 指纹驱动；一次性提示点掉后不再出现 |
| 容器启动后 Android 时间跳回 1970 | OpenWrt `sysfixtime` 用 `hwclock -s` 读宿主 RTC（停在 1970）并写入系统时钟；关机又 `hwclock -w` 写回 | `03` 禁用 `sysfixtime`/`sysntpd`/`hwclock --systz`；`04` 在 init 后把 `/dev/rtc0` 覆盖为 `/dev/null` |
| 容器每 30 秒失败重启并泄漏几百个实例 | pid 文件指向 unshare wrapper；失败时只杀 wrapper；veth peer 未创建 | 按 `/proc/<pid>/root` 杀整个进程树；等 PID namespace init；toybox 显式 `name` 创建 veth 并校验 peer；`04` 加锁 |
| `veth peer veth-owrt was not created` | 创建 veth 时 `ip` 解析到 BusyBox 或被并发 04 删除 | `04` 强制 toybox PATH；目录锁串行化；创建后校验 |
| Wi-Fi 是默认路由时 autorun 一直等 5G / 04 选不到 WAN | `ip route get 8.8.8.8` 返回 `wlan0`，旧逻辑只认默认路由 | `find_rmnet_wan` 用 `ip -4 route show table all` 找 rmnet 默认；autorun 等 180 秒；`04` 重试 30 秒 |
| 容器内 `date` 与宿主不一致 | 容器曾执行 `hwclock -s` / NTP | 容器禁用时间服务并隐藏 RTC；Android `auto_time=1`、`ntp_server=ntp.aliyun.com` |
| Magisk `service.d` 下 `veth-owrt` 反复创建失败且每 30 秒泄漏容器 | Magisk 在 BusyBox ash `ASH_STANDALONE=1` 模式运行脚本（忽略 `PATH`），BusyBox `ip` 建不出命名 peer、BusyBox `ps` 无 `-A -o` | `00_openwrt.sh`、`service_openwrt_autorun.sh`、`04` 三层 `unset ASH_STANDALONE` + `exec /system/bin/sh`，并改用 `pgrep -P` 严格匹配容器 init PID |
| PC 原生 IPv6 ping 外网 100% 丢包 | 宿主 `table 200` 原为 `<prefix>/64 dev veth-host`，Android 在 `veth-host` 上对 LAN 客户端发 NDP 解析失败 | 改为 `via fe80::2 dev veth-host onlink table 200`；PC ping `2400:3200::1` 34–53 ms、0% 丢包 |
| 容器冷启动后 `fw3` 规则为空（手机打不开 LuCI 或 LAN 无 NAT） | `04` 启动时与 `procd`/`S19firewall` 及异步 `netifd reload` 竞态 | 将 `/etc/init.d/firewall restart` 移至 `04` 末尾并校验重试；看门狗每 30 秒（5s 循环第 6 拍）在 LAN 与 WAN-only 双模式下执行 `ensure_container_fw()` 自愈 |
| 带电扩展坞重插/充电时 USB 网卡掉线或 `error -71` | VBUS 触发 `oplus_otg_disable_work` 将 dwc3 打回 `mode=none`；充电时 OPLUS `oplus_chg_fast_switch_check()` 翻转 `switch1_gpio:1`（WARP）抢占 D+/D- | Run #6 合入 0-KABI 补丁 `fix_oplus_warp_probe.patch`（`disable_warp_probe=Y`，实测 25 次拦截/0 次 `switch1_gpio:1`）；用户态升级为 5 秒看门狗 + `ensure_usb_host_mode()`（严守 `mode=peripheral`）+ `attach_lan_inplace()` 原地热挂（11s 自愈、不重启 `procd`） |
| 恢复 USB Host 后网卡降级为 USB 2.0（480 Mbps） | 强写 `mode=host` 缺少 Type-C 极性事件，`ss_phy` 未设置 `PHY_LANE_A/B` | `ensure_usb_host_mode()` 探测 `a600000.ssusb/orientation`（`A`/`B`）并缓存至 `/data/openwrt/run/usb3_orient`，锁定 `usb 3-1` **5000 Mbps** 边充边用 |

更完整的测试记录见 **[`TEST_REPORT.md`](TEST_REPORT.md)**。

---

## 9. 回滚

详见 **[`RECOVERY_AND_ROLLBACK.md`](RECOVERY_AND_ROLLBACK.md)**。工作区不再留存旧备份 `.img`（由用户在工作区外自行保管初始 Root boot 与 117 分区备份），最快回滚路径：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
$backup = "<你的外部备份路径>"
& $fb flash boot_a "$backup\stock_magisk_boot.img"
& $fb reboot
```

这只回滚内核，不动数据分区。OpenWrt 容器故障通常不需要刷机，删掉 `/data/adb/service.d/00_openwrt.sh` 或 `touch /data/openwrt/disable_autorun` 即可。

---

## 10. Android OTA 与 KABI 复验

Android OTA 会覆盖 `boot`（自定义内核丢失）和 `vbmeta_a`（AVB 重新启用）。**是否需要重编内核，取决于新固件 vendor 模块的符号 CRC。**

流程：

1. 从新固件解包 `vendor_dlkm` / `vendor_boot` 里的 `.ko`；
2. 解析每个 `.ko` 的 `__versions`，生成新的 CRC 表；
3. 与当前 `artifacts/kernel_run6/Module.symvers` 对比；
4. 结果：
   - **1,607 个符号全部匹配** → 直接用现有 `Image` 重新打包 Magisk boot，刷 `boot_a`，**不用重编**；
   - **任意不匹配** → 必须按新固件源码重编内核，并重新跑 KABI 闸门。

当前黄金表 `configs/phone_kabi_crc.json` 对应 `LE2120_14.0.0.1901`。换固件后要重新生成。

---

## 11. 构建失败排查

GitHub Actions 运行页 → 失败步骤 → 展开日志：

- `Prepare KABI-safe config`：哪个 `CONFIG_*` 没开；
- `Compile kernel Image`：第一个 `error:`；
- `Verify 100% KABI CRC`：哪个符号 `MISSING` / `MISMATCH`；
- `Build out-of-tree r8152_2p5g.ko`：vermagic / CRC 问题；
- `Package AnyKernel3`：`Image` 是否生成。

KABI 失败时不要绕过闸门——刷进去会导致原厂模块拒绝加载，手机可能卡开机。
