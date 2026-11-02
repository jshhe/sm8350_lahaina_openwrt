# 测试与实验报告

> 设备：OnePlus 9 Pro / `lemonadep` / LE2120（国行）
> 系统：OOS 14 `LE2120_14.0.0.1901`
> 内核：`5.4.254-qgki-gd2a1055adeb0`（自定义，GitHub Actions build `40346641157` / run4）
> OpenWrt：21.02.7 `armvirt/64`
> 最后一次上机：2026-10-27
> 结论：**主链路可用**；插网卡冷启动、23.05 用户态、AG/Clash 属于未完成/可选项。

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
| IPv6 | 原生 `/64` / RA / 外网 | ✅ |
| LuCI | 中文界面 | ✅ |
| Autostart | WAN-only 自启 / 看门狗 | ✅ |
| Autostart | 插 2.5G 网卡冷启动 | ⏳ 待验收 |

---

## 2. 内核构建实验

### 2.1 构建迭代

| 构建 | 产物 | 说明 |
| :--- | :--- | :--- |
| run2 | `artifacts/kernel_run2/` | 早期打通编译链路，保留作对照 |
| run3 | `artifacts/kernel_run3/` | 加入 `Module.symvers`，继续修配置 |
| **run4** | `artifacts/kernel_run4/` | **最终版本**：KABI 100%，指纹/2.5G/PID_NS 全部就绪 |

run4 关键数据：

```text
build:        40346641157
uname -v:     #1 SMP PREEMPT Mon Oct 26 15:30:13 UTC 2026
Image:        48,421,376 bytes
SHA256:       732343e064af440ed32edc0c07098bcdb9fde69a12b6056a5128a141194ff09b
boot image:   new-boot-custom-v3.img (201,326,592 bytes)
boot SHA256:  3c6de08d0e90cbf02d9a2ef8598a1969742ef98a48ebe479be25206848335141
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
- 宿主 table 200/201 + rule 1000/1001；
- 容器 `odhcpd` 发 RA；
- PC 获得同 `/64` 地址；
- PC 可 ping 容器 `::1`，也可 ping `2400:3200::1`；
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
  └── exec sh /data/openwrt/scripts/service_openwrt_autorun.sh
```

已验证（WAN-only，USB 网卡未插）：

- 脚本等到 `boot_completed`；
- 等到 5G 默认路由；
- 容器未运行时执行 `04`；
- `eth0` 不存在时记录 WARN，但 WAN 仍可用；
- 每 30 秒 `ensure_wan` 重断言转发/路由；
- 守护被杀后能被看门狗拉起。

未验证：

- 拔掉 USB 数据线、插 2.5G 网卡、重启手机后，`eth0` 是否能稳定在容器启动前出现；
- 若网卡枚举较晚，`04` 首次可能以 WAN-only 启动，需要看门狗或人工重跑才能把 `eth0` 移入容器。

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

1. **插网卡冷启动验收**（最高优先级）；
2. 23.05.5 `armsr/armv8` rootfs + 禁用 `fw4` 的旁路测试；
3. 容器内 AdGuard Home / Clash（仅服务 USB LAN 客户端）；
4. USB WiFi 网卡 + 内核内置驱动（让 OpenWrt 自己发 WiFi）；
5. Android OTA 后的 KABI 复验流程自动化。

---

## 11. 复现命令

```bash
# 内核与 KABI
adb shell uname -r
adb shell su -c "grep -c 'rtl8152' /proc/kallsyms"
adb shell su -c "/data/adb/magisk/busybox unshare -p -f sh -c 'echo pid=\$\$'"

# 容器
adb shell su -c "cat /data/openwrt/run/container.pid"
adb shell su -c "tail -20 /data/openwrt/logs/autorun.log"

# 网络
adb shell su -c "ip rule; ip route show table 100; ip -6 rule"
adb shell su -c "/data/adb/magisk/busybox wget -O - http://10.200.1.2/ | head"

# 电源
adb shell su -c "cat /sys/devices/system/cpu/cpu7/online"
adb shell su -c "cat /sys/class/oplus_chg/battery/capacity"
adb shell su -c "cat /sys/class/oplus_chg/battery/mmi_charging_enable"
```
