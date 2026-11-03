# 构建、刷机、部署与验证

本文档记录当前固件的完整落地流程：**自定义 KABI 安全内核 → 刷入 boot → 部署 OpenWrt 21.02.7 容器 → 网络/自启 → 验证**。

> **当前基线（2026-10）**
> - Android：OOS 14 `LE2120_14.0.0.1901`
> - 内核：`5.4.254-qgki-gd2a1055adeb0`，GitHub Actions build `40346641157`（run4）
> - KABI：1,607 / 1,607 符号 CRC 匹配
> - OpenWrt：21.02.7 `armvirt/64`（`fw3` + `iptables-legacy`）
> - 当前 boot：`artifacts/kernel_run4/new-boot-custom-v3.img`
>
> 旧的“原厂内核 + r8152 Magisk 模块”路线仅作为**零刷机兜底/回滚参考**，不再是主路线。

---

## 1. 构建产物

| 产物 | 说明 |
| :--- | :--- |
| `AnyKernel3-OnePlus9Pro-OpenWrt-5.4.zip` | 给 Kernel Flasher 用；保留当前 boot 的 ramdisk（含 Magisk） |
| `Image` | 裸内核，48,421,376 字节；**不能直接 fastboot 刷** |
| `Module.symvers` | 本次构建的导出符号 CRC，用于 KABI 审计与新固件对比 |
| `new-boot-custom-v3.img` | 已打包好的完整 boot（Magisk ramdisk + 自定义内核），可直接刷 `boot_a` |
| `r8152_2p5g.ko` | 原厂内核兜底模块（当前已不使用） |
| `r8152-2.5G-Magisk-Module.zip` | 原厂内核 + Magisk 的免刷机方案（备用） |
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
| `NF_TABLES` / `fw4` | ❌ | ❌ |
| KABI 兼容原厂模块 | — | ✅ 1,607/1,607 |

---

## 3. 云端构建

GitHub Actions → **Build OnePlus 9 Pro 5.4 Kernel (OpenWrt + RTL8156B)** → **Run workflow**。

工作流会：

1. 下载 Clang `r383902b1` + GCC 4.9 工具链；
2. 克隆 OnePlusOSS 内核与 `modules_and_devicetree`，覆盖 `vendor` / `techpack` / `device`；
3. 用 `drivers/r8152/` 替换内核里的旧 `r8152.c`；
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

如果已经有打包好的 `new-boot-custom-v3.img`（Magisk ramdisk + 自定义内核）：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb getvar current-slot
& $fb flash boot_a artifacts\kernel_run4\new-boot-custom-v3.img
& $fb reboot
```

> **不要** `fastboot flash boot Image`：`Image` 只是裸内核，不是 boot 镜像。
> **不要** `fastboot flash boot AnyKernel3-*.zip`：zip 不是分区镜像。

### 4.3 刷完验证

```bash
adb shell uname -r
# 期望：5.4.254-qgki-gd2a1055adeb0

adb shell su -c "dmesg | grep -i r8152"
adb shell su -c "grep r8152 /proc/kallsyms | head"
adb shell su -c "lsusb"
adb shell su -c "ip -br link"

# PID namespace
adb shell su -c "/data/adb/magisk/busybox unshare -p -f sh -c 'echo pid_inside_ns=\$\$'"
# 期望：pid_inside_ns=1

# 指纹
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

1. GitHub Actions → **Build r8152 2.5G Module for Stock Kernel**；
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

# 3) 唯一 Magisk 入口
adb shell su -c "printf '#!/system/bin/sh\nexec sh /data/openwrt/scripts/service_openwrt_autorun.sh\n' > /data/adb/service.d/00_openwrt.sh"
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
    - `veth-host` `fe80::1`，`veth-owrt` `fe80::2`，容器默认 `via fe80::1`；
    - 宿主 table 200：`<prefix>/64 dev veth-host`；rule `iif <rmnet> lookup 200 pref 1000`；
    - 宿主 table 201：5G IPv6 默认；rule `from <prefix> lookup 201 pref 1001`；
    - 容器内 `odhcpd` 发 RA，客户端 SLAAC。

补充的可靠性措施：

- 启动前按 `/proc/<pid>/root` 清理整个容器进程树，避免失败启动泄漏 PID/netns；
- `04` 用目录锁串行化，autorun 与手动执行不会并发创建 veth；
- veth 用 toybox `ip link add name ... peer name ...`，并校验 peer 存在；
- 等 PID namespace init 真正出现后再写 `container.pid`；
- 容器 init 完成后把 `/dev/rtc0` / `/dev/rtc` 覆盖成 `/dev/null`；
- 5G PDN 抖动时 `04` 重试 30 秒；autorun 等待 180 秒；
- 找 5G 接口用 `ip -4 route show table all`，不依赖 Wi-Fi 可能占据的系统默认路由。

> 时钟细节见 [`TIME_NOTES.md`](TIME_NOTES.md)。

### 6.5 开机自启

唯一入口：

```text
/data/adb/service.d/00_openwrt.sh
```

内容只有一行：

```sh
#!/system/bin/sh
exec sh /data/openwrt/scripts/service_openwrt_autorun.sh
```

自启脚本会：

1. 先启动电源守护（cpu7 离线、50–60% 停充）；
2. 等 `sys.boot_completed=1`；
3. 等 5G 默认路由（最多 120 秒）；
4. 等 USB 网卡 `eth0`（最多 60 秒）；
5. 容器没跑就执行 `04`；
6. 每 30 秒看门狗：
   - 重新确保 `ip_forward` / IPv6 forwarding；
   - 重新确保 table 100、rule 90/100/101；
   - 容器挂了自动重启；
   - 电源守护挂了自动拉起。

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
adb shell su -c "iptables -t nat -S POSTROUTING | grep 10.200.1"
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

更完整的测试记录见 **[`TEST_REPORT.md`](TEST_REPORT.md)**。

---

## 9. 回滚

详见 **[`RECOVERY_AND_ROLLBACK.md`](RECOVERY_AND_ROLLBACK.md)**。最快路径：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb flash boot_a magisk_patch\magisk_patched_boot_v30.7.img
& $fb reboot
```

这只回滚内核，不动数据分区。OpenWrt 容器故障通常不需要刷机，删掉 `/data/adb/service.d/00_openwrt.sh` 或 `touch /data/openwrt/disable_autorun` 即可。

---

## 10. Android OTA 与 KABI 复验

Android OTA 会覆盖 `boot`（自定义内核丢失）和 `vbmeta_a`（AVB 重新启用）。**是否需要重编内核，取决于新固件 vendor 模块的符号 CRC。**

流程：

1. 从新固件解包 `vendor_dlkm` / `vendor_boot` 里的 `.ko`；
2. 解析每个 `.ko` 的 `__versions`，生成新的 CRC 表；
3. 与当前 `artifacts/kernel_run4/Module.symvers` 对比；
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
