#!/system/bin/sh
# collect_ca_qmi.sh
#
# 手机端同时采集 telephony.registry 和 QMI RF Band Information。
# 用法（MT 管理器终端，root）：
#   sh /sdcard/Download/collect_ca_qmi.sh
# 停止：Ctrl-C，或直接关掉终端。
#
# 输出：/sdcard/Download/ca_qmi_YYYYmmdd_HHMMSS.log
#
# 判读：
#   QMI "TLV 0x11 len=8"  -> 1 个载波
#   QMI "TLV 0x11 len=16" -> 2 个载波（CA）

OUT="/sdcard/Download/ca_qmi_$(date +%Y%m%d_%H%M%S).log"
QMI=/data/local/tmp/qmi_nas_test

echo "# start $(date)" > "$OUT"
echo "# device: $(getprop ro.product.model) $(getprop ro.build.display.id)" >> "$OUT"

while true; do
    echo "===== $(date +%H:%M:%S) =====" >> "$OUT"

    dumpsys telephony.registry \
        | grep -E 'mCellIdentity=CellIdentityNr|mPhysicalChannelConfigs=|mServiceState=|ssRsrp' \
        >> "$OUT"

    "$QMI" 2>&1 \
        | grep -E 'Get RF Band Information|TLV 0x01 len|TLV 0x11 len' \
        >> "$OUT"

    sleep 2
done
