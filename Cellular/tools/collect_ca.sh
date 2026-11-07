#!/system/bin/sh
# collect_ca.sh - log telephony CA / band / signal state on-device.
#
# Xiaomi (adb-only, via Shizuku/Termux):
#   rish -c "sh /sdcard/Download/collect_ca.sh"
#
# OnePlus (root):
#   su -c "sh /sdcard/Download/collect_ca.sh"
#
# Stop with Ctrl-C. Output:
#   /sdcard/Download/ca_YYYYmmdd_HHMMSS.log
#
# The log is a sequence of blocks. Each block contains the current
# mSignalStrength / mCellIdentity / mCellInfo / mPhysicalChannelConfigs /
# mServiceState / mTelephonyDisplayInfo lines from telephony.registry.

OUT="/sdcard/Download/ca_$(date +%Y%m%d_%H%M%S).log"
echo "# start $(date)" > "$OUT"
echo "# device: $(getprop ro.product.model) $(getprop ro.build.display.id)" >> "$OUT"
echo "# kernel: $(uname -r)" >> "$OUT"

while true; do
    echo "===== $(date +%Y-%m-%dT%H:%M:%S) =====" >> "$OUT"
    dumpsys telephony.registry \
        | grep -E 'mSignalStrength=|mCellIdentity=|mCellInfo=|mPhysicalChannelConfigs=|mServiceState=|mTelephonyDisplayInfo=|mDataConnectionState=|mDataActivity=' \
        | head -n 24 >> "$OUT"
    sleep 2
done
