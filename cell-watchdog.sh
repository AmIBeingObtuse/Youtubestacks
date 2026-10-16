#!/bin/sh
# cell-watchdog.sh - GL-X2000 (Spitz Plus) cellular watchdog
#
# Fixes: when the carrier resets the mobile data session, qcm re-dials in ~1 s and the
# modem gets a NEW IP, but the router's DHCP client on wwan0_1 (interface modem_2_1_s1_4)
# keeps the OLD lease until it expires - up to 2 hours of black-holed traffic.
# This probes through the cellular interface every minute and, after 2 misses, forces a
# DHCP release + fresh DISCOVER (what the router does on its own when the lease expires).
# If that doesn't help, it re-dials the cellular session.
#
# Install:  /usr/bin/cell-watchdog.sh  +  cron "* * * * * /usr/bin/cell-watchdog.sh"
# Logs:     logread -e cell-watchdog

DEV="wwan0_1"                       # cellular data interface (check: ip -4 addr show wwan0_1)
PARENT="modem_2_1_s1"               # netifd qcm interface for SIM slot 1
PIDFILE="/var/run/udhcpc-${DEV}.pid"
TARGETS="1.1.1.1 9.9.9.9 8.8.8.8"
STATE="/tmp/cell-watchdog.count"
TAG="cell-watchdog"

# Healthy if any target answers through the cellular interface
for t in $TARGETS; do
    if ping -q -c 1 -W 3 -I "$DEV" "$t" >/dev/null 2>&1; then
        [ -f "$STATE" ] && logger -t "$TAG" "cellular OK again via $DEV"
        rm -f "$STATE"
        exit 0
    fi
done

n=$(cat "$STATE" 2>/dev/null)
n=$(( ${n:-0} + 1 ))
echo "$n" > "$STATE"
ip4=$(ip -4 addr show dev "$DEV" 2>/dev/null | awk '/inet /{print $2; exit}')
logger -t "$TAG" "no reply via $DEV (miss $n, ip ${ip4:-none})"

case "$n" in
    2)    # 2 misses in a row: assume a stale lease -> release + fresh DISCOVER
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            logger -t "$TAG" "forcing DHCP release/rediscover on $DEV (udhcpc $pid)"
            kill -USR2 "$pid"
            sleep 2
            kill -USR1 "$pid"
        else
            logger -t "$TAG" "no udhcpc for $DEV, re-dialling $PARENT"
            ifup "$PARENT"
        fi
        ;;
    5)    # still dead 3 minutes later: full re-dial of the cellular session
        logger -t "$TAG" "still no reply, re-dialling $PARENT"
        ifup "$PARENT"
        ;;
    10)    # still dead: start the cycle again (never reboots, never loops faster than this)
        echo 0 > "$STATE"
        ;;
esac
exit 0
