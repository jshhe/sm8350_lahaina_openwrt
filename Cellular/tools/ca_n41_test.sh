#!/system/bin/sh
# ca_n41_test.sh
#
# 目的：强制一加用 n41 做主载波，然后在有流量时把 n79 加回允许列表，
#       看网络会不会把 n79 作为 SCell 挂上来。
#
# 用法（MT 管理器终端，root）：
#   sh /sdcard/Download/ca_n41_test.sh
#
# 流程：
#   1. SA 只锁 n41，等手机驻留到 n41（ARFCN 504990）
#   2. 提示你开始测速，等 20 秒
#   3. 把 n79 加回允许列表
#   4. 记录 120 秒的 dumpsys（载波数 / 频段 / RSRP）
#   5. 恢复默认频段配置
#
# 输出：/sdcard/Download/ca_n41_YYYYmmdd_HHMMSS.log

OUT="/sdcard/Download/ca_n41_$(date +%Y%m%d_%H%M%S).log"
QMI_SET=/data/local/tmp/qmi_band_set
QMI_RESTORE=/data/local/tmp/qmi_restore_nr

log() { echo "$@" >> "$OUT"; }

log "# start $(date)"
log "# device: $(getprop ro.product.model) $(getprop ro.build.display.id)"
log ""

echo ""
echo "=== 步骤 1/4：SA 只锁 n41 ==="
log "# step1: SA = n41 only"
$QMI_SET 41 41,79 0 >> "$OUT" 2>&1
echo "已下发，等待驻留 n41 ..."

i=0
while [ $i -lt 60 ]; do
    arfcn=$(dumpsys telephony.registry | grep -m1 'mCellIdentity=CellIdentityNr' \
            | sed -n 's/.*mNrArfcn = \([0-9]*\).*/\1/p')
    log "wait ${i}: arfcn=$arfcn"
    if [ "$arfcn" = "504990" ]; then
        echo "已驻留 n41 (ARFCN 504990)"
        break
    fi
    i=$((i+1))
    sleep 2
done

if [ "$arfcn" != "504990" ]; then
    echo "!! 120 秒内没有驻留到 n41（当前 arfcn=$arfcn）"
    echo "!! 可能这个位置 n41 太弱，换个位置再试"
    log "# abort: never camped on n41"
    $QMI_RESTORE >> "$OUT" 2>&1
    echo "已恢复默认频段。日志：$OUT"
    exit 1
fi

echo ""
echo "=== 步骤 2/4：现在开始测速（切到测速 App，20 秒后自动继续）==="
log "# step2: user starts speedtest, wait 20s"
sleep 20

echo ""
echo "=== 步骤 3/4：把 n79 加回允许列表 ==="
log "# step3: add n79"
$QMI_SET 41,79 41,79 0 >> "$OUT" 2>&1

echo "=== 步骤 4/4：记录 120 秒（保持测速/下载）==="
i=0
while [ $i -lt 60 ]; do
    echo "===== $(date +%H:%M:%S) =====" >> "$OUT"
    dumpsys telephony.registry \
        | grep -E 'mCellIdentity=CellIdentityNr|mPhysicalChannelConfigs=|mNr=CellSignalStrengthNr' \
        >> "$OUT"
    i=$((i+1))
    sleep 2
done

echo ""
echo "=== 恢复默认频段 ==="
log "# restore"
$QMI_RESTORE >> "$OUT" 2>&1
log "# done"

echo ""
echo "完成。日志：$OUT"
echo "把这份日志发给我，或者直接 adb pull。"
