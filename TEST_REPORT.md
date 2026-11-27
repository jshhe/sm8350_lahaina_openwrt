# 测试与实验报告

> 设备：OnePlus 9 Pro / `lemonadep` / LE2120（国行）
> 系统：OOS 14 `LE2120_14.0.0.1901`
> 内核：`5.4.254-qgki-gd2a1055adeb0`（自定义，GitHub Actions build `40346641157` / run4）
> OpenWrt：21.02.7 `armvirt/64`
> 最后一次上机：2026-11-27
> 结论：**主链路与千兆 USB 网卡（RTL8153）免手操冷启动验收已通过**；2.5G 网卡冷启动复验、24–72 小时耐力测试、含 `fix_oplus_warp_probe.patch` 新内核上机验证以及 23.05 用户态 / AG / Clash 属于待验收/可选项。

---

## 1. 测试矩阵

| 类别 | 项目 | 结果 |
| :--- | :--- | :---: |
| Boot | Bootloader 解锁 / AVB 关闭 / Magisk 30.7 | ✅ |
| Boot | 自定义内核开机 | ✅ |
| Kernel | KABI 1,607 符号 CRC | ✅ |
| Kernel | `RELR=n` / `PID_NS=y` / 指纹驱动 | ✅ |
| Kernel | 内置 `r8152 v2.22.1` | ✅ |
| Android | 显示 / 触控 / 音频 / 相机 / WiFi | ✅ |
| Android | 指纹 / TEE | ✅ |
| Android | 5G 数据 | ✅ |
| Android | 开机完整性弹窗 | ✅（一次性，已定位） |
| Power | cpu7 离线 / 限频 | ✅ |
| Power | 50–60% 停充 | ✅ |
| Namespace | `PID_NS` 内 PID=1 | ✅ |
| Container | `procd` / `ubusd` / `uhttpd` / `dropbear` | ✅ |
| Container | `dnsmasq` / `odhcpd` | ✅ |
| Network | LAN DHCP / NAT / 5G 出口 | ✅ |
| Network | 宿主访问容器 LuCI | ✅ |
| IPv6 | 原生 `/64` / RA / `table 200 via fe80::2` / 外网 | ✅ |
| Firewall | 容器 `fw3`（`Allow-Host-UI` + `MASQUERADE`）自愈 | ✅ |
| LuCI | 中文界面（PC `192.168.2.1` + 手机 `10.200.1.2`） | ✅ |
| Autostart | Magisk `ASH_STANDALONE` 隔离 + 单容器防泄漏 | ✅ |
| Autostart | WAN-only 自启 / 看门狗 | ✅ |
| USB Host | 带电扩展坞供电重插 30–60s 自愈 + 边充边用 | ✅ |
| Clock | 容器不再改写 Android 时钟 | ✅ |
| Clock | 重启后 NTP 自动校正 | ✅ |
| Cleanup | 泄漏实例/进程树清理 | ✅ |
| Autostart | 插千兆网卡（RTL8153）免手操冷启动 | ✅（2026-11-27） |
| Autostart | 插 2.5G 网卡（RTL8156B/BG）冷启动复验 | ⏳ 待验收 |
| Endurance | 连续运行 24–72 小时稳定性 | ⏳ 待验收 |

---

## 2. 内核构建实验

### 2.1 构建迭代

| 构建 | 产物 | 说明 |
| :--- | :--- | :--- |
| run2 | `artifacts/kernel_run2/` | 早期打通编译链路，保留作对照 |
| run3 | `artifacts/kernel_run3/` | 加入 `Module.symvers`，继续修配置 |
| run4 | `artifacts/kernel_run4/`（已归档移除） | 首个全功能版：KABI 100%，指纹/2.5G/PID_NS 就绪 |
| **run6** | `artifacts/kernel_run6/` | **当前在网版本**：在 run4 基础上合入 `fix_oplus_warp_probe.patch`（0-KABI），实测 `disable_warp_probe=Y` 零 `switch1_gpio:1`、USB 3.0 5000 Mbps 与 `sink` 供电共存、5s 看门狗 + 原地热挂 11s 恢复 |

run6 关键数据：

```text
build:        45950059781
uname -v:     #1 SMP PREEMPT Fri Nov 27 06:15:42 UTC 2026
Image:        48,421,376 bytes
SHA256:       aa9bcca8f875851778b371b28ed4bac5f0f1ce94f0cee0ef201f33c3f97a8575
boot image:   new-boot-custom-v4-magisk31.1.img (201,326,592 bytes)
boot SHA256:  eadf3cf37bde2ea5402756eef01d68290be809d0d84bfd480a88fd22ed1b73d7
```
```

### 2.2 KABI 校验

方法：

1. 从手机 `vendor_dlkm` / `vendor_boot` 收集 99 个原厂 `.ko`；
2. 解析每个 `.ko` 的 `__versions` 段，得到它需要的符号与 CRC；
3. 去掉模块之间互相导出的符号，只保留必须由 `vmlinux` 提供的符号；
4. 生成 `configs/phone_kabi_crc.json`，共 **1,607** 个符号；
5. 构建后读取 `Module.symvers`，逐个比对。

结果：

```text
KABI check: vmlinux exports=..., required by phone modules=1607
  matched   : 1607/1607
  missing   : 0
  mismatched: 0
SUCCESS: 100% KABI CRC match with all 99 stock phone modules!
```

意义：`msm_drm`、`wlan`、`camera`、音频、指纹等预编译模块可以继续加载，不需要重新编译整个 vendor 树。

### 2.3 关键配置验证

```text
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_MACVLAN=y
CONFIG_IP6_NF_NAT=y
CONFIG_USB_RTL8152=y
CONFIG_OPLUS_FINGERPRINT=y
# CONFIG_NF_TABLES is not set
# CONFIG_BRIDGE_NETFILTER is not set
# CONFIG_VLAN_8021Q is not set
# CONFIG_SYSVIPC is not set
# CONFIG_USER_NS is not set
# CONFIG_RELR is not set
CONFIG_LOCALVERSION="-qgki-gd2a1055adeb0"
```

构建工作流在编译前强制检查关键项，`RELR=y` 会直接失败。

### 2.4 内核刷入

- 当前 `boot_a`：`new-boot-custom-v3.img`；
- `uname -r`：`5.4.254-qgki-gd2a1055adeb0`；
- 回滚基准：`magisk_patch/magisk_patched_boot_v30.7.img`（原厂内核 + Magisk 30.7）。

### 2.5 原厂模块与驱动

| 项目 | 结果 |
| :--- | :--- |
| 99 个原厂 `.ko` 的符号需求 | ✅ 1,607/1,607 匹配，无 missing/mismatch |
| `msm_drm` | ✅ 显示正常 |
| `wlan` / `qcacld` | ✅ 内部 WiFi 正常 |
| `camera` | ✅ 相机正常 |
| 音频 | ✅ 正常 |
| 指纹 | ✅ 见 3.2 |
| r8152 | ✅ 内置，`rtl8152_get_version` 在 kallsyms |

---

## 3. Android 功能回归

### 3.1 基础功能

| 项目 | 验证方式 | 结果 |
| :--- | :--- | :---: |
| 开机 | 正常进入系统 | ✅ |
| 显示 | 1440×3216 120Hz | ✅ |
| 触控 | 正常操作 | ✅ |
| 音频 | 播放/录音 | ✅ |
| 相机 | 前后摄 | ✅ |
| 内部 WiFi | 连接/热点 | ✅ |
| 5G | `rmnet_dataX` 获取 IPv4，容器 ping 外网 | ✅ |
| USB 2.5G | `dmesg` / `ip -br link` | ✅ |

### 3.2 指纹修复

早期自定义内核缺 OPlus 指纹驱动，导致：

- `fps_hal` 反复崩溃；
- `/dev/goodix_fp` 不存在；
- Android 弹出“系统/设备内部出现问题”。

修复：

```text
CONFIG_OPLUS_FINGERPRINT=y
CONFIG_OPLUS_FINGERPRINT_COMMON=y
CONFIG_OPLUS_FINGERPRINT_QCOM=y
CONFIG_OPLUS_FINGERPRINT_GOODIX_OPTICAL=y
CONFIG_OPLUS_FINGERPRINT_JIIOV_OPTICAL=y
CONFIG_OPLUS_FINGERPRINT_SILEAD=y
```

验证：

```text
fps_hal=running
/dev/goodix_fp 存在
TEE goodixfp 已加载
HAL deaths since last reboot: 0
```

### 3.3 开机弹窗定位

现象：第一次开机弹出“Android 系统/设备内部出现问题”。

排查：

- `sys.init.updatable_crashing` 为空；
- `dropbox` 无 crash / tombstone；
- 指纹 HAL 无死亡；
- 弹窗只出现一次，点掉后不再出现。

结论：属于自定义内核触发的**一次性内核完整性提示**，不影响功能，不是持续崩溃。

---

## 4. 电源与充电守护

脚本：`scripts/05b_cpu_charge_guard.sh`

| 项目 | 目标 | 实测 |
| :--- | :--- | :--- |
| Cortex-X1 / cpu7 | 离线 | `cpu7=0` |
| A55 最高频 | ≤ 1.32 GHz | `1324800` |
| A78 最高频 | ≤ 1.44 GHz | `1440000` |
| 停充阈值 | ≥ 60% | `soc=60 stop charging` |
| 恢复阈值 | ≤ 50% | 逻辑已实现 |
| 充电状态 | `mmi_charging_enable=0` | ✅ |

日志：`/data/openwrt/logs/power_guard.log`

PID 复用问题：

- 旧实现只看 `kill -0 $pid`，重启后 PID 被别的进程复用，守护会误判“已在运行”；
- 现在校验 `/proc/<pid>/cmdline` 必须包含 `05b_cpu_charge_guard`；
- 迁移目录时还遇到旧守护仍以已删除的 `/data/adb/openwrt/...` 路径运行，已杀掉并清理 pid。

---

## 5. 命名空间与容器

### 5.1 PID namespace

```bash
/data/adb/magisk/busybox unshare -p -f sh -c 'echo pid=$$'
# pid=1
```

容器内 `procd` 是 PID 1，Android 的 `zygote` / `system_server` 不受影响。

### 5.2 容器启动

```text
unshare -m -u -n -p -f
chroot /data/openwrt/rootfs /sbin/init
```

- mount / UTS / net / PID namespace；
- 没有 IPC namespace（`SYSVIPC=n`，`unshare -i` 不可用）；
- 没有 user namespace；
- `/proc` 在容器内重新挂载；
- `/dev`、`/dev/pts`、`/sys` bind-mount。

### 5.3 OpenWrt 服务

| 服务 | 状态 |
| :--- | :---: |
| `procd` | ✅ |
| `ubusd` | ✅ |
| `netifd` | ✅ |
| `uhttpd` | ✅ |
| `dropbear` | ✅ |
| `dnsmasq` | ✅ |
| `odhcpd` | ✅ |

---

## 6. 网络测试

### 6.1 IPv4

拓扑：

```text
PC 192.168.2.227
   │
USB 2.5G 网卡（netns 直通）
   │
容器 eth0 192.168.2.1/24
   │
veth-owrt 10.200.1.2/30
   │
veth-host 10.200.1.1/30
   │
Android iptables MASQUERADE
   │
rmnet_dataX（5G）
```

结果：

- PC 通过 DHCP 获得 `192.168.2.227`；
- PC 可访问 `http://192.168.2.1/`；
- 容器内 `ping 223.5.5.5` 0% 丢包；
- 宿主 `wget http://10.200.1.2/` 返回 200；
- SSH `root@192.168.2.1` 免密可进。

关键路由：

```text
table 100:
  default via <5G网关> dev rmnet_dataX
  10.200.1.0/30 dev veth-host

ip rule:
  90:  to 10.200.1.0/30 lookup main
  100: from 10.200.1.0/30 lookup 100
  101: iif rmnet_dataX to 10.200.1.0/30 lookup main
```

### 6.2 IPv6

- 从 `rmnet_dataX` 读取运营商全局 `/64`；
- 容器 `eth0` 配 `::1/64`；
- `veth-host` / `veth-owrt` 使用 `fe80::1` / `fe80::2`；
- 宿主 table 200（`via fe80::2 dev veth-host onlink`）/ table 201 + rule 1000/1001；
- 容器 `odhcpd` 发 RA；
- PC（`以太网 3`，RTL8153 1 Gbps）自动获得同 `/64` 地址；
- PC 可 ping 容器 `::1`，也可 ping `2400:3200::1`（热修验证 34–53 ms、冷启动验收 44–48 ms，0% 丢包）；
- **没有 NAT66，没有 ULA**。

详见 [`IPV6_NOTES.md`](IPV6_NOTES.md)。

### 6.3 实测故障与修复

| # | 现象 | 根因 | 修复 |
| :---: | :--- | :--- | :--- |
| 1 | 容器启动后 rootfs 被搬空 | `mktemp -d` 无模板，dropbear init 把 `/*` 移到 `/etc/dropbear` | 强制模板 + `mv` 保护 |
| 2 | dnsmasq 无实例 | `dhcp` 配置缺 `config dnsmasq` | 补全全局段 |
| 3 | IPv6 地址被刷掉 | `network reload` 异步 flush | 延迟添加 + `sleep 2` |
| 4 | `ip addr replace` 不支持 | toybox `ip` 限制 | 改用 `add` |
| 5 | 重启容器找不到 eth0 | 旧容器仍持有 netns | 停旧容器后重新探测 |
| 6 | 断网/重连后转发失效 | Android netd 重置 sysctl/规则 | 看门狗每 30 秒重断言 |
| 7 | 宿主能 ping 容器但 TCP 超时 | table 100 缺 veth 直连路由 | 显式添加 `10.200.1.0/30 dev veth-host` |
| 8 | 宿主访问 10.200.1.2 走 5G | 源地址规则匹配不到宿主自身流量 | 增加 `to 10.200.1.0/30 lookup main pref 90` |
| 9 | 手机浏览器 LuCI 被拒 | uhttpd RFC1918 过滤 | `rfc1918_filter=0` + 仅允许宿主的防火墙规则 |
| 10 | LuCI 中文装不上 | opkg 索引架构文件名不匹配 | 手工安装 `luci-base` + 中文包 |
| 11 | 电源守护不启动 | PID 复用误判 | 校验 cmdline |
| 12 | 迁移后新守护不启动 | 旧进程占用 pid 文件 | 杀旧进程 + 清 pid |
| 13 | 守护挂了没人拉 | 看门狗只检查容器 | 每 30 秒调用守护 |
| 14 | Magisk `service.d` 下 `veth-owrt` 失败且每 30s 泄漏容器 | Magisk 在 BusyBox ash `ASH_STANDALONE=1` 模式运行（忽略 `PATH`），BusyBox `ip`/`ps` 缺失所需能力 | `00_openwrt.sh`/`autorun`/`04` 三层 `unset ASH_STANDALONE` + `exec /system/bin/sh` + 严格 `pgrep -P` |
| 15 | PC 原生 IPv6 ping 外网 100% 丢包 | 宿主 `table 200` 缺下一跳（`dev veth-host`），Android 在 `veth-host` 上对 LAN 客户端发 NDP 解析失败 | 改为 `via fe80::2 dev veth-host onlink table 200`，PC ping `2400:3200::1` 恢复 34–53 ms、0% 丢包 |
| 16 | 冷启动后容器 `fw3` 规则不完整 | `04` 与 `procd`/`S19firewall` 及异步 `netifd reload` 竞态 | 将 `/etc/init.d/firewall restart` 移到 `04` 末尾校验重试，看门狗新增 `ensure_container_fw()` 自愈 |
| 17 | 带电扩展坞重插后 `eth0` 掉线、`error -71` | 非 PD 5V 坞 VBUS 触发 `oplus_otg_disable_work`（`mode=none`），充电时 OPLUS WARP 探测切 `switch1_gpio:1` 抢占 D+/D- | 用户态新增 `ensure_usb_host_mode()`（保护 `mode=peripheral`）+ 热挂看门狗；内核新增 0-KABI 补丁 `fix_oplus_warp_probe.patch` |

---

## 7. LuCI 中文

- 安装 `luci-i18n-base-zh-cn`、`luci-i18n-firewall-zh-cn`；
- `luci.main.lang=zh-cn`；
- 手工执行 CGI 确认：

```html
<html lang="zh-cn">
<title>OpenWrt - 概览 - LuCI</title>
```

- `uhttpd` 返回 403 登录页是正常的（未登录）；
- BusyBox `wget` 把 403 当错误、不输出 body，所以命令行看起来“空”，浏览器正常。

---

## 8. 自启动与看门狗

入口：

```text
/data/adb/service.d/00_openwrt.sh
  ├── unset ASH_STANDALONE
  └── exec /system/bin/sh /data/openwrt/scripts/service_openwrt_autorun.sh
```

已验证（WAN-only + 2026-11-27 千兆 RTL8153 冷启动与供电重插自愈）：

- 脚本先清除 `ASH_STANDALONE` 并切换到 Android `/system/bin/sh`，等待 `sys.boot_completed=1` 与 5G 活跃路由（最多 180 秒）；
- 调用 `ensure_usb_host_mode()`（严守 `mode=peripheral` 不碰 PC USB）并等待 USB 网卡（最多 30 秒）；
- 容器未运行时以 `/system/bin/sh` 执行 `04`，`eth0` 未出现时先以 WAN-only 启动；
- 每 30 秒看门狗：`ensure_wan()` 重断言转发/路由/宿主 `iptables`；拉起电源守护；容器异常时重启；容器为 WAN-only 且检测到 `eth0` 热插拔/重插恢复时自动重跑 `04` 挂载；LAN 在位时通过 `ensure_container_fw()` 自愈 `fw3` 的 `Allow-Host-UI` 与 `MASQUERADE`。

待复验：

- 2.5G USB 网卡（RTL8156B/BG）的同流程免手操冷启动复验（本次冷启动验收使用千兆 RTL8153 `0bda:8153`）；
- 24–72 小时连续运行稳定性。

---

### 8.1 时钟 / RTC 事故（2026-11-03）

现象：手动同步好 Android 时间后，几十秒内又跳回 1970。

根因链：

1. 容器把宿主 `/dev` 绑进 rootfs；
2. OpenWrt `sysfixtime` 开机执行 `hwclock -s -u -f /dev/rtc0`；
3. 手机 RTC 停在 1970（`since_epoch` 约 77 万秒）；
4. 容器因 veth/PID 清理 bug 每 30 秒失败重启，于是反复覆盖；
5. 容器 `stop()` 又 `hwclock -w` 把错误时间写回 RTC，形成闭环；
6. Android `AUTO_TIME=0`，且 NTP 默认 18 小时才刷新一次。

修复：

- `03` 删除 `sysfixtime` / `sysntpd` rc 链接，替换 `sysfixtime` 为 no-op，注释 `hwclock --systz`，关闭容器 NTP；
- `04` 在 init 完成后把 `/dev/rtc0` / `/dev/rtc` 覆盖为 `/dev/null`；
- `04` 清理整个容器进程树、加锁、修正 veth 创建、等 PID namespace init；
- autorun 用 `ip -4 route show table all` 找 5G，等待 180 秒；
- Android `auto_time=1`，`ntp_server=ntp.aliyun.com`，NTP force refresh。

清理结果：

| 指标 | 清理前 | 清理后 |
| :--- | ---: | ---: |
| rootfs 进程 | 2002 | 10（1 个容器） |
| 独立 netns | 196 | 1 |
| `procd` | 194 | 1 |
| `ntpd` | 193 | 0 |

验证：

- 容器启动/重启前后宿主时间不变；
- 容器 `date +%s` 与宿主 epoch 一致；
- 重启 Android 后时间保持正确；
- 看门狗杀容器后 30 秒内自动重启，`04 exit=0`；
- 容器内 `/dev/rtc0` 显示为 `/dev/null`（major 1,3）。

RTC 写入：

```text
hwclock: ioctl RTC_SET_TIME: Permission denied
```

即使 `setenforce 0` 也一样，说明是内核/固件限制；RTC 仍为 1970。Android 依赖 NTP 校正，容器不再接触 RTC。详见 [`TIME_NOTES.md`](TIME_NOTES.md)。

---

### 8.2 2026-11-27 故障排查、供电重插自愈与免手操冷启动验收

#### 8.2.1 Magisk `ASH_STANDALONE=1` 根因与三层修复

现象：开机后自启日志持续报 `ERROR: veth peer veth-owrt was not created`、`04 exit=1`，每 30 秒重试并不断泄漏容器实例（实测启动 6 分钟内已累积 7 个容器实例，且每次都误拾取旧容器 PID）。

根因：Magisk 以 BusyBox `ash` 独立模式（`ASH_STANDALONE=1`）执行 `service.d` 脚本，此时任何不含 `/` 的命令（`ip`、`ps`、`sh`、`awk`、`readlink`）都会被强制解析为 BusyBox applet，完全忽略脚本内设置的 `PATH`：

1. BusyBox `ip` 无法创建带命名 peer 的 veth 对（`veth-owrt` 静默缺失）；
2. BusyBox `ps` 不支持 `-A -o`，导致 `kill_container_tree()` 清理与容器 init PID 探测全部失效。

修复：

- 三层清除 `ASH_STANDALONE` 并重执 `/system/bin/sh`：`/data/adb/service.d/00_openwrt.sh`、`service_openwrt_autorun.sh`、`scripts/04_start_openwrt_and_network.sh`（同时 `service_openwrt_autorun.sh` 与 `service_power_guard.sh` 显式调用 `/system/bin/sh`）；
- `04` 改用严格 `pgrep -P "$UNSHARE_PID"`（回退 `ps -A -o PID,PPID`）定位新容器 init PID，绝不回退匹配任意 rootfs 进程，并在清理残留 `procd` 时补全 rootfs 回退查杀。

验证：重启后 `service_openwrt_autorun.sh` 实测 `exe=/system/bin/sh ASH=unset`，系统内仅保留 **1 个 `procd`**，0 泄漏。

#### 8.2.2 原生 IPv6 `table 200` 下一跳修复

现象：PC 获取到了运营商 `/64` 地址，但 `ping -6 2400:3200::1` 100% 丢包。

根因：`04` 原先在宿主 `table 200` 写入 `<prefix>::/64 dev veth-host`（无下一跳），导致 Android 收到 5G 回程包时在 `veth-host` 上对 LAN 客户端发 NDP 邻居解析并失败。

修复：`scripts/04_start_openwrt_and_network.sh` 将 `table 200` 改为 `ip -6 route replace "$V6_NET" via fe80::2 dev "$VETH_HOST" onlink table 200`。

验证：PC（`以太网 3`，RTL8153 1 Gbps）立即 ping 通 `2400:3200::1`，实测延迟 **34–53 ms、0% 丢包**。

#### 8.2.3 容器 `fw3` 启动竞态与看门狗自愈

现象：容器刚启动时偶发 `zone_wan_input`（`Allow-Host-UI`）或 `zone_wan_postrouting`（`MASQUERADE`）规则缺失。

修复：将 `/etc/init.d/firewall restart` 移至 `04` 末尾（`netifd` 与 IPv6 全部稳定之后）并做一次校验重试；在 `service_openwrt_autorun.sh` 的 30 秒看门狗中新增 `ensure_container_fw()`，缺失时自动重启防火墙自愈。

验证：冷启动日志中 `04` 首次报 `WARN: container fw3 rules incomplete after firewall restart`，随后看门狗自动完成自愈，容器内 `-A zone_wan_postrouting -m comment --comment "!fw3" -j MASQUERADE` 与 `Allow-Host-UI` 均正常生效。

#### 8.2.4 带电扩展坞（非 PD 5V）定位、供电重插自愈与 0-KABI 内核补丁

实测一款非 PD 5V 带电 Type-C 扩展坞（`power_operation_mode=default`，被 OPLUS 充电子系统识别为 `[BrickID]` / `USB_DCP`），观察到两类问题：

1. **冷重启角色**：非 PD 坞不会在手机重启后发起 USB-PD `PR_SWAP`，重启后停留在 `power_role=[source]`（手机给坞供电、`Not charging`），需插拔一次供电才切回 `power_role=[sink]` 充电；
2. **重插供电与 WARP 探测干扰**（`dmesg` 实证）：
   - 接入外部 5V VBUS 触发 `oplus_otg_disable_work`，关闭 `otg_switch` 并注销 xHCI 总线（`r8152` `status -108` 断开，`a600000.ssusb` 跌回 `mode=none`）；
   - 恢复 `mode=host` 后，只要充电处于开启状态（`mmi_charging_enable=1`），`oplus_chg_fast_switch_check()` 看到 `POWER_SUPPLY_TYPE_USB_DCP` 便反复翻转硬件 D+/D- 开关 `switch1_gpio:1`（`warp mode`）并触发 `smbchg_usb_suspend_enable`（`reset adapter`），劫持 USB D+/D- 导致 `usb 2-1: device descriptor read/64, error -71`。

用户态修复与实测：

- 在 `service_openwrt_autorun.sh` 与 `scripts/04_start_openwrt_and_network.sh` 中新增 `ensure_usb_host_mode()`（严守 `mode=peripheral` 护栏，绝不触碰 PC USB 数据线；仅在 `mode=none` 或 `mode=host` 且无 xHCI 设备、`otg_online != 0` 且 `data_role=[host]` 时暂关 `mmi_charging_enable` 并恢复 Host 枚举），并在 30 秒看门狗中加入 WAN-only 自动热挂逻辑；
- **供电重插自愈实测通过**：带电重插后 ~30–60 秒自动恢复 USB Host、`eth0` 与容器路由，并实测 **边充边用**（充电电流 `cur=-211 mA`，电量 `58% -> 59%`）期间 `eth0` 持续 `UP`。

内核侧根治（0-KABI 补丁）：

- 新增 `fix_oplus_warp_probe.patch`（已集成至 `.github/workflows/build_kernel.yml`）：在 `drivers/power/oplus_chg/oplus_charger.c` 的 `oplus_chg_fast_switch_check()`（`chip->mmi_chg == 0` 检查之后）加入模块参数 `/sys/module/oplus_chg/parameters/disable_warp_probe`（默认 `1`），直接返回并打印 `disable_warp_probe,return`，彻底停止 `switch1_gpio:1` WARP 探测，同时保留正常 5V / USB-PD 充电；
- 不修改任何结构体或导出符号（1,607 KABI CRC 保持 100% 匹配），且运行时可随时 `echo 0 > /sys/module/oplus_chg/parameters/disable_warp_probe` 恢复。

#### 8.2.5 免手操冷启动验收结果（2026-11-27，PASSED）

测试条件：拔掉 PC 调试 USB 线，接入带电 Type-C 扩展坞 + 千兆 USB 网卡（RTL8153，`0bda:8153`），执行手机冷重启，全程不人工干预。

| 验收项 | 实测结果 | 结论 |
| :--- | :--- | :---: |
| USB 枚举与驱动 | `3-1` `0bda:8153`，USB 3.0 SuperSpeed Gen 1（`speed=5000`，5 Gbps），内置 `r8152 v2.22.1` | ✅ |
| 进程与容器卫生 | `service_openwrt_autorun.sh` 运行于 `/system/bin/sh`（`ASH_STANDALONE` 已清除）；单 `procd`（0 泄漏）；`netifd`/`uhttpd`/`dnsmasq`/`odhcpd` 与 `05b_cpu_charge_guard.sh` 全在位 | ✅ |
| 容器防火墙 | `fw3` `zone_wan_postrouting`（`MASQUERADE`）+ `zone_wan_input`（`Allow-Host-UI`）自动生效 | ✅ |
| PC DHCP / IPv6 | PC（`以太网 3`，RTL8153 1 Gbps）自动获得 `192.168.2.227/24` + 运营商原生 `/64`（真实前缀已脱敏，无 NAT66/ULA） | ✅ |
| LuCI 管理页 | PC `http://192.168.2.1/` 与手机浏览器 `http://10.200.1.2/` 均可正常打开 | ✅ |
| IPv4 外网 | PC `ping 223.5.5.5`：**45–69 ms，0% 丢包** | ✅ |
| IPv6 外网 | PC `ping -6 2400:3200::1`：**44–48 ms，0% 丢包** | ✅ |
| 电源守护 | `cpu7=0`，`cap=59%`，`mmi_charging_enable=0`（Not charging） | ✅ |

---

## 9. 仓库与发布卫生

- 117 个分区全量备份 14.29 GiB，SHA256 校验通过；
- 仓库无 token / 私钥 / 设备序列号；
- 文档中的真实 IPv6 前缀、EUI-64、内网 IP、Windows 用户名已从历史清除；
- 历史压缩为单初始提交 + 后续修复提交；
- 旧 Actions runs / artifacts 已删除；
- 许可证：GPL-2.0 + NOTICE + Realtek 固件许可证；
- 仓库仍为 private，由用户自行转 public。

---

## 10. 未完成 / 可选项

1. **2.5G 网卡（RTL8156B/BG）冷启动复验与 24–72 小时耐力测试**（千兆 RTL8153 免手操冷启动已于 2026-11-27 通过）；
2. **刷入含 `fix_oplus_warp_probe.patch` 的新版内核并实测验证**（确认 `disable_warp_probe=Y` 且充电时零 `switch1_gpio:1`）；
3. 23.05.5 `armsr/armv8` rootfs + 禁用 `fw4` 的旁路测试；
4. 容器内 AdGuard Home / Clash（仅服务 USB LAN 客户端）；
5. USB WiFi 网卡 + 内核内置驱动（让 OpenWrt 自己发 WiFi）；
6. Android OTA 后的 KABI 复验流程自动化。

---

## 11. 复现命令

```bash
# 内核与 KABI / WARP 开关
adb shell uname -r
adb shell su -c "grep -c 'rtl8152' /proc/kallsyms"
adb shell su -c "/data/adb/magisk/busybox unshare -p -f sh -c 'echo pid=\$\$'"
adb shell su -c "cat /sys/module/oplus_chg/parameters/disable_warp_probe"

# 容器与防泄漏检查
adb shell su -c "cat /data/openwrt/run/container.pid"
adb shell su -c "ps -A -o PID,PPID,NAME | grep procd"
adb shell su -c "tail -20 /data/openwrt/logs/autorun.log"

# 网络与容器防火墙
adb shell su -c "ip rule; ip route show table 100; ip -6 rule; ip -6 route show table 200"
adb shell su -c "/data/adb/magisk/busybox wget -O - http://10.200.1.2/ | head"
adb shell su -c "P=\$(cat /data/openwrt/run/container.pid); /data/adb/magisk/busybox nsenter -t \$P -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; iptables -t nat -S zone_wan_postrouting; iptables -S zone_wan_input'"

# USB Host 与电源
adb shell su -c "cat /sys/devices/platform/soc/a600000.ssusb/mode /sys/class/typec/port0/data_role /sys/class/typec/port0/power_role"
adb shell su -c "cat /sys/devices/system/cpu/cpu7/online"
adb shell su -c "cat /sys/class/oplus_chg/battery/capacity"
adb shell su -c "cat /sys/class/oplus_chg/battery/mmi_charging_enable"
```
