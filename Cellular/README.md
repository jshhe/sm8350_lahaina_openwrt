# 一加 9 Pro (LE2120) 中国移动 SA n41+n79 2CC

设备：OnePlus 9 Pro `LE2120`，ColorOS 14 `LE2120_14.0.0.1901(CN01)`，Magisk root
网络：中国移动 5G SA（46000），n41 / n79 共站

> 主项目总览和 OpenWrt 容器部分见 [`../README.md`](../README.md)；本文只记录 5G CA 修复。

---

## 结论

一加 9 Pro 在 CMCC SA 下默认只能跑单载波。根因不是硬件，也不是网络或温控，而是
**一加的 CMCC 运营商 MBN 把 TDD+TDD NR 载波聚合关掉了**。

对应的 NV 项：

```text
/nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos
```

| 来源 | 值 |
|---|---|
| 一加 通用 MBN | `07 01 01 01` |
| 一加 CMCC `OPLUS_CMCC_OpenMkt` | `07 00 00 00` |
| 小米 11 Pro CMCC `Volte_OpenMkt` | `07 01 01 01` |

MBN 记录格式为 `02 00 <len> 00 <1 字节版本> <值>`，所以 4 字节 `07 00 00 00`
对应运行时 EFS 里的 3 字节 `00 00 00`。

运行时 EFS 实测（两条路径都必须改）：

```text
/nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos
/nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos_Subscription01
  → 00 00 00
```

把两条路径都写成 `01 01 01` 后，n41+n79 聚合生效。

> 直接改 `/data/vendor/modem_config/.../mcfg_sw.mbn` **无效**：MBN 版本号没有变化，
> modem 不会重新应用；必须写运行时 EFS，或同时提升 MBN 版本。

---

## 效果

| 配置 | 测速 |
|---|---|
| 小米 17 Pro Max，CA 关 | ~800 Mbps |
| 小米 17 Pro Max，CA 开 | ~1200 Mbps |
| 一加，修改前 | 800–900 Mbps |
| 一加，修改后 | **1100+ Mbps** |

同一位置、同一时段对比，小米关 CA 的速度没有变化（始终 ~800），
说明网络条件未变，一加的提升来自聚合本身。

排除项：n79 主载波 RSRP 约 -67 dBm / SINR 30、电池约 30.9°C、单卡、Smart 5G 已关闭；
不是信号、温控、双卡或网络负载。

---

## 修复步骤

前置条件：

- 手机 `sys.usb.config=diag,adb`
- Windows 已用 Zadig 给 `22d9:276c` 的 Interface 0 装 WinUSB
- 详见 [`tools/capture_setup.md`](tools/capture_setup.md)

**关键：抓包/写 EFS 前必须停掉 adb server**，否则 libusb 打开复合设备时会被
ADB 接口（MI_01）拒绝，报 `Access denied`。

```powershell
$ADB   = "<platform-tools>\adb.exe"     # 或直接使用 PATH 里的 adb
$TOOLS = "<OpenCodeProjects>\.tools"    # 仓库外的 QCSuper 工具目录

& $ADB shell 'su -c "setprop sys.usb.config diag,adb"'
& $ADB kill-server
```

准备 3 字节文件（内容 `01 01 01`），通过 QCSuper 的 EFS shell 写入：

```text
put C:/path/nv_tt_010101.bin /nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos
put C:/path/nv_tt_010101.bin /nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos_Subscription01
exit
```

```powershell
$QCSuper = "$TOOLS\qcsuper.cmd"
Get-Content cmds.txt | & $QCSuper --usb-modem 22d9:276c:1:0 --efs-shell
```

验证：

```text
cat /nv/item_files/modem/nr5g/RRC/cap_control_nrca_t_plus_t_band_combos
→ 01 01 01
```

然后重启手机。EFS 值重启后保持（已验证多次重启）。

> 直接改 MBN 文件无效：modem 只在 MBN 版本变化时重新应用，改内容不触发。

---

## 还原

把 `00 00 00`（3 字节）写回同样的两个路径，重启。

原厂 MBN 备份：

```text
/sdcard/Download/mcfg_sw.mbn.orig
md5 c6d360938f865863eb32daa3574a3630
```

---

## 注意事项

- **系统 OTA 可能覆盖**：升级后 modem 配置可能被重新应用，速度若回落需重新写入；
- 一加的 `mPhysicalChannelConfigs` 结构本身残缺（`mBand=0`、`mChannelNumber=invalid`、
  `mBandwidth=0`），**不能**用来判断载波数；
- QMI `Get RF Band Information` 在这台机器上始终只报一组 band，也不可靠；
- 最终确认需要抓 RRC 看 `sCellToAddModList`（工具链已就绪，见下）。

---

## 目录

```text
Cellular/
├─ README.md                 本文
├─ qmi_test/                 QMI NAS 测试工具源码（读/设频段、SSP mask）
├─ cellular_pro/             分析残留：CMCC MBN 参考样本 + Cellular Pro 分析笔记
└─ tools/
   ├─ capture_setup.md       Windows 下 QCSuper/SCAT + WinUSB 抓 diag 的完整步骤
   ├─ collect_ca_root.sh     root 手机端采集 dumpsys（2 秒一条）
   ├─ collect_ca_qmi.sh      手机端同时采集 dumpsys + QMI RF band
   ├─ collect_ca.sh          小米（Shizuku/rish）用的采集脚本
   ├─ ca_n41_test.sh         锁 n41 → 提示测速 → 加回 n79 → 记录 120 秒
   ├─ parse_telephony.py     日志解析，输出 CSV（nr_count / secondary / ss_arfcn 等）
   └─ rish_setup.sh          小米 Shizuku rish 安装脚本
```

抓包工具不在本仓库（放在仓库外的 `<OpenCodeProjects>\.tools\`）：

```text
<OpenCodeProjects>\.tools\
├─ qcsuper\        QCSuper 2.1.4
├─ scat\           SCAT 2.1.2
├─ venv\           Python 3.14 环境（含 libusb DLL）
├─ qcsuper.cmd
├─ scat.cmd
└─ zadig-2.9.exe   WinUSB 驱动工具
```
