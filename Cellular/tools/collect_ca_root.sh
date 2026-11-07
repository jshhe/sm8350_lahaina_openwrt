#!/system/bin/sh
# collect_ca_root.sh - on-device CA / band / RSRP collector for rooted phones.
#
# Termux (root, no PC needed):
#   su -c "sh /sdcard/Download/collect_ca_root.sh"
#   su -c "timeout 900 sh /sdcard/Download/collect_ca_root.sh"
#
# Output:
#   /sdcard/Download/ca_root_YYYYmmdd_HHMMSS.log
#
# Every 2 s : telephony.registry snapshot (CA entries, band, PCI, ARFCN, RSRP)
# Every 10 s: full qmi_nas_test output (Serving System + RF Band Information)
# Every 30 s: battery level / temperature (the 888 throttles 5G when hot)

OUT="/sdcard/Download/ca_root_$(date +%Y%m%d_%H%M%S).log"
QMI="/data/local/tmp/qmi_nas_test"

{
    echo "# start $(date)"
    echo "# device: $(getprop ro.product.model) $(getprop ro.build.display.id)"
    echo "# kernel: $(uname -r)"
} > "$OUT"

i=0
while true; do
    ts=$(date +%Y-%m-%dT%H:%M:%S)

    {
        echo "===== $ts ====="
        dumpsys telephony.registry \
            | grep -E 'mSignalStrength=|mCellIdentity=|mPhysicalChannelConfigs=|mServiceState=|mTelephonyDisplayInfo=|mDataConnectionState=|mDataActivity=' \
            | head -n 24
    } >> "$OUT"

    if [ $((i % 5)) -eq 0 ] && [ -x "$QMI" ]; then
        {
            echo "----- qmi $ts -----"
            "$QMI" 2>&1
        } >> "$OUT"
    fi

    if [ $((i % 15)) -eq 0 ]; then
        echo "----- battery $(date +%H:%M:%S) $(dumpsys battery | grep -E 'level:|temperature:' | tr '\n' ' ')" >> "$OUT"
    fi

    i=$((i + 1))
    sleep 2
done
