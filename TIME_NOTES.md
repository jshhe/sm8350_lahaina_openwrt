# 时间 / RTC 事故与修复

> 设备：OnePlus 9 Pro / LE2120 / OOS 14 `LE2120_14.0.0.1901`
> 结论：**问题在 OpenWrt 容器，不在 Android 自动同步。**

---

## 1. 根因

容器共享 Android 内核，并且把宿主 `/dev` 绑定进容器：

```bash
mount --bind /dev "$ROOTFS/dev"
```

OpenWrt 的 `/etc/init.d/sysfixtime` 在开机时执行：

```sh
hwclock -s -u -f /dev/rtc0
```

`hwclock -s` = **从 RTC 读取时间并写入系统时钟**。这台手机的 RTC 停在 1970（`/sys/class/rtc/rtc0/since_epoch` 只有约 77 万秒），于是容器每次启动都把 Android 系统时间打回 1970。

同一次启动里 `/etc/init.d/system` 还有：

```sh
hwclock -u --systz
```

关机时 `sysfixtime stop()` 又会执行 `hwclock -w`，把错误的系统时间写回 RTC，形成闭环。

同时容器因为 `veth-owrt` 创建/清理 bug 每 30 秒失败重启一次，所以表现成“过几十秒时间又变回 1970”。

---

## 2. 为什么普通“自动同步”救不回来

- `Settings.Global.AUTO_TIME` 当时是 `0`（自动时间实际没开）；
- 即使打开，`network_time_update_service` 默认 18 小时才重新 NTP 一次；
- 拨一下开关只是用开机时缓存的 NTP 结果外推，不会立即重新联网；
- 缓存里的 NTP 对端显示为 `127.0.0.1:123`，本身就不正常。

所以手动同步一次后，30 秒内又被容器覆盖。

---

## 3. 修复内容

### 3.1 容器侧（关键）

`scripts/03_setup_openwrt_rootfs.sh` 在解压 rootfs 后：

- 删除 `/etc/rc.d/*sysfixtime`、`/etc/rc.d/*sysntpd`；
- 把 `/etc/init.d/sysfixtime` 替换成 no-op 脚本；
- 注释 `/etc/init.d/system` 里的 `hwclock -u --systz`；
- 把 `/etc/config/system` 的 NTP client 设为 `enabled=0`。

`scripts/04_start_openwrt_and_network.sh` 在容器 init 完成后：

```sh
mount --bind /dev/null /dev/rtc0
mount --bind /dev/null /dev/rtc
```

把手机 RTC 从容器里隐藏掉（OpenWrt preinit 会重新挂 devtmpfs，所以必须在 init 完成后做）。

### 3.2 容器生命周期

- 按 `/proc/<pid>/root` 杀整个容器进程树，而不是只杀 wrapper PID；
- 等 PID namespace init 真正出现后再写 `container.pid`；
- 用 toybox `ip link add name ...` 创建 veth，并校验 peer 真的存在；
- `04` 加目录锁，禁止 autorun 和手动执行并发；
- `04` 对 5G PDN 抖动重试 30 秒；
- autorun 用 `ip -4 route show table all` 找活跃 rmnet，不再依赖系统默认路由（Wi-Fi 可能是默认）；
- 5G 冷启动等待延长到 180 秒；
- 看门狗继续每 30 秒检查容器和电源守护。

### 3.3 Android 侧

```bash
settings put global auto_time 1
settings put global ntp_server ntp.aliyun.com
cmd network_time_update_service force_refresh
```

`auto_time` 之前是 `0`，已改为 `1`。

---

## 4. RTC 写入限制

`hwclock -w -u -f /dev/rtc0` 仍然失败：

```text
hwclock: ioctl RTC_SET_TIME: Permission denied
```

即使 `setenforce 0`（Permissive）、CapEff 全开也一样。说明不是容器问题，而是这台机器的 RTC 写入路径被内核/固件限制。RTC 读数仍是 1970。

因此：

- **不要依赖 RTC**；
- Android 开机后由 NTP（`ntp.aliyun.com`）校正；
- 容器永远不读/写 RTC；
- 彻底断电后如果 RTC 仍回到 1970，属于 RTC 备份供电/晶振的硬件问题。

---

## 5. 验证结果

| 项目 | 结果 |
| :--- | :--- |
| 容器启动前/后宿主时间 | 不变（2026-11-03） |
| 容器内 `date +%s` | 与宿主 epoch 一致 |
| 容器重启/看门狗重启 | 宿主时间不变 |
| 重启 Android 后 | 时间保持正确，NTP 生效 |
| 容器内 `ntpd` | 0 个 |
| 容器内 `/dev/rtc0` | 被 `/dev/null` 覆盖 |
| 容器进程 | 1 个 `procd`，约 10 个 rootfs 进程 |
| 泄漏实例 | 清理前 2002 个 rootfs 进程 / 196 个 netns → 0 |
| `04` 退出码 | 0（WAN-only） |

---

## 6. 维护注意

1. **不要重新启用** `sysfixtime` / `sysntpd`；
2. 如果重跑 `03`，补丁会自动应用；
3. 如果手工替换 rootfs，必须重新应用第 3.1 节；
4. 不要把 `/dev/rtc0` 重新暴露给容器；
5. Android 的 `auto_time` 和 `ntp_server` 属于用户设置，恢复出厂/OTA 后要重新确认；
6. `04.lock.d` 正常退出会自动删除；如果进程被 `kill -9`，下一次启动会检测 stale PID 并清理。

---

## 7. 待验证：RTC 断电测试（2026-11-03）

用户准备做一次**完全关机、拔电、再开机**，用来判断 RTC 是“只是时间丢了”还是“备份供电/晶振坏了”。

### 7.1 断电前基线（2026-11-03 23:51:28 CST）

```text
Android 时间:        2026-11-03 23:51:28 CST
Android epoch:       1793721088
RTC since_epoch:     799137
RTC 时间:            1970-01-10 05:58:57 UTC
Android uptime:      2599.71 秒（约 43 分钟）
auto_time:           1
ntp_server:          ntp.aliyun.com
```

### 7.2 开机后要记录

```bash
adb shell su -c "date; date +%s"
adb shell su -c "cat /sys/class/rtc/rtc0/since_epoch"
adb shell su -c "hwclock -r -u -f /dev/rtc0"
adb shell su -c "cat /proc/uptime"
```

### 7.3 判读

| 开机后现象 | 结论 |
| :--- | :--- |
| `since_epoch` 明显大于 799137（例如 +断电时长） | RTC 计数器和备份供电都正常，只是时间没校准 |
| `since_epoch` 接近 799137，且 uptime 很小 | 可能没有真正断电，RTC 保持供电，测试无效 |
| `since_epoch` 回到很小的值/再次停在 1970-01-09 附近 | RTC 备份供电或晶振有问题，属于硬件 |
| `hwclock -r` 报错/读数不递增 | RTC 硬件或驱动异常 |

> 注意：RTC 写入本身仍被 `RTC_SET_TIME: Permission denied` 挡住，所以即使 RTC 计数正常，也不能用 `hwclock -w` 校准；Android 继续靠 NTP。

