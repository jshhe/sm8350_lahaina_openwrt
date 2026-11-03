# 总计划与执行记录（As-Built）

> 项目：一加 9 Pro（SM8350 / lemonadep / LE2120）→ Android + OpenWrt 5G CPE
> 状态：**主链路已完成并验证**，剩余插网卡冷启动验收与可选项。
> 最后更新：2026-11

---

## 0. 目标与非目标

### 目标

1. 保留 Android 原生图形界面、相机、音频、内部 WiFi、指纹、5G 基带；
2. 让手机同时成为一台 5G CPE：USB 网卡做 LAN，5G 做 WAN；
3. OpenWrt 提供 DHCP / DNS / RA / LuCI / SSH / 防火墙 / 代理能力；
4. 2.5G 驱动内置内核，不依赖 Magisk 模块；
5. 电池长期保持在 50–60%，Cortex-X1 离线；
6. 所有 OpenWrt 文件集中在 `/data/openwrt/`；
7. 内核可云端构建，KABI 可验证，失败可回滚。

### 非目标

- 不把整机刷成 OpenWrt；
- 不把 5G 基带直通给 OpenWrt；
- 不把内部 WiFi 直通给 OpenWrt；
- 不使用 WSL2 编译；
- 不长期保留多个 Magisk 模块入口。

---

## 1. 最终架构

```text
[Bootloader 解锁] → [AVB 关闭] → [Magisk 30.7] → [自定义 5.4.254 boot]
                                                          │
                                                   Android 正常启动
                                                          │
                                          Magisk service.d/00_openwrt.sh
                                                          │
                                      unshare -m -u -n -p -f + chroot
                                                          │
                                            OpenWrt 21.02.7 (/data/openwrt/rootfs)
                                                          │
                     ┌────────────────────────────────────┴────────────────────────────────────┐
                     │                                                                         │
          USB 2.5G/1G 网卡 (netns 直通)                                         veth-owrt 10.200.1.2/30
             容器 eth0 192.168.2.1/24                                              veth-host 10.200.1.1/30
                     │                                                                         │
               PC / 交换机                                                      Android iptables MASQUERADE
                                                                                           │
                                                                                     rmnet_dataX (5G)
```

---

## 2. 阶段执行记录

| 阶段 | 内容 | 状态 | 证据 |
| :---: | :--- | :---: | :--- |
| 1 | 验机、确认型号/固件/分区 | ✅ | `LE2120_14.0.0.1901` |
| 2 | Bootloader 解锁 | ✅ | `ro.boot.verifiedbootstate=orange` |
| 3 | Magisk 30.7 Root | ✅ | Magisk App / `su` 可用 |
| 4 | 关闭 AVB / dm-verity | ✅ | `vbmeta_a` flags `0x3`，见 `AVB_DISABLED.md` |
| 5 | 117 分区全量备份 | ✅ | 14.29 GiB + SHA256，`full_backup_*` |
| 6 | 合并恢复集 | ✅ | `backup_merged_*`，60 官方 + 57 phone-only |
| 7 | 内核源码/工具链/工作流 | ✅ | `.github/workflows/build_kernel.yml` |
| 8 | 自定义内核编译 | ✅ | run4 build `40346641157` |
| 9 | KABI 1,607 符号校验 | ✅ | 100% 匹配 |
| 10 | 刷入自定义 boot | ✅ | `new-boot-custom-v3.img` |
| 11 | Android 功能回归 | ✅ | 显示/音频/相机/WiFi/指纹/5G |
| 12 | 指纹修复 / 弹窗定位 | ✅ | `fps_hal=running`，一次性提示 |
| 13 | 2.5G 内置驱动 | ✅ | `r8152 v2.22.1`，模块已移除 |
| 14 | PID namespace 验证 | ✅ | 容器内 PID=1 |
| 15 | OpenWrt rootfs 部署 | ✅ | 21.02.7 armvirt/64 |
| 16 | 容器服务 | ✅ | procd/ubusd/uhttpd/dropbear/dnsmasq/odhcpd |
| 17 | USB 网卡 netns 直通 | ✅ | 容器 `eth0 192.168.2.1/24` |
| 18 | IPv4 NAT / 策略路由 | ✅ | PC DHCP、5G 出口 |
| 19 | 原生 IPv6 `/64` | ✅ | PC 可 ping 容器与外网 |
| 20 | LuCI 中文 | ✅ | `lang="zh-cn"`，标题“概览” |
| 21 | 电源/充电守护 | ✅ | cpu7=0，60% 停充 |
| 22 | 开机自启 / 看门狗 | ⚠️ | WAN-only 已验证；插网卡冷启动待验收 |
| 23 | 目录统一 `/data/openwrt` | ✅ | 唯一入口 `service.d/00_openwrt.sh` |
| 24 | 仓库审计 / 历史压缩 | ✅ | 无密钥/序列号，GPL-2.0 + NOTICE |
| 25 | 容器时钟/RTC 隔离 | ✅ | 禁用 sysfixtime/sysntpd，RTC 覆盖为 null |
| 26 | 容器泄漏清理 / 04 加锁 | ✅ | 2002 进程/196 netns → 1 容器 |

---

## 3. 关键决策记录

### D1：容器，而不是 VM / 整机固件

- 5G 基带依赖 Android RIL/QMI 与厂商 modem 固件；
- 保留 Android 才能继续用相机/显示/音频/WiFi/指纹；
- 容器共享内核，开销低；
- `PID_NS` 让 `procd` 安全当 PID 1。

### D2：最小 KABI 变更，而不是“功能全开”

- 99 个原厂 `.ko`、1,607 个符号 CRC 是硬约束；
- 只开 `PID_NS`、`DEVTMPFS`、`MACVLAN`、`IP6_NF_NAT`、`r8152` 等；
- 不开 `NF_TABLES` / `BRIDGE_NETFILTER` / `VLAN_8021Q` / `SYSVIPC` / `USER_NS`；
- 显式 `RELR=n`；
- 构建时 KABI 不匹配直接失败。

### D3：OpenWrt 21.02，而不是 23.05 / 24.10

- 内核 `NF_TABLES=n`；
- 22.03+ 默认 `fw4` + nftables，起不来；
- 21.02 是最后一个默认 `fw3` + iptables 的版本；
- 23.05 可以禁用 `fw4` 跑用户态，但属于可选实验；
- 24.10 改用 `apk`，脚本还要改。

### D4：5G 不直通，宿主做 WAN

- OpenWrt 没有 Android RIL/QMI 拨号栈；
- 直通 `rmnet_dataX` 也不能拨号；
- 正确模型：Android 负责数据连接，容器通过 veth + 宿主 NAT/策略路由出网。

### D5：内部 WiFi 不直通

- `qcacld-3.0` / `cnss2` 闭源厂商栈；
- AP 模式依赖厂商 `hostapd`、BDF、`cnss-daemon`；
- 移走 `wlan0/wlan2` 会打断 Android WiFi/热点，容器里也起不了 AP；
- 若需要 OpenWrt WiFi，用 USB WiFi 网卡 + 内核内置 upstream 驱动。

### D6：USB 网卡 netns 直通

- 容器拿到真实 LAN 口；
- 避免宿主在 LAN 侧再做一层 bridge/NAT；
- 容器内统一改名 `eth0`，配置简单。

### D7：单根目录 `/data/openwrt`

```text
/data/openwrt/{rootfs,scripts,packages,images,run,logs}
```

- 所有 OpenWrt 包、配置、脚本、镜像、状态、日志只放这里；
- Magisk 只保留 `service.d/00_openwrt.sh` 一个入口；
- 不再使用 `/data/adb/openwrt`、`/sdcard`、`/data/local/tmp` 存放运行文件。

### D8：原生 IPv6，而不是 NAT66

- 运营商 `/64` 同前缀共享；
- 宿主转发 + table 200/201 策略路由；
- 容器 `odhcpd` 发 RA；
- 无 NAT66、无 ULA。

### D9：时钟只允许 Android 管理

- 容器与 Android 共享内核和 `/dev`；
- OpenWrt 的 `sysfixtime` / `sysntpd` 会读写宿主 RTC，而本机 RTC 停在 1970；
- 因此容器内禁用所有 RTC/NTP 时间处理，并在 init 后把 `/dev/rtc0` 覆盖为 `/dev/null`；
- Android `auto_time=1` + `ntp_server=ntp.aliyun.com` 负责校时；
- 详见 [`TIME_NOTES.md`](TIME_NOTES.md)。

---

## 4. 硬件与外设

| 设备 | 要求 | 当前状态 |
| :--- | :--- | :--- |
| 手机 | 一加 9 Pro LE2120，OOS 14 | ✅ |
| USB-C 扩展坞 | PD 供电 + USB 3.0 | 用户自备 |
| USB 2.5G 网卡 | RTL8156B / RTL8156BG | 已验证 |
| 充电头 | 30–65W PD | 用户自备 |
| 散热 | 可选 | 建议长期运行加 |

> 避免使用非标准 VOOC/WARP 直充头；用通用 PD 让扩展坞握手。

---

## 5. 工具箱（实际文件）

| 文件 | 用途 |
| :--- | :--- |
| `scripts/01_backup_partitions.sh` | 备份 boot/vendor_boot/dtbo/modem 等关键分区 |
| `scripts/01b_full_backup_all_partitions.sh` | 117 分区全量备份 |
| `scripts/02_patch_kernel_config.py` | 内核配置合入 |
| `scripts/03_setup_openwrt_rootfs.sh` | 解压/适配 rootfs |
| `scripts/04_start_openwrt_and_network.sh` | 启动容器、netns 直通、veth、NAT、IPv6 |
| `scripts/05b_cpu_charge_guard.sh` | cpu7 离线、限频、50–60% 停充 |
| `scripts/05_headless_power_control.sh` | 可选无头化节能 |
| `scripts/06_android_functional_test.sh` | Android 功能/命名空间测试 |
| `scripts/06_restore_gui.sh` | 恢复图形界面 |
| `scripts/verify_kabi_crc.py` | 1,607 符号 CRC 闸门 |
| `service_openwrt_autorun.sh` | 开机自启 + 看门狗 |
| `service_power_guard.sh` | 电源守护拉起/防重复 |

---

## 6. 验收标准

### 必须通过

- [x] `uname -r` = `5.4.254-qgki-gd2a1055adeb0`
- [x] KABI 1,607/1,607
- [x] 99 个原厂模块全部加载
- [x] 指纹 / 显示 / 音频 / 相机 / WiFi / 5G 正常
- [x] `unshare -p -f` 内 PID=1
- [x] 容器 `procd` / `dnsmasq` / `dropbear` / `odhcpd` 运行
- [x] PC 通过 USB 网卡获得 `192.168.2.x`
- [x] LuCI 中文可访问
- [x] IPv4 出口正常
- [x] IPv6 原生 `/64` 正常
- [x] cpu7 离线，60% 停充

### 待通过

- [ ] 拔 USB 数据线、插 2.5G 网卡、重启手机，全自动恢复 LAN + WAN
- [ ] 连续运行 24–72 小时无断流/内存泄漏
- [ ] 5G 重拨后 IPv6 前缀自动刷新（当前需重跑 `04`）

---

## 7. 剩余工作

| 优先级 | 事项 | 说明 |
| :---: | :--- | :--- |
| P0 | 插网卡冷启动验收 | 当前最大未验证项 |
| P1 | 5G 重拨 / 网卡热插拔自动化 | 目前靠 30 秒看门狗与人工重跑 |
| P2 | 23.05.5 + 禁用 fw4 旁路测试 | 不重编内核 |
| P3 | AG / Clash 部署 | 仅服务 USB LAN |
| P4 | USB WiFi 网卡 + 内置驱动 | 需要重编内核 |
| P5 | Android OTA KABI 复验自动化 | 先对比 CRC 再决定是否重编 |

---

## 8. 相关文档

- [`README.md`](README.md)：项目总览与架构
- [`README_BUILD.md`](README_BUILD.md)：构建/刷机/部署/排错
- [`TEST_REPORT.md`](TEST_REPORT.md)：测试与实验记录
- [`IPV6_NOTES.md`](IPV6_NOTES.md)：IPv6 设计与实测
- [`TIME_NOTES.md`](TIME_NOTES.md)：容器时钟/RTC 事故与修复
- [`RECOVERY_AND_ROLLBACK.md`](RECOVERY_AND_ROLLBACK.md)：备份与回滚
- [`AVB_DISABLED.md`](AVB_DISABLED.md)：AVB 关闭记录
