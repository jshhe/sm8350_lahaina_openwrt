# Qualcomm DIAG 抓包环境（Windows）

用于抓取 UE Capability / CA 组合，验证一加 LE2120 在 CMCC SA 下是否支持 n41+n79。

## 1. 工具位置

```text
<OpenCodeProjects>\.tools\
├─ qcsuper\              QCSuper 2.1.4（源码）
├─ scat\                 SCAT 2.1.2（fgsect/scat）
├─ venv\                 Python 3.14 虚拟环境
├─ qcsuper.cmd           包装脚本（自动把 venv\Scripts 加进 PATH，供 pyusb 找 libusb DLL）
├─ scat.cmd              同上
├─ zadig-2.9.exe         驱动工具
├─ libusb27\             libusb 1.0.27 官方二进制（备用）
└─ libusb-src\           libusb 源码（排查用）
```

`venv\Scripts\libusb-1.0.dll` 目前是 1.0.27（VS2022 MS64），备份在 `libusb-1.0.dll.1.0.30.bak`。

## 2. 驱动（只需做一次）

一加切到 diag 模式后，USB 变成 `22d9:276c`：

```text
interface 0: FF/FF/30  0x01/0x81   ← ffs.diag
interface 1: FF/42/01  0x02/0x82   ← ffs.adb
```

Windows 自带的 "OPPO HS-USB MSM Diagnostics" 驱动会 Code 10 起不来，必须用 Zadig 把 **Interface 0** 换成 **WinUSB**。

- 手机：`adb shell su -c "setprop sys.usb.config diag,adb"`
- Zadig（管理员）→ Options → List All Devices → 选 `SM8350-MTP (Interface 0)` → WinUSB → Replace Driver

> 设备名永远是 "SM8350-MTP"，因为 USB 产品字符串不随模式变；认 **Interface 0**，不要选 Interface 1（ADB）。

装好后设备管理器里应显示：

```text
SM8350-MTP (Interface 0)   USBDevice   svc=WinUSB   Status OK
```

## 3. 关键坑：抓包前必须停掉 adb server

libusb 打开复合设备时会把**所有 WinUSB 接口**都打开一遍。adb 接口被 adb server 占着时会返回
`Access denied`，导致整个 `libusb_open` 失败——即使 diag 接口本身完全正常。

```powershell
& "<platform-tools>\adb.exe" kill-server
```

抓完再：

```powershell
& "<platform-tools>\adb.exe" start-server
```

## 4. 抓包

```powershell
# 设备信息，确认链路
& "<OpenCodeProjects>\.tools\qcsuper.cmd" --usb-modem 22d9:276c:1:0 --info

# 抓 PCAP + 原始 DLF
& "<OpenCodeProjects>\.tools\qcsuper.cmd" `
  --usb-modem 22d9:276c:1:0 `
  --pcap-dump .tmp\uecap.pcap `
  --dlf-dump  .tmp\uecap.dlf
```

抓包期间在手机上**开关一次飞行模式**，让 UE 重新 attach，基站才会重新发
`UECapabilityEnquiry`。等 30 秒左右按 Ctrl-C 停止。

> 必须 Ctrl-C 正常退出：QCSuper 写文件没有 flush，直接 kill 会得到 0 字节。

## 5. 分析

```powershell
& "<OpenCodeProjects>\.tools\scat.cmd" -t qc -d .tmp\uecap.qmdl --cacombos
```

重点看：

- `LOG_5GNR_RRC_SUPPORTED_CA_COMBOS`：基带自己记录的 CA 组合表；
- `UECapabilityInformation`：发给网络的 `ca-ParametersNR`，看有没有 `n41-n79`。

Wireshark 也可以直接开 pcap（GSMTAP），但 NR RRC 需要 SCAT 的插件。

## 6. 恢复手机 USB

```powershell
& "<platform-tools>\adb.exe" shell 'su -c "setprop sys.usb.config mtp,adb"'
```

注意：从 `diag,adb` 切回 `mtp,adb` 时，configfs 的 f1/f2 可能仍指向 `ffs.diag`/`ffs.adb`
（diag-router 占着 ffs，切换失败），属性显示 `mtp,adb` 但主机侧仍是 PID 276C、没有 MTP。
**重启手机**即可恢复（`persist.sys.usb.config=mtp,adb`）。

## 7. 已验证的事实

- `--info` 成功，返回：
  ```text
  Chip version:        3
  Firmware build ID:   MPSS.HI.4.3.c4-00234-LC_ALL_PACK-1.27136.146
  Diag version:        8
  ```
- 单独对 MI_00 做 `CreateFileW` + `WinUsb_Initialize` 均成功（非管理员），所以不是权限问题。
- libusb 1.0.27 和 1.0.30 表现一致，不是 DLL 版本问题。
