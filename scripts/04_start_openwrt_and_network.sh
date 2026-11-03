#!/system/bin/sh
# Android's toybox ip is required for named veth pairs and netns operations.
# Magisk's PATH can put BusyBox ip first, which silently fails to create the
# peer; keep toybox first and call BusyBox only via $BB.
export PATH=/system/bin:/system/xbin:$PATH
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
CONTAINER_STARTED=0
LOCK_DIR="$RUN_DIR/04.lock.d"
LOCK_HELD=0

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Find the active 5G interface.  The system default route may be Wi-Fi, so check
# each rmnet interface for an IPv4 address and its own default table.
find_rmnet_wan() {
    # Find the first IPv4 default route whose device is an rmnet interface.
    # This is more reliable than probing per-interface tables, which can be
    # temporarily empty while Android reconnects the PDN.
    dev=$(ip -4 route show table all 2>/dev/null | awk '/^default/ {
        d="";
        for (i=1;i<=NF;i++) if ($i=="dev") { d=$(i+1); break }
        if (d ~ /^rmnet/) { print d; exit }
    }')
    if [ -n "$dev" ]; then
        echo "$dev"
        return 0
    fi
    for iface in rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 rmnet_data4 rmnet_data5 rmnet0 v4-rmnet_data0; do
        ip -4 addr show "$iface" 2>/dev/null | grep -q 'inet ' || continue
        ip route show table "$iface" 2>/dev/null | grep -q '^default' || continue
        echo "$iface"
        return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# Kill every process that belongs to the OpenWrt container.  PID files are not
# enough: a failed startup leaves the PID-namespace init and its children alive,
# and killing only the unshare wrapper does not tear the namespace down.
#
# Killing the namespace init (procd) makes the kernel terminate every other
# process in that PID namespace, so we only inspect procd + wrapper PIDs instead
# of spawning readlink/cat for every process on the phone (that took minutes).
# ------------------------------------------------------------------------------
kill_container_tree() {
    sig="$1"
    list=""

    for pid in $(ps -A -o PID,NAME 2>/dev/null | awk '$2=="procd" {print $1}'); do
        [ "$pid" = "$$" ] && continue
        root=$(readlink "/proc/$pid/root" 2>/dev/null) || continue
        case "$root" in
            "$ROOTFS"|"$ROOTFS"/*) list="$list $pid" ;;
        esac
    done

    # The unshare/chroot wrappers keep the host root, so match their cmdline.
    for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep -E "unshare.*$ROOTFS|chroot.*$ROOTFS" | grep -v grep | awk '{print $1}'); do
        [ "$pid" = "$$" ] && continue
        list="$list $pid"
    done

    if [ -n "$list" ]; then
        log "killing container processes (-$sig): $(echo $list | wc -w)"
        kill "-$sig" $list 2>/dev/null
    fi
}

# Slow fallback for an abnormal state where the namespace init is already gone
# but some chrooted process survived.  Only used when the fast path leaves
# processes behind.
kill_container_rootfs_fallback() {
    sig="$1"
    list=""
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        root=$(readlink "$p/root" 2>/dev/null) || continue
        case "$root" in
            "$ROOTFS"|"$ROOTFS"/*) list="$list $pid" ;;
        esac
    done
    if [ -n "$list" ]; then
        log "fallback killing rootfs processes (-$sig): $(echo $list | wc -w)"
        kill "-$sig" $list 2>/dev/null
    fi
}

cleanup_old_container() {
    if [ -f "$RUN_DIR/container.pid" ]; then
        log "Stopping previous container (pid file: $(cat "$RUN_DIR/container.pid" 2>/dev/null))"
    fi
    kill_container_tree TERM
    sleep 2
    kill_container_tree KILL
    sleep 1
    rm -f "$RUN_DIR/container.pid"
    # Remove stale veth pairs from earlier failed attempts.  The toybox/busybox
    # split is important: toybox creates a correct pair only with "name ...".
    for v in "$VETH_HOST" veth0 veth1; do
        ip link show "$v" >/dev/null 2>&1 && ip link del "$v" 2>/dev/null
    done
}

cleanup_on_exit() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$CONTAINER_STARTED" = "1" ]; then
        log "ERROR: container startup failed; cleaning up leaked processes"
        kill_container_tree TERM
        sleep 2
        kill_container_tree KILL
        rm -f "$RUN_DIR/container.pid"
    fi
    [ "$LOCK_HELD" = "1" ] && rm -rf "$LOCK_DIR"
}
trap cleanup_on_exit EXIT

[ -d "$ROOTFS" ] || { log "ERROR: $ROOTFS not found; run 03_setup_openwrt_rootfs.sh first"; exit 1; }
mkdir -p "$STATE_DIR" "$RUN_DIR" "$LOG_DIR"

# Serialize 04: autorun, a manual run, or a stale watchdog must never create
# veth pairs/containers at the same time.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ] && [ "$old" != "$$" ]; then
        log "another 04 instance is running (pid $old); exiting"
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { log "ERROR: cannot acquire 04 lock"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
LOCK_HELD=1

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

# Kill any previous/leaked container before doing anything else.  The old netns
# may still own eth0, and stale veth pairs break the next startup.
cleanup_old_container

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
        RMNET_IF=$(find_rmnet_wan)
        ;;
esac
# The PDN can flap while Android reconnects; give it a short grace period.
if [ -z "$RMNET_IF" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        RMNET_IF=$(find_rmnet_wan)
        [ -n "$RMNET_IF" ] && break
        sleep 2
    done
fi
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

# Wait for the PID-namespace init instead of racing a fixed sleep.  Using the
# wrapper PID as container PID leaves the real init alive when startup fails.
CONTAINER_PID=""
i=0
while [ $i -lt 20 ]; do
    CONTAINER_PID=$(ps -A -o PID,PPID 2>/dev/null | awk -v p="$UNSHARE_PID" '$2==p {print $1; exit}')
    [ -n "$CONTAINER_PID" ] && break
    sleep 1
    i=$((i+1))
done
if [ -z "$CONTAINER_PID" ]; then
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        root=$(readlink "$p/root" 2>/dev/null) || continue
        case "$root" in
            "$ROOTFS"|"$ROOTFS"/*) CONTAINER_PID="$pid"; break ;;
        esac
    done
fi
[ -n "$CONTAINER_PID" ] || { log "ERROR: container init not found; check $LOG_DIR/init.log"; exit 1; }
CONTAINER_STARTED=1
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
    log "WARN: $LAN_IF not present; starting WAN-only"
fi

# ------------------------------------------------------------------------------
# Create the veth WAN pair.
# Android toybox requires the explicit "name <if>" form for a named veth pair.
# BusyBox's ip returns success but does not create the peer on this build, so
# use toybox for creation and BusyBox only for the netns move.
# ------------------------------------------------------------------------------
ip link del "$VETH_HOST" 2>/dev/null
if ! ip link add name "$VETH_HOST" type veth peer name "$VETH_OWRT" 2>/dev/null; then
    log "ERROR: failed to create veth pair"
    exit 1
fi
if ! ip link show "$VETH_OWRT" >/dev/null 2>&1; then
    log "ERROR: veth peer $VETH_OWRT was not created"
    ip link del "$VETH_HOST" 2>/dev/null
    exit 1
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
    # Give the container side its link-local address before installing the
    # default route, otherwise the route can fail with "Network is unreachable".
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add fe80::2/64 dev "$VETH_OWRT" 2>/dev/null
    V6_DEFAULT_OK=0
    for i in 1 2 3 4 5; do
        if $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace default via fe80::1 dev "$VETH_OWRT" onlink 2>/dev/null; then
            V6_DEFAULT_OK=1
            break
        fi
        sleep 1
    done
    [ "$V6_DEFAULT_OK" = "1" ] || log "WARN: could not set container IPv6 default route"
    # netifd has settled by now, so these addresses are no longer flushed.
    if $NSENTER -t "$CONTAINER_PID" -n -- ip link show eth0 >/dev/null 2>&1; then
        $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add "$V6_LAN_ADDR/64" dev eth0 2>/dev/null
        $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace "$V6_NET" dev eth0 2>/dev/null
        log "IPv6 LAN: $V6_LAN_ADDR/64 on eth0"
    else
        log "WARN: LAN NIC not in container; IPv6 LAN address skipped"
    fi
    ip -6 route replace "$V6_NET" dev "$VETH_HOST" table 200 2>/dev/null \
        || log "WARN: could not add IPv6 route table 200"
    ip -6 rule del iif "$RMNET_IF" lookup 200 2>/dev/null
    ip -6 rule add iif "$RMNET_IF" lookup 200 pref 1000

    # Keep container/LAN IPv6 on the 5G link even if Wi-Fi is still the
    # default route (we use Wi-Fi for adb while testing).
    V6_GW=$(ip -6 route show default table "$RMNET_IF" 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -n "$V6_GW" ]; then
        ip -6 route replace default via "$V6_GW" dev "$RMNET_IF" table 201 2>/dev/null
        ip -6 rule del from "$V6_NET" lookup 201 2>/dev/null
        ip -6 rule add from "$V6_NET" lookup 201 pref 1001
    fi
    owrt_exec "/etc/init.d/dnsmasq restart" 2>/dev/null
    owrt_exec "/etc/init.d/odhcpd restart" 2>/dev/null
fi

# ------------------------------------------------------------------------------
# Build a dedicated IPv4 table for the 5G WAN.  Android's per-network tables
# are normally named after the interface on this build, but we still fall back
# to route lookup / default-device probing.
# ------------------------------------------------------------------------------
RMNET_GW=$(ip route get 8.8.8.8 oif "$RMNET_IF" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
if [ -z "$RMNET_GW" ]; then
    RMNET_GW=$(ip route show table "$RMNET_IF" 2>/dev/null | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
fi
if [ -z "$RMNET_GW" ]; then
    RMNET_GW=$(ip route show default dev "$RMNET_IF" 2>/dev/null | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
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

# Final IPv6 re-assert.  netifd/odhcpd can flush routes and LAN addresses after
# the asynchronous reload above, so put them back once more at the very end.
if [ -n "$V6_NET" ]; then
    ip -6 addr add fe80::1/64 dev "$VETH_HOST" 2>/dev/null
    $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add fe80::2/64 dev "$VETH_OWRT" 2>/dev/null
    V6_DEFAULT_OK=0
    for i in 1 2 3 4 5; do
        if $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace default via fe80::1 dev "$VETH_OWRT" onlink 2>/dev/null; then
            V6_DEFAULT_OK=1
            break
        fi
        sleep 1
    done
    [ "$V6_DEFAULT_OK" = "1" ] || log "WARN: IPv6 default route still missing"
    if $NSENTER -t "$CONTAINER_PID" -n -- ip link show eth0 >/dev/null 2>&1; then
        $NSENTER -t "$CONTAINER_PID" -n -- ip -6 addr add "$V6_LAN_ADDR/64" dev eth0 2>/dev/null
        $NSENTER -t "$CONTAINER_PID" -n -- ip -6 route replace "$V6_NET" dev eth0 2>/dev/null
    fi
    ip -6 route replace "$V6_NET" dev "$VETH_HOST" table 200 2>/dev/null
    owrt_exec "/etc/init.d/odhcpd restart" 2>/dev/null
fi

# Final RTC mask: OpenWrt's preinit (and network reload) can mount devtmpfs over
# /dev, so do this only after all init/reload work is finished.
owrt_exec "mount --bind /dev/null /dev/rtc0 2>/dev/null; mount --bind /dev/null /dev/rtc 2>/dev/null"

log "OpenWrt started."
log "  LAN: http://192.168.2.1"
log "  WAN: $RMNET_IF (IPv4)"
log "  IPv6: ${V6_NET:-disabled} (native /64, no NAT66)"
