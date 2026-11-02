#!/system/bin/sh
# ==============================================================================
# 04_start_openwrt_and_network.sh
# Start the OpenWrt chroot, move the USB LAN NIC into its netns, create a veth
# WAN pair, and route the container through the Android 5G modem.
#
# Track A (stock kernel): mount+UTS+net namespaces, no PID namespace.
# Track B (custom kernel): adds PID namespace; IPv4 + native IPv6 /64.
#
# IPv6 design note: do NOT use NAT66. Share the carrier /64 with the LAN via
# routing + RA; see IPV6_NOTES.md.
#
# Run as root (adb shell su -c "sh /data/openwrt/scripts/04_start_openwrt_and_network.sh").
# ==============================================================================

ROOTFS="/data/openwrt/rootfs"
STATE_DIR="/data/openwrt"
RUN_DIR="/data/openwrt/run"
LOG_DIR="/data/openwrt/logs"
LAN_IF="${LAN_IF:-eth0}"
VETH_HOST="veth-host"
VETH_OWRT="veth-owrt"
HOST_IP="10.200.1.1"
OWRT_IP="10.200.1.2"
HOST_NET="10.200.1.0/30"
TABLE_ID=100
CONTAINER_PID=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

[ -d "$ROOTFS" ] || { log "ERROR: $ROOTFS not found; run 03_setup_openwrt_rootfs.sh first"; exit 1; }
mkdir -p "$STATE_DIR" "$RUN_DIR" "$LOG_DIR"

# ------------------------------------------------------------------------------
# Locate BusyBox. Android's toybox ip does not implement 'ip link ... netns';
# Magisk/KernelSU BusyBox does.
# ------------------------------------------------------------------------------
BB=""
for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /system/bin/busybox /system/xbin/busybox; do
    if [ -x "$b" ]; then
        BB="$b"
        break
    fi
done
[ -n "$BB" ] || { log "ERROR: busybox not found; install Magisk/KernelSU first"; exit 1; }
BB_IP="$BB ip"
log "busybox: $BB"

# ------------------------------------------------------------------------------
# Find the 5G WAN interface. Prefer the clat IPv4 interface when Android has
# created one (IPv6-only carrier + 464XLAT).
# ------------------------------------------------------------------------------
# Pick the interface that actually carries the default IPv4 route.
# The active 5G PDN is not fixed: it may be rmnet_data0, rmnet_data1,
# rmnet_data2, etc. depending on the carrier/SIM state.
RMNET_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
case "$RMNET_IF" in
    rmnet*|v4-rmnet*) ;;
    *)
        RMNET_IF=""
        for iface in rmnet_data1 rmnet_data0 rmnet0 v4-rmnet_data0; do
            if ip link show "$iface" >/dev/null 2>&1 && ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
                RMNET_IF="$iface"
                break
            fi
        done
        ;;
esac
[ -n "$RMNET_IF" ] || { log "ERROR: no active rmnet interface; enable mobile data and disable Wi-Fi"; exit 1; }
log "5G WAN (IPv4): $RMNET_IF"

# ------------------------------------------------------------------------------
# Native IPv6 prefix detection. We share the carrier /64 with the LAN (same as
# Android hotspot) instead of using NAT66. Only /64 is handled:
#   rmnet_dataX: 2001:db8:1234:5678:..../64
#   LAN eth0:    2001:db8:1234:5678::1/64 + RA
# ------------------------------------------------------------------------------
V6_CIDR=""
V6_NET=""
V6_LAN_ADDR=""
V6_CIDR=$(ip -6 addr show dev "$RMNET_IF" scope global 2>/dev/null | awk '/inet6/ {print $2; exit}')
if [ -n "$V6_CIDR" ]; then
    V6_PLEN=${V6_CIDR#*/}
    V6_ADDR=${V6_CIDR%/*}
    if [ "$V6_PLEN" = "64" ]; then
        V6_BASE=$(echo "$V6_ADDR" | cut -d: -f1-4)
        case "$V6_BASE" in
            *::*|'') : ;;
            *) V6_NET="${V6_BASE}::/64"; V6_LAN_ADDR="${V6_BASE}::1" ;;
        esac
    fi
fi
[ -n "$V6_NET" ] && log "Native IPv6 prefix: $V6_NET (no NAT66)" || log "WARN: no global /64 on $RMNET_IF; IPv6 LAN disabled"

# ------------------------------------------------------------------------------
# Find the USB NIC.
# ------------------------------------------------------------------------------
if ! ip link show "$LAN_IF" >/dev/null 2>&1; then
    for iface in eth0 usb0 eth1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            LAN_IF="$iface"
            break
        fi
    done
fi
if ip link show "$LAN_IF" >/dev/null 2>&1; then
    log "LAN NIC: $LAN_IF"
else
    log "WARN: LAN NIC $LAN_IF not present; plug the Type-C dock/2.5G adapter"
fi

# ------------------------------------------------------------------------------
# Stop a previous container if present.
# ------------------------------------------------------------------------------
if [ -f "$RUN_DIR/container.pid" ]; then
    OLD_PID=$(cat "$RUN_DIR/container.pid")
    if [ -d "/proc/$OLD_PID" ]; then
        log "Stopping previous container PID $OLD_PID"
        kill -TERM "$OLD_PID" 2>/dev/null
        sleep 2
        kill -KILL "$OLD_PID" 2>/dev/null
    fi
    rm -f "$RUN_DIR/container.pid"
fi

# The old container owned eth0; once it is gone the NIC is back in the host
# netns, so re-detect the LAN interface before moving it.
if ! ip link show "$LAN_IF" >/dev/null 2>&1; then
    for iface in eth0 usb0 eth1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            LAN_IF="$iface"
            break
        fi
    done
fi

# ------------------------------------------------------------------------------
# Namespace flags. Mount/UTS/net exist on the stock kernel; PID/IPC appear only
# after the custom kernel is flashed.
# ------------------------------------------------------------------------------
UNSHARE="$BB unshare"
if [ ! -x "$BB" ]; then
    UNSHARE="unshare"
fi

if ! $UNSHARE -p -f true 2>/dev/null; then
    log "ERROR: kernel lacks CONFIG_PID_NS; refusing to run /sbin/init in host PID namespace!"
    exit 1
fi

NS_FLAGS="-m -u -n -p -f"
if $UNSHARE -i true 2>/dev/null; then
    NS_FLAGS="-m -u -n -i -p -f"
fi
log "unshare flags: $NS_FLAGS"

# ------------------------------------------------------------------------------
# Start the container. With -p -f, unshare forks a child that becomes PID 1 in
# the new PID namespace, so mounting proc inside gives an isolated /proc and
# procd can never signal Android host processes.
# ------------------------------------------------------------------------------
mkdir -p "$ROOTFS/tmp/run" "$ROOTFS/tmp/lock"

$UNSHARE $NS_FLAGS /system/bin/sh -c '
    ROOTFS="$1"
    mount --make-rslave / 2>/dev/null
    mount -t proc proc "$ROOTFS/proc" 2>/dev/null
    mount --bind /dev "$ROOTFS/dev" 2>/dev/null
    mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null
    mount --bind /sys "$ROOTFS/sys" 2>/dev/null
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    exec /system/bin/chroot "$ROOTFS" /sbin/init
' sh "$ROOTFS" </dev/null >$LOG_DIR/init.log 2>&1 &
UNSHARE_PID=$!
sleep 3
CONTAINER_PID=$(ps -A -o PID,PPID 2>/dev/null | awk -v p="$UNSHARE_PID" '$2==p {print $1; exit}')
[ -n "$CONTAINER_PID" ] || CONTAINER_PID="$UNSHARE_PID"
echo "$CONTAINER_PID" > "$RUN_DIR/container.pid"
log "unshare wrapper PID: $UNSHARE_PID, container init PID: $CONTAINER_PID"
[ -d "/proc/$CONTAINER_PID" ] || { log "ERROR: container exited; check $LOG_DIR/init.log"; exit 1; }

# ------------------------------------------------------------------------------
# Move the physical LAN NIC into the container netns.
# ------------------------------------------------------------------------------
if ip link show "$LAN_IF" >/dev/null 2>&1; then
    ip link set "$LAN_IF" down 2>/dev/null
    if ! $BB_IP link set "$LAN_IF" netns "$CONTAINER_PID"; then
        log "ERROR: failed to move $LAN_IF into container netns"
        exit 1
    fi
    log "moved $LAN_IF -> container"
else
    log "WARN: $LAN_IF disappeared before move"
fi

# ------------------------------------------------------------------------------
# Create the veth WAN pair.
# ------------------------------------------------------------------------------
ip link del "$VETH_HOST" 2>/dev/null
if ! ip link add "$VETH_HOST" type veth peer name "$VETH_OWRT" 2>/dev/null; then
    if ! $BB_IP link add "$VETH_HOST" type veth peer name "$VETH_OWRT"; then
        log "ERROR: failed to create veth pair"
        exit 1
    fi
fi
if ! $BB_IP link set "$VETH_OWRT" netns "$CONTAINER_PID"; then
    log "ERROR: failed to move $VETH_OWRT into container netns"
    exit 1
fi

ip addr flush dev "$VETH_HOST" 2>/dev/null
ip addr add "$HOST_IP/30" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

# ------------------------------------------------------------------------------
# Configure the container side.
# ------------------------------------------------------------------------------
# Android 14 toybox nsenter resolves -t PID to /proc/0 and fails.
# Magisk BusyBox nsenter works; prefer it.
NSENTER="$BB nsenter"
if [ ! -x "$BB" ]; then
    NSENTER="nsenter"
fi

$NSENTER -t "$CONTAINER_PID" -n -- ip link set lo up
$NSENTER -t "$CONTAINER_PID" -n -- ip link set "$VETH_OWRT" up
$NSENTER -t "$CONTAINER_PID" -n -- ip addr add "$OWRT_IP/30" dev "$VETH_OWRT" 2>/dev/null
$NSENTER -t "$CONTAINER_PID" -n -- ip route replace default via "$HOST_IP" dev "$VETH_OWRT"

# Normalize the USB NIC name to eth0 inside the container.
$NSENTER -t "$CONTAINER_PID" -n -- ip link set "$LAN_IF" down 2>/dev/null
$NSENTER -t "$CONTAINER_PID" -n -- "$BB" ip link set "$LAN_IF" name eth0 2>/dev/null
$NSENTER -t "$CONTAINER_PID" -n -- ip link set eth0 up 2>/dev/null

owrt_exec() {
    $NSENTER -t "$CONTAINER_PID" -m -u -n -p -- /system/bin/chroot "$ROOTFS" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
}

# Let procd settle, then reload network/firewall/dnsmasq so they see the
# interfaces that appeared after init started.
sleep 2
owrt_exec "/etc/init.d/network reload" 2>/dev/null
owrt_exec "/etc/init.d/firewall reload" 2>/dev/null
owrt_exec "/etc/init.d/dnsmasq restart" 2>/dev/null
# netifd applies 'network reload' asynchronously; let it settle before the
# IPv6 LAN address is added, otherwise it gets flushed again.
sleep 2

# Native IPv6: the LAN address, /64 route and odhcpd/dnsmasq restarts are done
# in the host-forwarding block below, after netifd's reload has settled.
# (Adding them here got flushed by the asynchronous 'network reload'.)

# ------------------------------------------------------------------------------
# Host forwarding.
# ------------------------------------------------------------------------------
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null
echo 0 > "/proc/sys/net/ipv4/conf/$VETH_HOST/rp_filter" 2>/dev/null
echo 0 > "/proc/sys/net/ipv4/conf/$RMNET_IF/rp_filter" 2>/dev/null

# Native IPv6 forwarding: packets arriving from the 5G interface for the LAN /64
# go to veth-host (table 200), not back out the 5G interface. Packets to the
# host's own address in the /64 are caught by the local table (rule 0) first.
if [ -n "$V6_NET" ]; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    echo 1 > "/proc/sys/net/ipv6/conf/$RMNET_IF/forwarding" 2>/dev/null
    echo 1 > "/proc/sys/net/ipv6/conf/$VETH_HOST/forwarding" 2>/dev/null
    ip -6 addr add fe80::1/64 dev "$VETH_HOST" 2>/dev/null
    # The container's default route needs the host-side fe80::1 to exist first.
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace default via fe80::1 dev "$VETH_OWRT"
    # netifd has settled by now, so these addresses are no longer flushed.
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add "$V6_LAN_ADDR/64" dev eth0 2>/dev/null
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add fe80::2/64 dev "$VETH_OWRT" 2>/dev/null
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace "$V6_NET" dev eth0
    log "IPv6 LAN: $V6_LAN_ADDR/64 on eth0"
    ip -6 route replace "$V6_NET" dev "$VETH_HOST" table 200
    ip -6 rule del iif "$RMNET_IF" lookup 200 2>/dev/null
    ip -6 rule add iif "$RMNET_IF" lookup 200 pref 1000

    # Keep container/LAN IPv6 on the 5G link even if Wi-Fi is still the
    # default route (we use Wi-Fi for adb while testing).
    V6_GW=$(ip -6 route show default table "$RMNET_IF" 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -n "$V6_GW" ]; then
        ip -6 route replace default via "$V6_GW" dev "$RMNET_IF" table 201
        ip -6 rule del from "$V6_NET" lookup 201 2>/dev/null
        ip -6 rule add from "$V6_NET" lookup 201 pref 1001
    fi
    owrt_exec "/etc/init.d/dnsmasq restart" 2>/dev/null
    owrt_exec "/etc/init.d/odhcpd restart" 2>/dev/null
fi

# ------------------------------------------------------------------------------
# Build a dedicated IPv4 table for the 5G WAN. Android's per-network tables are
# numeric and not guaranteed to be named after the interface, so never use
# 'lookup $RMNET_IF' (that is an interface name, not a routing table name).
# ------------------------------------------------------------------------------
RMNET_GW=$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
if [ -z "$RMNET_GW" ]; then
    RMNET_GW=$(ip route show table "$RMNET_IF" 2>/dev/null | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
fi
if [ -n "$RMNET_GW" ]; then
    ip route replace default via "$RMNET_GW" dev "$RMNET_IF" table "$TABLE_ID"
else
    ip route replace default dev "$RMNET_IF" table "$TABLE_ID"
fi
# Keep the veth subnet on-link inside table 100; otherwise locally generated
# replies to the container (source 10.200.1.1) follow the 5G default route.
ip route replace "$HOST_NET" dev "$VETH_HOST" table "$TABLE_ID"

ip rule del pref 100 2>/dev/null
ip rule del pref 101 2>/dev/null
ip rule add from "$HOST_NET" lookup "$TABLE_ID" pref 100
ip rule add iif "$RMNET_IF" to "$HOST_NET" lookup main pref 101
# Host-originated traffic to the container's veth subnet must use the main
# table's on-link route instead of the 5G default.  Needed for phone-browser
# LuCI at http://10.200.1.2/ and for host-side SSH to the container.
ip rule del pref 90 2>/dev/null
ip rule add to "$HOST_NET" lookup main pref 90

# IPv6: configured in the host-forwarding block above via native /64 sharing.
# Do not add NAT66 here.

# ------------------------------------------------------------------------------
# Host NAT. Stock kernel has no nftables; prefer iptables-legacy.
# ------------------------------------------------------------------------------
IPT="iptables"
if command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
fi
if ! $IPT -t nat -L >/dev/null 2>&1; then
    if command -v iptables-legacy >/dev/null 2>&1; then
        IPT="iptables-legacy"
    else
        log "ERROR: no working iptables binary"
        exit 1
    fi
fi
log "iptables: $IPT"

$IPT -t nat -D POSTROUTING -s "$HOST_NET" -o "$RMNET_IF" -j MASQUERADE 2>/dev/null
$IPT -t nat -I POSTROUTING -s "$HOST_NET" -o "$RMNET_IF" -j MASQUERADE
$IPT -D FORWARD -i "$VETH_HOST" -o "$RMNET_IF" -j ACCEPT 2>/dev/null
$IPT -I FORWARD -i "$VETH_HOST" -o "$RMNET_IF" -j ACCEPT
$IPT -D FORWARD -i "$RMNET_IF" -o "$VETH_HOST" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
$IPT -I FORWARD -i "$RMNET_IF" -o "$VETH_HOST" -m state --state RELATED,ESTABLISHED -j ACCEPT

# IPv6 NAT66 is deliberately NOT used.
# The phone is a single UE; if the carrier gives a /64, the correct approach is
# NDP proxy / prefix sharing so LAN clients get native addresses.
# See IPV6_NOTES.md.

log "OpenWrt started."
log "  LAN: http://192.168.2.1"
log "  WAN: $RMNET_IF (IPv4)"
log "  IPv6: ${V6_NET:-disabled} (native /64, no NAT66)"
