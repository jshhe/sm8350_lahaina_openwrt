#!/system/bin/sh
# Magisk runs service.d scripts in BusyBox ash standalone mode (ASH_STANDALONE=1),
# which forces bare commands (ps, ip, sh, awk) to BusyBox applets and ignores PATH.
# Re-exec under Android's mksh so toybox ip and ps behave normally.
if [ -n "$ASH_STANDALONE" ]; then
    unset ASH_STANDALONE
    exec /system/bin/sh "$0" "$@"
fi
# ==============================================================================
# service_openwrt_autorun.sh
# Magisk late_start service: bring up the OpenWrt 5G router container on boot
# and keep it alive.
#
# Install:
#   adb push service_openwrt_autorun.sh /data/local/tmp/
#   adb shell su -c "mv /data/local/tmp/service_openwrt_autorun.sh /data/openwrt/scripts/"
#   adb shell su -c "chmod 755 /data/openwrt/scripts/service_openwrt_autorun.sh"
# Magisk entry: /data/adb/service.d/00_openwrt.sh ->
#   #!/system/bin/sh
#   unset ASH_STANDALONE
#   exec /system/bin/sh /data/openwrt/scripts/service_openwrt_autorun.sh
#
# Disable without removing:
#   touch /data/openwrt/disable_autorun
# ==============================================================================
# Keep toybox first: BusyBox ip cannot create a named veth peer on this build.
# BusyBox applets are called explicitly through $BB instead.
export PATH=/system/bin:/system/xbin:$PATH

BB=/data/adb/magisk/busybox
LOG=/data/openwrt/logs/autorun.log
PIDFILE=/data/openwrt/run/container.pid
mkdir -p /data/openwrt/logs /data/openwrt/run

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

container_running() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    # PID reuse guard: the init's root must be the OpenWrt rootfs.
    root=$($BB readlink "/proc/$pid/root" 2>/dev/null)
    case "$root" in
        *openwrt/rootfs*) return 0 ;;
    esac
    return 1
}

container_has_lan() {
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    $BB nsenter -t "$pid" -n ip link show eth0 >/dev/null 2>&1
}

ensure_container_fw() {
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 0
    if ! $BB nsenter -t "$pid" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c \
        'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; iptables -t nat -S zone_wan_postrouting 2>/dev/null | grep -q MASQUERADE && iptables -S zone_wan_input >/dev/null 2>&1'; then
        log "container fw3 rules incomplete; restarting firewall"
        $BB nsenter -t "$pid" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c \
            'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /etc/init.d/firewall restart' >/dev/null 2>&1
    fi
}

host_has_lan() {
    for iface in eth0 usb0 eth1; do
        ip link show "$iface" >/dev/null 2>&1 && return 0
    done
    return 1
}

usb_host_has_devices() {
    for d in /sys/bus/usb/devices/2-[1-9]* /sys/bus/usb/devices/3-[1-9]*; do
        [ -f "$d/idVendor" ] && return 0
    done
    return 1
}

usb_host_has_usb3() {
    for d in /sys/bus/usb/devices/3-[1-9]*; do
        [ -f "$d/idVendor" ] && return 0
    done
    return 1
}

USB_PROBE_SKIP=0
USB_LAST_SIG=""

# Recover USB host mode (preferring USB 3.0 SuperSpeed 5 Gbps via lane A/B
# orientation override) when a powered Type-C hub/dock is attached.
# Never touches mode=peripheral (wired PC USB cable).
ensure_usb_host_mode() {
    host_has_lan && return 0
    mode_f="/sys/devices/platform/soc/a600000.ssusb/mode"
    orient_f="/sys/devices/platform/soc/a600000.ssusb/orientation"
    otg_sw="/sys/class/oplus_chg/usb/otg_switch"
    otg_on="/sys/class/oplus_chg/usb/otg_online"
    role_f="/sys/class/typec/port0/data_role"
    usb_type_f="/sys/class/power_supply/usb/type"
    warp_dis_f="/sys/module/oplus_chg/parameters/disable_warp_probe"
    mmi_f="/sys/class/oplus_chg/battery/mmi_charging_enable"
    cap_f="/sys/class/oplus_chg/battery/capacity"

    [ -r "$mode_f" ] || return 0
    mode=$(cat "$mode_f" 2>/dev/null)
    case "$mode" in
        none) ;;
        host)
            usb_host_has_devices && return 0
            ;;
        *)
            USB_PROBE_SKIP=0
            return 0
            ;;
    esac

    if [ -w "$otg_sw" ] && [ "$(cat "$otg_sw" 2>/dev/null)" != "1" ]; then
        echo 1 > "$otg_sw" 2>/dev/null
    fi

    online=$(cat "$otg_on" 2>/dev/null)
    role=$(cat "$role_f" 2>/dev/null)
    utype=$(cat "$usb_type_f" 2>/dev/null)
    sig="${online}:${role}:${utype}"
    if [ "$sig" != "$USB_LAST_SIG" ]; then
        USB_LAST_SIG="$sig"
        USB_PROBE_SKIP=0
    fi
    case "$online" in
        ''|0) return 0 ;;
    esac
    trigger=0
    case "$role" in
        *'[host]'*) trigger=1 ;;
    esac
    [ "$utype" = "USB_DCP" ] && trigger=1
    [ "$trigger" = "1" ] || return 0

    if [ "$USB_PROBE_SKIP" -gt 0 ]; then
        USB_PROBE_SKIP=$((USB_PROBE_SKIP - 1))
        return 0
    fi

    log "Type-C dock detected (mode=$mode, otg_online=$online, role=$role, usb_type=$utype); recovering USB 3.0 host mode"
    old_mmi=$(cat "$mmi_f" 2>/dev/null)
    warp_dis=$(cat "$warp_dis_f" 2>/dev/null)
    if [ "$warp_dis" != "Y" ] && [ "$old_mmi" = "1" ] && [ -w "$mmi_f" ]; then
        echo 0 > "$mmi_f" 2>/dev/null
        sleep 1
    fi

    found_lan=0
    orient_cache="/data/openwrt/run/usb3_orient"
    cached_o=$(cat "$orient_cache" 2>/dev/null)
    case "$cached_o" in
        B) try_list="B A" ;;
        *) try_list="A B" ;;
    esac
    cur_m="$mode"
    for try_o in $try_list; do
        if [ "$cur_m" != "none" ]; then
            echo none > "$mode_f" 2>/dev/null
            sleep 2
        fi
        [ -w "$orient_f" ] && echo "$try_o" > "$orient_f" 2>/dev/null
        echo 1 > "$otg_sw" 2>/dev/null
        echo host > "$mode_f" 2>/dev/null || break
        cur_m="host"
        k=0
        while [ $k -lt 5 ]; do
            if host_has_lan; then
                found_lan=1
                if usb_host_has_usb3; then
                    echo "$try_o" > "$orient_cache" 2>/dev/null
                    log "USB 3.0 SuperSpeed active (orientation=$try_o)"
                    break 2
                fi
                break
            fi
            sleep 1
            k=$((k+1))
        done
    done

    if [ "$found_lan" != "1" ]; then
        # Plain charger without USB hub/NIC: restore idle state and back off 5 min (60 * 5s).
        echo none > "$mode_f" 2>/dev/null
        [ -w "$orient_f" ] && echo none > "$orient_f" 2>/dev/null
        USB_PROBE_SKIP=60
    fi
    if [ "$warp_dis" != "Y" ] && [ "$old_mmi" = "1" ]; then
        soc=$(cat "$cap_f" 2>/dev/null)
        [ -n "$soc" ] && [ "$soc" -le 50 ] 2>/dev/null && echo 1 > "$mmi_f" 2>/dev/null
    fi
}

# Hot-attach a newly enumerated host USB LAN NIC directly into the running
# OpenWrt container netns (~3-4s, avoids restarting procd or dropping 10.200.1.2).
attach_lan_inplace() {
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    lan=""
    for iface in eth0 usb0 eth1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            lan="$iface"
            break
        fi
    done
    [ -n "$lan" ] || return 1

    ip link set "$lan" down 2>/dev/null
    $BB ip link set "$lan" netns "$pid" || return 1
    if [ "$lan" != "eth0" ]; then
        $BB nsenter -t "$pid" -n -- "$BB" ip link set "$lan" name eth0 2>/dev/null || return 1
    fi
    $BB nsenter -t "$pid" -n -- ip link set eth0 up 2>/dev/null
    $BB nsenter -t "$pid" -n -- ip addr replace 192.168.2.1/24 dev eth0 2>/dev/null
    $BB nsenter -t "$pid" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c \
        'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /etc/init.d/network reload' >/dev/null 2>&1
    sleep 1
    $BB nsenter -t "$pid" -n -- ip link set eth0 up 2>/dev/null
    $BB nsenter -t "$pid" -n -- ip addr add 192.168.2.1/24 dev eth0 2>/dev/null

    # Re-apply native IPv6 /64 prefix from active 5G WAN if available.
    W=$(find_rmnet_wan)
    if [ -n "$W" ]; then
        v6_cidr=$(ip -6 addr show dev "$W" scope global 2>/dev/null | $BB awk '/inet6/ {print $2; exit}')
        if [ -n "$v6_cidr" ] && [ "${v6_cidr#*/}" = "64" ]; then
            v6_base=$(echo "${v6_cidr%/*}" | cut -d: -f1-4)
            case "$v6_base" in
                *::*|'') : ;;
                *)
                    v6_net="${v6_base}::/64"
                    v6_lan="${v6_base}::1"
                    ip -6 addr add fe80::1/64 dev veth-host 2>/dev/null
                    $BB nsenter -t "$pid" -n -- ip -6 addr add fe80::2/64 dev veth-owrt 2>/dev/null
                    $BB nsenter -t "$pid" -n -- ip -6 route replace default via fe80::1 dev veth-owrt onlink 2>/dev/null
                    $BB nsenter -t "$pid" -n -- ip -6 addr add "$v6_lan/64" dev eth0 2>/dev/null
                    $BB nsenter -t "$pid" -n -- ip -6 route replace "$v6_net" dev eth0 2>/dev/null
                    ip -6 route replace "$v6_net" via fe80::2 dev veth-host onlink table 200 2>/dev/null
                    ip -6 rule del iif "$W" lookup 200 2>/dev/null
                    ip -6 rule add iif "$W" lookup 200 pref 1000
                    v6_gw=$(ip -6 route show default table "$W" 2>/dev/null | $BB awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
                    if [ -n "$v6_gw" ]; then
                        ip -6 route replace default via "$v6_gw" dev "$W" table 201 2>/dev/null
                        ip -6 rule del from "$v6_net" lookup 201 2>/dev/null
                        ip -6 rule add from "$v6_net" lookup 201 pref 1001
                    fi
                    log "in-place IPv6 LAN: $v6_lan/64 on eth0"
                    ;;
            esac
        fi
    fi

    $BB nsenter -t "$pid" -m -u -n -p -- /system/bin/chroot /data/openwrt/rootfs /bin/sh -c \
        'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /etc/init.d/dnsmasq restart; /etc/init.d/odhcpd restart' >/dev/null 2>&1
    ensure_container_fw
    container_has_lan
}

# Find the active 5G interface.  Do not use the system default route: Wi-Fi may
# be the default while 5G still has its own per-network default table.
find_rmnet_wan() {
    dev=$(ip -4 route show table all 2>/dev/null | $BB awk '/^default/ {
        d="";
        for (i=1;i<=NF;i++) if ($i=="dev") { d=$(i+1); break }
        if (d ~ /^rmnet/) { print d; exit }
    }')
    if [ -n "$dev" ]; then
        echo "$dev"
        return 0
    fi
    for iface in rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 rmnet_data4 rmnet_data5; do
        ip -4 addr show "$iface" 2>/dev/null | grep -q 'inet ' || continue
        ip route show table "$iface" 2>/dev/null | grep -q '^default' || continue
        echo "$iface"
        return 0
    done
    return 1
}

# Android's netd resets ip_forward and the policy rules when the network
# changes (hotspot off, USB NIC plug, 5G reconnect).  Re-assert them.
ensure_wan() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || echo 1 > /proc/sys/net/ipv4/ip_forward
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = "1" ] || echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

    ip route show table 100 2>/dev/null | grep -q '10.200.1.0/30' || ip route replace 10.200.1.0/30 dev veth-host table 100

    W=$(ip route show table 100 2>/dev/null | $BB awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    case "$W" in
        rmnet*|v4-rmnet*)
            ip -4 addr show "$W" 2>/dev/null | grep -q 'inet ' || W=""
            ;;
        *) W="" ;;
    esac
    if [ -z "$W" ]; then
        W=$(find_rmnet_wan)
    fi
    case "$W" in
        rmnet*|v4-rmnet*)
            G=$(ip route get 8.8.8.8 oif "$W" 2>/dev/null | $BB awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
            [ -n "$G" ] || G=$(ip route show table "$W" 2>/dev/null | $BB awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
            if [ -n "$G" ]; then
                ip route replace default via "$G" dev "$W" table 100
            else
                ip route replace default dev "$W" table 100
            fi
            ip rule del pref 100 2>/dev/null
            ip rule del pref 101 2>/dev/null
            ip rule add from 10.200.1.0/30 lookup 100 pref 100
            ip rule add iif "$W" to 10.200.1.0/30 lookup main pref 101
            ip rule | grep -q 'to 10.200.1.0/30 lookup main' || ip rule add to 10.200.1.0/30 lookup main pref 90

            IPT="iptables"
            command -v iptables-legacy >/dev/null 2>&1 && IPT="iptables-legacy"
            $IPT -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s 10.200.1.0/30 -o $W -j MASQUERADE" \
                || $IPT -t nat -I POSTROUTING -s 10.200.1.0/30 -o "$W" -j MASQUERADE 2>/dev/null
            $IPT -S FORWARD 2>/dev/null | grep -q -- "-i veth-host -o $W -j ACCEPT" \
                || $IPT -I FORWARD -i veth-host -o "$W" -j ACCEPT 2>/dev/null
            $IPT -S FORWARD 2>/dev/null | grep -q -- "-i $W -o veth-host.*RELATED,ESTABLISHED.*ACCEPT" \
                || $IPT -I FORWARD -i "$W" -o veth-host -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
            ;;
    esac
}

# Keep cpu7 offline and the battery in the 50-60% band.
[ -f /data/openwrt/scripts/service_power_guard.sh ] && /system/bin/sh /data/openwrt/scripts/service_power_guard.sh

# Optional headless power tuning (only when explicitly enabled).
if [ -f "/data/openwrt/enable_headless" ] && [ -f "/data/openwrt/scripts/05_headless_power_control.sh" ]; then
    /system/bin/sh /data/openwrt/scripts/05_headless_power_control.sh > /data/openwrt/logs/power.log 2>&1
fi

# Wait for Android to finish booting.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
    sleep 2
    i=$((i+1))
done

# Wait for 5G data.  After a cold boot the modem/PDN can take over two minutes,
# and Wi-Fi may already be the system default route, so poll rmnet explicitly.
i=0
IF=""
while [ $i -lt 90 ]; do
    IF=$(find_rmnet_wan)
    [ -n "$IF" ] && break
    sleep 2
    i=$((i+1))
done
log "WAN interface: ${IF:-none}"

# Wait for the USB LAN NIC so the container gets its LAN port on first start.
ensure_usb_host_mode
i=0
while ! host_has_lan && [ $i -lt 15 ]; do
    ensure_usb_host_mode
    host_has_lan && break
    sleep 2
    i=$((i+1))
done

if container_running; then
    log "container already running, skip"
else
    log "starting OpenWrt container (WAN=${IF:-none})"
    /system/bin/sh /data/openwrt/scripts/04_start_openwrt_and_network.sh >> "$LOG" 2>&1
    log "04 exit=$?"
fi

ensure_wan

# Watchdog: fast 5s liveness + USB LAN hot-attach loop; heavier WAN/fw/power
# checks run every 6th tick (30s) to keep CPU/battery overhead minimal.
# Create /data/openwrt/disable_autorun to pause.
TICK=0
while true; do
    sleep 5
    [ -f /data/openwrt/disable_autorun ] && continue
    TICK=$((TICK + 1))

    if [ $((TICK % 6)) -eq 0 ]; then
        ensure_wan
        [ -f /data/openwrt/scripts/service_power_guard.sh ] && /system/bin/sh /data/openwrt/scripts/service_power_guard.sh
    fi

    if ! container_running; then
        log "container not running, restarting"
        /system/bin/sh /data/openwrt/scripts/04_start_openwrt_and_network.sh >> "$LOG" 2>&1
        log "04 exit=$?"
        ensure_wan
    elif ! container_has_lan; then
        ensure_usb_host_mode
        if host_has_lan; then
            log "USB LAN NIC appeared; hot-attaching in-place"
            if attach_lan_inplace; then
                log "in-place LAN attach succeeded"
                ensure_wan
            else
                log "in-place LAN attach failed; falling back to full 04 restart"
                /system/bin/sh /data/openwrt/scripts/04_start_openwrt_and_network.sh >> "$LOG" 2>&1
                log "04 exit=$?"
            fi
        fi
        [ $((TICK % 6)) -eq 0 ] && ensure_container_fw
    else
        [ $((TICK % 6)) -eq 0 ] && ensure_container_fw
    fi
done
