# IPv6 设计说明：同 `/64` 原生共享，不做 NAT66

## 1. 结论

一加 9 Pro 的 5G 是**单 UE**。运营商通常只给一个 `/64`，正确做法和 Android 热点一致：

- 上游 `rmnet_dataX` 持有运营商 `/64`；
- 容器 LAN `eth0` 配同一个 `/64` 的 `::1/64`；
- `odhcpd` 在 LAN 发 RA，客户端 SLAAC 得到同前缀地址；
- 宿主只做**IPv6 转发 + 策略路由**；
- **不使用 NAT66，不使用 ULA**。

这样 LAN 客户端拿到的是原生公网 IPv6，不需要地址转换。

---

## 2. 实测依据

### 2.1 Android 热点

插卡开热点时观察：

```text
rmnet_dataX: 2001:db8:1234:5678::a1b2/64   (5G 上游)
wlan2:       2001:db8:1234:5678::c1/64     (热点 AP)
client:      2001:db8:1234:5678::2/64      (下级设备)
```

> 地址为 RFC 3849 示例前缀，不是真实运营商前缀。

- 三者是**同一个 `/64`**；
- `ip6tables -t nat` 表不存在（原厂内核没有 `IP6_NF_NAT`）；
- `dumpsys tethering` 显示 IPv6 由 **BPF / 硬件 offload** 在 `rmnet_dataX` 和 `wlan2` 之间转发，客户端源地址保持不变；
- 下级 `test-ipv6.com` 10/10 通过。

结论：Android 热点没有做 NAT66，而是把运营商 `/64` 同时放在上游和 AP 上，按客户端地址转发。

### 2.2 OpenWrt 容器

实测结果（2026-11-27 复验通过）：

- PC（`以太网 3`，RTL8153 1 Gbps）通过 USB 网卡经 SLAAC/RA 自动获得运营商同 `/64` 地址；
- PC 可 ping 通容器 `eth0` 的 `::1`；
- PC 可 ping 通外网 `2400:3200::1`（热修后实测 **34–53 ms**、冷启动免手操验收实测 **44–48 ms**、USB 断连原地热挂基准实测 **46–47 ms**，均为 **0% 丢包**）；
- 容器内 `odhcpd` 正常发 RA；
- 没有配置任何 NAT66 规则，也没有使用 ULA。

---

## 3. 当前实现（`04_start_openwrt_and_network.sh`）

### 3.1 前缀检测

```bash
V6_CIDR=$(ip -6 addr show dev "$RMNET_IF" scope global | awk '/inet6/ {print $2; exit}')
```

只处理 `/64`：

```text
V6_NET      = <prefix>::/64
V6_LAN_ADDR = <prefix>::1
```

> 5G 接口不是固定的：脚本先查 `ip route get 8.8.8.8`，若 Wi-Fi 是默认路由则通过 `find_rmnet_wan()`（`ip -4 route show table all`）查找真正持有 IPv4 默认路由的 `rmnet_dataX`，不写死 `rmnet_data0/1/2`。

### 3.2 容器侧

```text
eth0:      <prefix>::1/64
veth-owrt: fe80::2/64
默认路由:  default via fe80::1 dev veth-owrt onlink
```

### 3.3 宿主侧

```text
veth-host: fe80::1/64

table 200:
  <prefix>::/64 via fe80::2 dev veth-host onlink

ip -6 rule:
  1000: iif <rmnet> lookup 200
```

作用：从 5G 进来的、目标地址属于 LAN `/64` 的回程包，经由容器侧 `veth-owrt` 的链路本地下一跳 `fe80::2` 转发到 `veth-host`，而不是又从 `rmnet` 发回去。

> **关键修复（2026-11-27）**：旧版 `04` 写的是 `<prefix>::/64 dev veth-host`（无下一跳）。这样 Android 会把整个 `/64` 视为 `veth-host` 直连网段，在 `veth-host` 上直接对 LAN 客户端发 NDP 邻居解析并失败（因为客户端位于容器另一侧的 `eth0` 后方），导致 PC 外网 IPv6 100% 丢包。改为 `via fe80::2 dev veth-host onlink table 200` 后，回程流量由容器路由到 `eth0`，PC ping `2400:3200::1` 立即恢复 0% 丢包。

如果 Wi-Fi 仍是默认路由、5G 不是默认，脚本还会尽力建立：

```text
table 201:
  default via <5G IPv6 网关> dev <rmnet>

ip -6 rule:
  1001: from <prefix>::/64 lookup 201
```

> 某些 Android 版本的路由表不是以接口名命名，table 201 可能为空；已验证的主路径不依赖它，因为宿主 main 表已有 5G IPv6 默认路由。

### 3.4 转发开关

```bash
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
echo 1 > /proc/sys/net/ipv6/conf/<rmnet>/forwarding
echo 1 > /proc/sys/net/ipv6/conf/veth-host/forwarding
```

Android netd 会在网络变化时重置这些值，自启看门狗每 30 秒（5 秒循环第 6 拍）重新断言；此外，当 USB 网卡热插拔或供电重插重新枚举时，`service_openwrt_autorun.sh` 的 `attach_lan_inplace()` 会原地将 `eth0` 挂回容器 netns，并同步重配原生 IPv6 `/64`、`table 200`（`via fe80::2 onlink`）及 `odhcpd`，无需重启 `procd`。

### 3.5 RA / DHCPv6

`/etc/config/dhcp` 中 LAN：

```text
option ra 'server'
option dhcpv6 'server'
option ra_management '1'
option ra_default '1'
option ra_dns '1'
```

客户端通过 SLAAC 获得同 `/64` 地址，DNS 由 RA 下发。

---

## 4. 为什么不用 NAT66

1. **不必要**：运营商已经给了 `/64`，LAN 可以直接用同前缀；
2. **破坏端到端**：NAT66 会让外部无法主动连接 LAN 设备；
3. **内核能力不是问题**：自定义内核虽然开了 `CONFIG_IP6_NF_NAT=y`，但当前方案完全没用到；
4. **和 Android 热点行为一致**：热点就是原生共享，已经被运营商网络验证可行。

---

## 5. 已知限制

1. **只处理 `/64`**：如果运营商给 `/56` / `/60`，脚本不会自动切前缀长度；
2. **前缀变化不自动刷新**：5G 重拨后运营商可能换 `/64`，当前需要重跑 `04` 或重启手机；
3. **没有 NDP proxy**：依赖运营商把整个 `/64` 路由到 UE；实测当前网络可用，但换运营商可能需要在 `rmnet` 上补 proxy NDP；
4. **IPv6 公网暴露边界需自行审视**：容器内 `fw3`（`iptables-legacy`）已正常运行并由看门狗每 30 秒在 LAN 与 WAN-only 双模式下自动自愈（`Allow-Host-UI` 与 IPv4 `MASQUERADE` 均生效），但 LAN 客户端持有运营商公网 `/64` 地址且入口经由 Android 宿主转发，如需严格 IPv6 入站隔离请额外核查容器 `ip6tables` 规则；
5. **热点客户端不共享**：Android 热点仍是独立网络，与容器 LAN 隔离。

---

## 6. 验证命令

```bash
# 宿主
adb shell su -c "ip -6 addr show dev rmnet_dataX scope global"
adb shell su -c "ip -6 rule | head"
adb shell su -c "ip -6 route show table 200"
# 期望包含：<prefix>::/64 via fe80::2 dev veth-host onlink

# 容器
P=$(cat /data/openwrt/run/container.pid)
BB=/data/adb/magisk/busybox
$BB nsenter -t "$P" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c '
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  ip -6 addr show eth0
  ip -6 route
  ping -6 -c 2 2400:3200::1
'

# 客户端
# Windows: ipconfig /all，确认拿到同 /64 地址
# Windows: ping -6 2400:3200::1（实测 34-53 ms / 0% 丢包）
# 浏览器: https://test-ipv6.com/
```
