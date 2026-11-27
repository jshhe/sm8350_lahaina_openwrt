# 总计划与执行记录（As-Built）

> 项目：一加 9 Pro（SM8350 / lemonadep / LE2120）→ Android + OpenWrt 5G CPE
> 状态：**主链路、Run #6 WARP 补丁内核、千兆 USB 网卡免手操冷启动、USB 3.0（5000 Mbps）边充边用与 5 秒看门狗原地热挂（11s 自愈）均已验收通过**；剩余 2.5G 网卡冷启动复验、24–72 小时耐力测试及可选项。
> 最后更新：2026-11-27

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
[Bootloader 解锁] → [AVB 关闭] → [Magisk 31.1] → [自定义 5.4.254 run6 boot]
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
| 3 | Magisk Root | ✅ | 初始 30.7，现已升级 `31.1:MAGISK:R` |
| 4 | 关闭 AVB / dm-verity | ✅ | `vbmeta_a` flags `0x3`，见 `AVB_DISABLED.md` |
| 5 | 117 分区全量备份 | ✅ | 14.29 GiB + SHA256（用户工作区外保管） |
| 6 | 合并恢复集 | ✅ | 60 官方 + 57 phone-only（用户工作区外保管） |
| 7 | 内核源码/工具链/工作流 | ✅ | `.github/workflows/build_kernel.yml` |
| 8 | 自定义内核编译 | ✅ | CI run6 build `45950059781`（含 `fix_oplus_warp_probe.patch`） |
| 9 | KABI 1,607 符号校验 | ✅ | 1,607/1,607 匹配；开机实载 61 个原厂模块 |
| 10 | 刷入自定义 boot | ✅ | `artifacts/kernel_run6/new-boot-custom-v4-magisk31.1.img`（SHA256 `eadf3cf3…ed1b73d7`） |
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
| 22 | 开机自启 / 看门狗 | ✅ | 5s 快速看门狗 + 30s 周期检查；千兆 RTL8153 冷启动与 11s 原地热挂通过；2.5G 待复验 |
| 23 | 目录统一 `/data/openwrt` | ✅ | 唯一入口 `service.d/00_openwrt.sh`（清 `ASH_STANDALONE`） |
| 24 | 仓库审计 / 历史压缩 / 清理 | ✅ | 无密钥/序列号，移除废旧预 CI 脚本与工作区临时旧备份 `.img`，GPL-2.0 + NOTICE |
| 25 | 容器时钟/RTC 隔离 | ✅ | 禁用 sysfixtime/sysntpd，RTC 覆盖为 null |
| 26 | 容器泄漏清理 / 04 加锁 | ✅ | 2002 进程/196 netns → 1 容器 |
| 27 | Magisk `ASH_STANDALONE` 与 `fw3` 竞态修复 | ✅ | 三层清 `ASH_STANDALONE` + `pgrep -P`；`04` 末尾重启 `fw3` + 看门狗每 30s 双模式 `ensure_container_fw` |
| 28 | 原生 IPv6 `table 200` 下一跳修复 | ✅ | `via fe80::2 dev veth-host onlink`，PC ping `2400:3200::1` 0% 丢包 |
| 29 | Run #6 WARP 0-KABI 补丁 + USB 3.0 A/B 缓存 + 原地热挂 | ✅ | `disable_warp_probe=Y` 实测 25 次拦截/0 次 `switch1_gpio:1`；`orientation` A/B 缓存锁定 USB 3.0 5000 Mbps 边充边用；`attach_lan_inplace()` 实测 11s 同 `procd` PID 恢复 |

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

### D10：隔离 Magisk `ASH_STANDALONE`、关闭 WARP 探测并实现 USB 3.0 快速原地热挂

- Magisk 默认以 BusyBox ash 独立模式（`ASH_STANDALONE=1`）运行 `service.d`，会忽略 `PATH` 并用 BusyBox `ip`/`ps` 替换 toybox，导致 `veth-owrt` 创建失败和每 30 秒泄漏容器；因此在 `00_openwrt.sh`、`service_openwrt_autorun.sh`、`04` 三层清除 `ASH_STANDALONE` 并重执 `/system/bin/sh`；
- 带电 Type-C 扩展坞充电时，OPLUS `oplus_chg_fast_switch_check()` 看到 `USB_DCP` 会翻转硬件 D+/D- 开关 `switch1_gpio:1`（WARP 探测），导致 USB 网卡 `error -71` 掉线；且手动切 `mode=host` 缺少 Type-C 极性事件会导致 `ss_phy` 降级到 USB 2.0（480 Mbps）；
- 解决策略软硬结合：
  1. 内核侧（Run #6 `45950059781` 已刷入验证）：0-KABI 补丁 `fix_oplus_warp_probe.patch` 增加 `/sys/module/oplus_chg/parameters/disable_warp_probe`（默认 `Y` / `0644`，运行时 `echo 0` 可逆），实测 25 次 `disable_warp_probe,return` 拦截、0 次 `switch1_gpio:1`，保留普通 5V / USB-PD 充电；
  2. 用户态（commit `6e3dc25`）：`ensure_usb_host_mode()` 同时支持 `data_role=[host]` 与带电非 PD 坞热插（`mode=none` + `data_role=[device]` + `USB_DCP`），严守 `mode=peripheral` 不碰 PC USB，探测并缓存 `a600000.ssusb/orientation`（`A`/`B` → `/data/openwrt/run/usb3_orient`）锁定 **USB 3.0 5000 Mbps** 边充边用（纯墙充退避 5 分钟）；`service_openwrt_autorun.sh` 升级为 **5 秒**看门狗 + `attach_lan_inplace()` 原地热挂（不重启 `procd`，实测 **11 秒**恢复，失败才回退 `04`）。

---

## 4. 硬件与外设

| 设备 | 要求 | 当前状态 |
| :--- | :--- | :--- |
| 手机 | 一加 9 Pro LE2120，OOS 14 | ✅ |
| USB-C 扩展坞 | 标准 **USB-PD（支持 `PR_SWAP`）** + USB 3.0 | 强烈推荐 PD 坞；非 PD 5V 坞已实测定位限制 |
| USB 网卡 | RTL8156B/BG（2.5G）或 RTL8153（1G） | 1G（`0bda:8153`，5 Gbps）冷启动已验收；2.5G 热插拔已验证、冷启动待复验 |
| 充电头 | 30–65W 标准 PD | 用户自备 |
| 散热 | 可选 | 建议长期运行加 |

> 避免使用非标准 VOOC/WARP 直充头；也避免非 PD 5V 扩展坞（实测 `power_operation_mode=default` / `[BrickID]` 重启后不会自动发送 `PR_SWAP`，需重插才从 `power_role=[source]` 切回 `[sink]` 充电）。使用标准 USB-PD 扩展坞可稳定握手。

---

## 5. 工具箱（实际文件）

| 文件 | 用途 |
| :--- | :--- |
| `scripts/01_backup_partitions.sh` | 备份 boot/vendor_boot/dtbo/modem 等关键分区 |
| `scripts/01b_full_backup_all_partitions.sh` | 117 分区全量备份 |
| `scripts/02_patch_kernel_config.py` | 内核配置合入 |
| `scripts/03_setup_openwrt_rootfs.sh` | 解压/适配 rootfs |
| `scripts/04_start_openwrt_and_network.sh` | 启动容器、USB 3.0 Host 恢复（A/B 极性缓存）、netns 直通、veth、NAT、IPv6、`fw3` 重启 |
| `scripts/05b_cpu_charge_guard.sh` | cpu7 离线、限频、50–60% 停充 |
| `scripts/05_headless_power_control.sh` | 可选无头化节能 |
| `scripts/06_android_functional_test.sh` | Android 功能/命名空间测试 |
| `scripts/06_restore_gui.sh` | 恢复图形界面 |
| `scripts/verify_kabi_crc.py` | 1,607 符号 CRC 闸门 |
| `service_openwrt_autorun.sh` | 开机自启 + 5 秒快速看门狗（USB 3.0 Host 恢复 + `attach_lan_inplace` 原地热挂）+ 30 秒周期检查（WAN / 双模式 `fw3` 自愈 / 电源守护） |
| `service_power_guard.sh` | 电源守护拉起/防重复 |
| `fix_oplus_warp_probe.patch` | 0-KABI 内核补丁：默认跳过 OPLUS WARP D+/D- 探测（`disable_warp_probe=Y`） |

---

## 6. 验收标准

### 必须通过

- [x] `uname -r` = `5.4.254-qgki-gd2a1055adeb0`（CI Run #6 `#1 SMP PREEMPT Fri Nov 27 06:15:42 UTC 2026`）
- [x] KABI 1,607/1,607；开机实载 61 个原厂模块，零符号冲突
- [x] `disable_warp_probe=Y`（`0644`）上机实测生效（25 次拦截、0 次 `switch1_gpio:1`，支持运行时 `echo 0` 可逆）
- [x] 指纹（`fps_hal=running`）/ 显示 / 音频 / 相机 / WiFi / 5G 正常，Magisk `31.1:MAGISK:R`
- [x] `unshare -p -f` 内 PID=1
- [x] 容器 `procd` / `dnsmasq` / `dropbear` / `odhcpd` / `fw3` 运行（单 `procd`，0 泄漏）
- [x] PC 通过 USB 网卡获得 `192.168.2.x`
- [x] LuCI 中文可访问（PC `http://192.168.2.1/` 与手机浏览器 `http://10.200.1.2/`）
- [x] IPv4 出口正常（`223.5.5.5` 0% 丢包）
- [x] IPv6 原生 `/64` 正常（`table 200` `via fe80::2 onlink`，`2400:3200::1` 0% 丢包）
- [x] cpu7 离线，60% 停充
- [x] 拔 USB 数据线、插千兆网卡（RTL8153 `0bda:8153`，USB 3.0 5 Gbps）、重启手机，免手操全自动恢复 LAN + WAN（2026-11-27 通过）
- [x] 带电扩展坞 USB 3.0 5000 Mbps（`usb 3-1`、`orientation=B`、`power_role=[sink]` 边充边用）与 5 秒看门狗原地热挂（断连 11 秒自愈、同 `procd` PID、IPv4 58 ms / IPv6 46–47 ms，0% 丢包）

### 待通过

- [ ] 插 2.5G 网卡（RTL8156B/BG）冷启动免手操复验
- [ ] 连续运行 24–72 小时无断流/内存泄漏
- [ ] 5G 重拨后 IPv6 前缀自动刷新（当前需重跑 `04`）

---

## 7. 剩余工作

| 优先级 | 事项 | 说明 |
| :---: | :--- | :--- |
| P0 | 2.5G 网卡冷启动复验与 24–72h 耐力测试 | 千兆（RTL8153）免手操冷启动与 Run #6 / USB 3.0 原地热挂均已于 2026-11-27 通过；2.5G（RTL8156B/BG）冷启动与长稳测试待验收 |
| P1 | 5G 重拨 IPv6 前缀自动刷新 | USB 网卡热插拔/供电重插自愈已由 5 秒看门狗 + 原地热挂实现；5G 重拨换前缀刷新待自动化 |
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
