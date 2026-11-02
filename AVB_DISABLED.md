# AVB / dm-verity 已关闭（A 槽）

- 时间：2026-10-25
- 设备：OnePlus 9 Pro LE2120，`LE2120_14.0.0.1901(CN01)`
- 槽位：`a`（当前活动槽）
- 结果：`vbmeta_a` flags = `0x00000003`
  - bit 0 `VERIFICATION_DISABLED`
  - bit 1 `HASHTREE_DISABLED`
- 当前状态（2026-11）：仍为 `0x3`，自定义内核与 Magisk 正常工作

## 刷写命令

> 必须用 platform-tools **34.0.4** 的 fastboot。
> platform-tools 37.0.0 的 `--disable-verity` 有回归 bug，会报
> `Failed to find AVB_MAGIC at offset: 0`。

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb --disable-verity --disable-verification flash vbmeta_a `
    "firmware_LE2120_14.0.0.1901\vbmeta.img"
```

实际只改了 vbmeta 头的 flags 字节（offset 123，`00` → `03`），没有改分区表或启动链。

## 验证

读回 `vbmeta_a` 与官方镜像逐字节比较，只有 offset 123 变化。

开机后 dmesg：

```text
[libfs_avb]Returning avb_handle with status: VerificationDisabled
AVB HASHTREE disabled on: /system_ext
AVB HASHTREE disabled on: /product
AVB HASHTREE disabled on: /vendor
```

`ro.boot.verifiedbootstate` 仍为 `orange`（Bootloader 已解锁，属正常）。
Magisk 30.7 Root 正常。

## 回滚

恢复官方 vbmeta（不改 flags）：

```powershell
$fb = ".tmp\platform-tools-34\platform-tools\fastboot.exe"
& $fb flash vbmeta_a "firmware_LE2120_14.0.0.1901\vbmeta.img"
# 或者用合并后的恢复集：
& $fb flash vbmeta_a "backup_merged_LE2120_14.0.0.1901\vbmeta_a.img"
```

> 恢复官方 vbmeta 后，AVB 会重新启用。只要 Bootloader 仍解锁，自定义内核 + Magisk 仍可启动；但如果要回锁 Bootloader，必须先恢复所有官方分区。

## 注意

1. **OTA 会覆盖 `vbmeta_a`**，升级后 AVB 会重新启用，需要重新执行上面的刷写命令。
2. **不要在 vbmeta 被修改的情况下重新锁 Bootloader**，否则签名校验失败可能无法开机。回锁前先刷回官方 vbmeta。
3. B 槽的 `vbmeta_b` 没有动，仍是旧版官方状态；当前只对活动槽 A 关闭了 AVB。
4. platform-tools 34.0.4 保留在 `.tmp\platform-tools-34\`，以后刷 vbmeta 直接用它。
5. 备份与回滚的完整流程见 [`RECOVERY_AND_ROLLBACK.md`](RECOVERY_AND_ROLLBACK.md)。
