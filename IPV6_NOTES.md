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

实测结果：

- PC 通过 USB 网卡获得运营商 `/64` 内的地址；
- PC 可以 ping 容器 `eth0` 的 `::1`；
- PC 可以 ping 外网 `2400:3200::1`；
- 容器内 `odhcpd` 正常发 RA；
- 没有配置任何 NAT66 规则。

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

> 5G 接口不是固定的：脚本用 `ip route get 8.8.8.8` 找真正承载默认路由的 `rmnet_dataX`，不写死 `rmnet_data0/1/2`。

### 3.2 容器侧

```text
eth0:      <prefix>::1/64
veth-owrt: fe80::2/64
默认路由:  via fe80::1 dev veth-owrt
```

### 3.3 宿主侧

```text
veth-host: fe80::1/64

table 200:
  <prefix>::/64 dev veth-host

ip -6 rule:
  1000: iif <rmnet> lookup 200
```

作用：从 5G 进来的、目标地址属于 LAN `/64` 的包，转发到 `veth-host`，而不是又从 `rmnet` 发回去。

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

Android netd 会在网络变化时重置这些值，自启看门狗每 30 秒重新断言。

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
4. **容器内没有 IPv6 防火墙**：`fw3` 未实际运行，IPv6 转发安全边界在宿主侧，默认没有做 LAN 隔离；
5. **热点客户端不共享**：Android 热点仍是独立网络，与容器 LAN 隔离。

---

## 6. 验证命令

```bash
# 宿主
adb shell su -c "ip -6 addr show dev rmnet_dataX scope global"
adb shell su -c "ip -6 rule | head"
adb shell su -c "ip -6 route show table 200"

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
# 浏览器: https://test-ipv6.com/
```
