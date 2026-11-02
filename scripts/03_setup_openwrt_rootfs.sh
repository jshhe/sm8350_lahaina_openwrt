#!/system/bin/sh
# ==============================================================================
# 03_setup_openwrt_rootfs.sh
# Deploy an OpenWrt arm64 rootfs into /data/openwrt/rootfs and adapt it for
# running on the OnePlus 9 Pro stock/custom Linux 5.4 kernel.
#
# Usage:
#   sh 03_setup_openwrt_rootfs.sh [rootfs.tar.gz]
#
# Supported rootfs (kernel has CONFIG_NF_TABLES=n):
#   openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz  (fw3 + iptables-legacy)
# 22.03+/23.05+ default to fw4/nftables and must have fw4 disabled.
# ==============================================================================

set -e

TAR_FILE="${1:-}"
DEST_DIR="/data/openwrt/rootfs"
MODDIR="/data/openwrt/scripts"

if [ -z "$TAR_FILE" ]; then
    for f in \
        /data/openwrt/images/openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz \
        /data/openwrt/images/openwrt-23.05.5-armsr-armv8-rootfs.tar.gz \
        /data/openwrt/images/openwrt-armsr-armv8-generic-rootfs.tar.gz \
        /sdcard/openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz \
        /sdcard/openwrt-23.05.5-armsr-armv8-rootfs.tar.gz \
        /sdcard/openwrt-armsr-armv8-generic-rootfs.tar.gz; do
        if [ -f "$f" ]; then
            TAR_FILE="$f"
            break
        fi
    done
fi

if [ -z "$TAR_FILE" ] || [ ! -f "$TAR_FILE" ]; then
    echo "[!] No rootfs tarball found."
    echo "    Put one of these in /data/openwrt/images/ and rerun:"
    echo "      openwrt-21.02.7-armvirt-64-default-rootfs.tar.gz  (recommended: fw3 + iptables-legacy)"
    echo "      openwrt-23.05.5-armsr-armv8-rootfs.tar.gz         (requires fw4 disabled)"
    exit 1
fi

echo "[1/5] Preparing $DEST_DIR ..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR" "$MODDIR"

echo "[2/5] Extracting $TAR_FILE ..."
tar -xzpf "$TAR_FILE" -C "$DEST_DIR"
sync

# Detect the OpenWrt release.
OWRT_VERSION="unknown"
if [ -f "$DEST_DIR/etc/openwrt_release" ]; then
    . "$DEST_DIR/etc/openwrt_release" 2>/dev/null || true
    OWRT_VERSION="${DISTRIB_RELEASE:-unknown}"
fi
echo "       OpenWrt release: $OWRT_VERSION"

# OpenWrt 21.02/22.03 use 'option ifname'; 23.05+ use 'option device'.
USE_DEVICE=1
case "$OWRT_VERSION" in
    21.*|22.*) USE_DEVICE=0 ;;
esac

if [ "$USE_DEVICE" = "1" ]; then
    LAN_OPT="option device 'eth0'"
    WAN_OPT="option device 'veth-owrt'"
else
    LAN_OPT="option ifname 'eth0'"
    WAN_OPT="option ifname 'veth-owrt'"
fi

echo "[3/5] Installing compatibility shims ..."
# OpenWrt's sbin/modprobe is an absolute symlink to /sbin/kmodloader.
# Remove it first; otherwise 'cat >' follows a non-existent host path.
rm -f "$DEST_DIR/sbin/modprobe"
cat > "$DEST_DIR/sbin/modprobe" <<'EOF'
#!/bin/sh
# OpenWrt kmodloader shim: the required netfilter/veth drivers are built into
# the OnePlus 9 Pro kernel, so there is nothing to load.
exit 0
EOF
chmod 755 "$DEST_DIR/sbin/modprobe"

# BusyBox mktemp in this rootfs has no default template: `mktemp -d` leaves
# tdir empty, and OpenWrt's dropbear init then executes
#     mv -f "${tdir}/"* /etc/dropbear/
# which moves the entire rootfs (bin/lib/sbin/usr/www) into /etc/dropbear.
# Force a template and guard the mv before the container ever starts.
DB="$DEST_DIR/etc/init.d/dropbear"
if [ -f "$DB" ]; then
    sed -i 's|tdir=$(mktemp -d); chmod 0700 "${tdir}"|tdir=$(mktemp -d /tmp/dropbear.XXXXXX) \|\| return 0; chmod 0700 "${tdir}"|' "$DB"
    sed -i 's|mv -f "${tdir}/"\* "${kdir}/"|[ -n "${tdir}" ] \&\& mv -f "${tdir}/"* "${kdir}/"|' "$DB"
    grep -q 'mktemp -d /tmp/dropbear.XXXXXX' "$DB" || {
        echo "[!] dropbear mktemp patch failed"
        exit 1
    }
fi

KVER=$(uname -r)
mkdir -p "$DEST_DIR/lib/modules/$KVER"
: > "$DEST_DIR/lib/modules/$KVER/modules.dep"
: > "$DEST_DIR/lib/modules/$KVER/modules.builtin"
: > "$DEST_DIR/lib/modules/$KVER/modules.alias"

mkdir -p "$DEST_DIR/dev" "$DEST_DIR/dev/pts" "$DEST_DIR/proc" "$DEST_DIR/sys" "$DEST_DIR/tmp"

echo "[4/5] Writing network/firewall/dhcp config ..."
cat > "$DEST_DIR/etc/config/network" <<EOF
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config interface 'lan'
    $LAN_OPT
    option proto 'static'
    option ipaddr '192.168.2.1'
    option netmask '255.255.255.0'

config interface 'wan'
    $WAN_OPT
    option proto 'static'
    option ipaddr '10.200.1.2'
    option netmask '255.255.255.252'
    option gateway '10.200.1.1'
    list dns '223.5.5.5'
    list dns '119.29.29.29'

# IPv6: no static ULA and no NAT66 here.
# Native IPv6 (carrier /64 + RA) is configured dynamically by 04; see IPV6_NOTES.md.
EOF

cat > "$DEST_DIR/etc/config/firewall" <<'EOF'
config defaults
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option syn_flood '1'

config zone
    option name 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    list network 'lan'

config zone
    option name 'wan'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'
    list network 'wan'

config forwarding
    option src 'lan'
    option dest 'wan'
EOF

# Allow the Android host (10.200.1.1) to reach LuCI/SSH on the veth WAN.
cat >> "$DEST_DIR/etc/config/firewall" <<'EOF'

config rule
    option name 'Allow-Host-UI'
    option src 'wan'
    option src_ip '10.200.1.1'
    option proto 'tcp'
    option dest_port '80 443'
    option target 'ACCEPT'
EOF

# Host access arrives from an RFC1918 source on the veth, so disable the
# uhttpd RFC1918 filter (the firewall still restricts it to 10.200.1.1).
if [ -f "$DEST_DIR/etc/config/uhttpd" ]; then
    sed -i "s/option rfc1918_filter '1'/option rfc1918_filter '0'/" "$DEST_DIR/etc/config/uhttpd"
fi

cat > "$DEST_DIR/etc/config/dhcp" <<'EOF'
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option rebind_protection '1'
    option rebind_localhost '1'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option nonegcache '0'
    option authoritative '1'
    option readethers '1'
    option leasefile '/tmp/dhcp.leases'
    option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
    option nonwildcard '1'
    option localservice '1'
    option ednspacket_max '1232'

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv4 'server'
    option ra 'server'
    option dhcpv6 'server'
    option ra_management '1'
    option ra_default '1'
    option ra_dns '1'

config dhcp 'wan'
    option interface 'wan'
    option ignore '1'
EOF

echo "[5/5] Done."
echo "       Rootfs: $DEST_DIR"
echo "       OpenWrt: $OWRT_VERSION"
if [ "$USE_DEVICE" = "1" ]; then
    echo "       netifd syntax: option device"
else
    echo "       netifd syntax: option ifname"
fi
