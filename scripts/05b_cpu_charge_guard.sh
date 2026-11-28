#!/system/bin/sh
# ==============================================================================
# 05b_cpu_charge_guard.sh
# 常驻守护：
#   1. 保持 Cortex-X1 (cpu7) 离线
#   2. 限制 A78 / A55 最高频率
#   3. 电池保持在 50%~60%：>=60% 停充，<=50% 恢复充电
#
# 用法：
#   sh 05b_cpu_charge_guard.sh --once   # 只执行一次
#   sh 05b_cpu_charge_guard.sh          # 常驻循环
# ==============================================================================

LOG=/data/openwrt/logs/power_guard.log
PIDFILE=/data/openwrt/run/power_guard.pid
mkdir -p /data/openwrt/logs /data/openwrt/run

CPU7=/sys/devices/system/cpu/cpu7/online
P0=/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
P4=/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
CAP=/sys/class/oplus_chg/battery/capacity
MMI=/sys/class/oplus_chg/battery/mmi_charging_enable
USB_ONLINE=/sys/class/power_supply/usb/online
POWER_ROLE=/sys/class/typec/port0/power_role

STOP_SOC=${STOP_SOC:-60}
RESUME_SOC=${RESUME_SOC:-50}
LOW_SOC_WARN=${LOW_SOC_WARN:-20}
P0_MAX=${P0_MAX:-1324800}
P4_MAX=${P4_MAX:-1440000}
LAST_LOW_WARN_SOC=""

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

set_max() {
    # $1 = sysfs path, $2 = max frequency
    [ -e "$1" ] || return 0
    cur=$(cat "$1" 2>/dev/null)
    case "$cur" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$cur" -gt "$2" ]; then
        if echo "$2" > "$1" 2>/dev/null; then
            log "freq $1: $cur -> $2"
        fi
    fi
}

apply() {
    # X1 offline
    if [ -e "$CPU7" ]; then
        v=$(cat "$CPU7" 2>/dev/null)
        if [ "$v" != "0" ]; then
            if echo 0 > "$CPU7" 2>/dev/null; then
                log "cpu7 offline"
            else
                log "cpu7 offline FAILED"
            fi
        fi
    fi

    set_max "$P0" "$P0_MAX"
    set_max "$P4" "$P4_MAX"

    # Battery band
    [ -e "$CAP" ] || return 0
    soc=$(cat "$CAP" 2>/dev/null)
    case "$soc" in ''|*[!0-9]*) return 0 ;; esac
    en=$(cat "$MMI" 2>/dev/null)

    if [ "$soc" -ge "$STOP_SOC" ] && [ "$en" != "0" ]; then
        if echo 0 > "$MMI" 2>/dev/null; then
            log "soc=$soc stop charging"
        else
            log "soc=$soc stop charging FAILED"
        fi
    elif [ "$soc" -le "$RESUME_SOC" ] && [ "$en" != "1" ]; then
        if echo 1 > "$MMI" 2>/dev/null; then
            log "soc=$soc resume charging"
        else
            log "soc=$soc resume FAILED (stop_voter/full)"
        fi
    fi

    # Rate-limited diagnostic alert when battery drains low without USB power
    # (e.g. non-PD dock stuck in power_role=[source] after reboot, or unplugged).
    if [ "$soc" -le "$LOW_SOC_WARN" ]; then
        uon=$(cat "$USB_ONLINE" 2>/dev/null)
        if [ "$uon" = "0" ] || [ -z "$uon" ]; then
            if [ "$(cat "$MMI" 2>/dev/null)" != "1" ]; then
                echo 1 > "$MMI" 2>/dev/null
            fi
            do_warn=0
            if [ -z "$LAST_LOW_WARN_SOC" ]; then
                do_warn=1
            elif [ "$soc" -le $((LAST_LOW_WARN_SOC - 5)) ]; then
                do_warn=1
            fi
            if [ "$do_warn" = "1" ]; then
                prole=$(cat "$POWER_ROLE" 2>/dev/null)
                log "WARN: low battery soc=${soc}% usb_online=${uon:-?} power_role=${prole:-?} mmi=$(cat "$MMI" 2>/dev/null)"
                LAST_LOW_WARN_SOC="$soc"
            fi
        else
            LAST_LOW_WARN_SOC=""
        fi
    else
        LAST_LOW_WARN_SOC=""
    fi
}

if [ "$1" = "--once" ]; then
    apply
    exit 0
fi

if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        # PID files survive reboots while PIDs get reused: verify the process
        # is really this guard, not just any process that inherited the PID.
        cmd=$(tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null)
        case "$cmd" in
            *05b_cpu_charge_guard*) exit 0 ;;
        esac
    fi
fi

echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM
log "guard started pid=$$ stop=${STOP_SOC}% resume=${RESUME_SOC}%"

while true; do
    apply
    sleep 30
done
