# 救砖与紧急回滚手册

> 设备：OnePlus 9 Pro / `lemonadep` / LE2120
> 当前固件：`LE2120_14.0.0.1901`
> 前提：Bootloader 已解锁、AVB 已关闭、Magisk 30.7
> 原则：**先判断故障在哪一层，不要一上来就全量刷机。**

---

## 0. 故障分层

| 层级 | 现象 | 处理 |
| :--- | :--- | :--- |
| **Level 0** | Android 正常，只是 OpenWrt 容器/LAN/WAN 不正常 | 不刷机，停自启、修脚本/rootfs |
| **Level 1** | 刷内核后卡第一屏、无限重启 | Fastboot 刷回原厂 Magisk boot |
| **Level 2** | 能开机但 WiFi/5G/相机异常 | 恢复 `vendor_boot` / `dtbo` / `modemst` / `fsg` / `persist` |
| **Level 3** | 黑屏、进不了 Fastboot | 9008 EDL + MSM Download Tool |

---

## 1. 备份与镜像清单

### 1.1 三个备份文件夹

| 文件夹 | 内容 | 用途 |
| :--- | :--- | :--- |
| `full_backup_LE2120_14.0.0.1901/` | 手机原始 117 分区 + `by-name.txt` / `getprop.txt` / `FILELIST.txt` / `SHA256SUMS.txt` | 原始证据、phone-only 分区来源 |
| `backup_merged_LE2120_14.0.0.1901/` | 117 分区最终恢复集：60 个物理分区用官方镜像，57 个 phone-only 来自手机；附 `MANIFEST.md` + `SHA256SUMS.txt` | **恢复时优先用这一套** |
| `firmware_LE2120_14.0.0.1901/` | 官方 OTA 解包的 43 个镜像 | 构建/对比，不是完整备份 |

### 1.2 当前 boot 镜像

| 文件 | 内容 | SHA256 |
| :--- | :--- | :--- |
| `artifacts/kernel_run4/new-boot-custom-v3.img` | Magisk ramdisk + 自定义内核 | `3c6de08d0e90cbf02d9a2ef8598a1969742ef98a48ebe479be25206848335141` |
| `magisk_patch/magisk_patched_boot_v30.7.img` | 原厂内核 + Magisk 30.7（回滚基准） | `a7fb4a0a65508861cbb235ada0f1e75fca9e23840a0da88a8f6799e0161b4d3d` |
| `firmware_LE2120_14.0.0.1901/boot.img` | 官方原厂 boot（未 Root） | 见官方包 |

> `magisk_patch/boot_a_current.img` 与 `magisk_patched_boot_v30.7.img` 当前内容相同，都是回滚基准。

### 1.3 快速工具

- Fastboot：`.tmp/platform-tools-34/platform-tools/fastboot.exe`（**刷 vbmeta 必须用 34.0.4**，37.0.0 的 `--disable-verity` 有回归 bug）
- ADB：`C:\Users\<你>\AppData\Local\Android\Sdk\platform-tools\adb.exe`
- 9008：高通 USB 驱动 + LE2120 MSM Download Tool（需自行准备）

---

## 2. Level 0：只坏 OpenWrt

Android 能正常开机、能进系统，只是容器/LAN/WAN 异常。

### 2.1 先停自启，防止反复重启

```bash
adb shell su -c "touch /data/openwrt/disable_autorun"
adb shell su -c "rm -f /data/adb/service.d/00_openwrt.sh"
adb reboot
```

`disable_autorun` 只是让看门狗空转；删掉 `00_openwrt.sh` 才是彻底停自启。

### 2.2 看日志

```bash
adb shell su -c "tail -50 /data/openwrt/logs/autorun.log"
adb shell su -c "tail -50 /data/openwrt/logs/init.log"
adb shell su -c "tail -20 /data/openwrt/logs/power_guard.log"
```

### 2.3 重新部署 rootfs

> `03` 会 **清空** `/data/openwrt/rootfs`。先备份配置：

```bash
adb shell su -c "cp -a /data/openwrt/rootfs/etc/config /data/openwrt/config_backup"
adb shell su -c "cp -a /data/openwrt/rootfs/etc /data/openwrt/etc_backup"
```

然后：

```bash
adb shell su -c "sh /data/openwrt/scripts/03_setup_openwrt_rootfs.sh"
adb shell su -c "sh /data/openwrt/scripts/04_start_openwrt_and_network.sh"
```

恢复自启：

```bash
adb shell su -c "printf '#!/system/bin/sh\nexec sh /data/openwrt/scripts/service_openwrt_autorun.sh\n' > /data/adb/service.d/00_openwrt.sh"
adb shell su -c "chmod 755 /data/adb/service.d/00_openwrt.sh"
adb shell su -c "rm -f /data/openwrt/disable_autorun"
```

---

## 3. Level 1：内核卡开机

### 3.1 进 Fastboot

1. 长按电源 + 音量减，强制关机；
2. 关机后长按 **音量加 + 音量减 + 电源**，进入 Fastboot；
3. 连接电脑，确认：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb devices
& $fb getvar current-slot
```

### 3.2 刷回原厂 Magisk boot

当前活动槽是 `a` 时：

```powershell
& $fb flash boot_a magisk_patch\magisk_patched_boot_v30.7.img
& $fb reboot
```

如果 `current-slot` 是 `b`：

```powershell
& $fb flash boot_b magisk_patch\magisk_patched_boot_v30.7.img
& $fb reboot
```

这会恢复原厂内核 + Magisk，**不动数据分区**。

### 3.3 恢复自定义内核

```powershell
& $fb flash boot_a artifacts\kernel_run4\new-boot-custom-v3.img
& $fb reboot
```

### 3.4 完全没有 Root 的原厂 boot

```powershell
& $fb flash boot_a firmware_LE2120_14.0.0.1901\boot.img
& $fb reboot
```

缺点：Magisk 丢失，需要重新用 Magisk App 修补 boot 再刷入。

---

## 4. Level 2：WiFi / 5G / 相机异常

如果内核能开机，但 `vendor_boot` / `dtbo` / 基带校准被破坏，恢复以下分区。

> **只刷自己手机的备份。** `modemst1`、`modemst2`、`fsg`、`persist` 包含 IMEI / 射频校准 / 传感器校准，刷错别人的会变砖或丢 IMEI。

### 4.1 恢复启动相关

```powershell
& $fb flash vendor_boot_a backup_merged_LE2120_14.0.0.1901\vendor_boot_a.img
& $fb flash dtbo_a backup_merged_LE2120_14.0.0.1901\dtbo_a.img
& $fb reboot
```

### 4.2 恢复基带 / 校准（谨慎）

```powershell
& $fb flash modem_a backup_merged_LE2120_14.0.0.1901\modem_a.img
& $fb flash modemst1 backup_merged_LE2120_14.0.0.1901\modemst1.img
& $fb flash modemst2 backup_merged_LE2120_14.0.0.1901\modemst2.img
& $fb flash fsg backup_merged_LE2120_14.0.0.1901\fsg.img
& $fb reboot
```

`persist` 一般不要动；只有传感器/指纹校准确实损坏时才考虑：

```powershell
& $fb flash persist backup_merged_LE2120_14.0.0.1901\persist.img
```

### 4.3 验证

```bash
adb shell getprop gsm.sim.state
adb shell getprop ro.boot.verifiedbootstate
adb shell dumpsys fingerprint | head
adb shell su -c "dmesg | grep -iE 'wlan|modem|fingerprint' | tail -30"
```

---

## 5. Level 3：黑屏 / 进不了 Fastboot（9008 EDL）

1. 电脑安装 **Qualcomm USB Driver**；
2. 打开 **MSM Download Tool**（LE2120 国行对应版本）；
3. 手机完全关机；
4. 按住 **音量加 + 音量减**，插 USB；
5. 设备管理器出现 `Qualcomm HS-USB QDLoader 9008 (COMx)`；
6. MSM 工具点 `Start`，等待 3–5 分钟；
7. 手机自动重启。

> EDL 会重写底层分区，**数据会丢**；但 117 分区备份仍在电脑上，可之后恢复关键分区。

---

## 6. A/B 槽位与 AVB

### 6.1 槽位

```powershell
& $fb getvar current-slot
```

- 当前使用 `a` 槽；
- `boot_b` / `vendor_boot_b` / `dtbo_b` 未作为主验证对象；
- 切槽不会自动恢复数据，只是换一套 boot/vendor_boot。

### 6.2 AVB

当前 `vbmeta_a` flags = `0x3`（verification + hashtree 关闭）。OTA 会覆盖 `vbmeta_a`，恢复 AVB。

重新关闭：

```powershell
& $fb --disable-verity --disable-verification flash vbmeta_a firmware_LE2120_14.0.0.1901\vbmeta.img
```

恢复官方：

```powershell
& $fb flash vbmeta_a backup_merged_LE2120_14.0.0.1901\vbmeta_a.img
```

> **不要在 vbmeta 被修改的情况下重新锁 Bootloader。** 先刷回官方 vbmeta，再回锁。

---

## 7. 校验备份完整性

在仓库根目录（Windows PowerShell 没有 `sha256sum` 时可用 Python）：

```powershell
python -c "
import hashlib, pathlib
root = pathlib.Path('backup_merged_LE2120_14.0.0.1901')
bad = []
for line in (root/'SHA256SUMS.txt').read_text().splitlines():
    if not line.strip(): continue
    want, name = line.split(None, 1)
    name = name.lstrip('*')
    h = hashlib.sha256()
    with open(root/name, 'rb') as f:
        for c in iter(lambda: f.read(8*1024*1024), b''): h.update(c)
    if h.hexdigest() != want: bad.append(name)
print('bad:', bad if bad else 'none')
"
```

Linux / Git Bash：

```bash
cd backup_merged_LE2120_14.0.0.1901
sha256sum -c SHA256SUMS.txt
```

---

## 8. OTA 注意事项

1. OTA 会覆盖 `boot` 和 `vbmeta_a`；
2. 解锁 + Root 状态下 OTA 经常失败，通常要走完整固件 fastboot 刷入；
3. 刷完整固件会清数据（取决于是否 `-w`）；
4. 升级后先做 KABI 对比：
   - 全部匹配 → 只重打包/刷 boot；
   - 有不匹配 → 重编内核；
5. 不要直接锁回 Bootloader，除非确认所有分区都是官方签名状态。

---

## 9. 最小回滚口诀

```text
只坏 OpenWrt  → 停自启、看日志、重跑 03/04
刷内核不开机  → fastboot flash boot_a magisk_patched_boot_v30.7.img
WiFi/5G 异常  → 恢复 vendor_boot_a / dtbo_a / modemst1/2 / fsg
彻底黑屏      → 9008 EDL + MSM
```

只要 117 分区备份和 `magisk_patched_boot_v30.7.img` 在，手机可以救回来。
