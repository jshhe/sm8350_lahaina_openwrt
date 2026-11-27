#!/system/bin/sh
# Magisk late_start service: start the CPU/charge guard once.
GUARD=/data/openwrt/scripts/05b_cpu_charge_guard.sh
[ -x "$GUARD" ] || exit 0

# Do not start twice. PIDs get reused across reboots, so only trust a PID file
# whose process really is the guard (checks /proc/<pid>/cmdline).
PIDFILE=/data/openwrt/run/power_guard.pid
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        cmd=$(tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null)
        case "$cmd" in
            *05b_cpu_charge_guard*) exit 0 ;;
        esac
    fi
fi

nohup /system/bin/sh "$GUARD" >/dev/null 2>&1 &
