#!/bin/bash
# mac-tuneup: read-only check whether a Mac is really throttling, and why.
# Changes nothing. Uses powermetrics, which needs sudo (it only reads).
#
#   bash throttle-check.sh          asks for the admin password; report also in ./throttle-<date>.txt
#
# Run it twice if possible: once idle, once under the load that feels slow,
# and once on battery if it only happens on the charger (or the other way round).
# Takes about 30 seconds.
#
# What it reads: CPU frequency (actual vs nominal), CPU temperature and fans
# (Intel), thermal pressure (Apple silicon), macOS thermal limits
# (pmset -g therm), kernel_task CPU, power source, charger wattage, battery
# condition and Low Power Mode. At the end it prints which pattern the
# numbers match. It never disables a protection: throttling from heat or from
# a hardware warning is a symptom to fix at the cause.

OUTDIR="${OUTDIR:-$PWD}"
OUT="$OUTDIR/throttle-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1
hdr() { echo; echo "=== $* ==="; }
ARCH=$(uname -m)

echo "Report started $(date '+%Y-%m-%d %H:%M:%S')"
hdr "Machine"
system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model Name|Model Identifier|Chip|Processor Name|Processor Speed|Memory:" | sed 's/^ */  /'
sw_vers -productVersion | sed 's/^/  macOS /'
echo "  architecture: $ARCH"

hdr "Power source, charger, battery"
pmset -g batt | sed 's/^/  /'
system_profiler SPPowerDataType 2>/dev/null \
  | grep -E "Cycle Count|Condition|Maximum Capacity|Full Charge Capacity|Wattage|Connected:|Charging:" | sed 's/^ */  /'
pmset -g | grep -iE "lowpowermode|powermode" | sed 's/^ */  /'

hdr "macOS thermal limits (pmset -g therm)"
pmset -g therm | sed 's/^/  /'
[ "$ARCH" = x86_64 ] && sysctl machdep.xcpm.cpu_thermal_level 2>/dev/null | sed 's/^/  /'

hdr "kernel_task CPU, 4 samples 3 s apart (high = macOS holding the CPU back, usually heat)"
top -l 5 -s 3 -stats command,cpu 2>/dev/null | awk '/^COMMAND/{s++} s>1 && $1=="kernel_task"{print "  sample " s-1 ": " $2 "%"}'

hdr "powermetrics: 10 samples, 1 s apart"
if [ "$ARCH" = x86_64 ]; then SAMPLERS="cpu_power,smc"; else SAMPLERS="cpu_power,thermal"; fi
echo "  (admin password needed; powermetrics only reads)"
# the output file is meant to be owned by the user, so the redirect stays outside sudo
# shellcheck disable=SC2024
if ! sudo powermetrics --samplers "$SAMPLERS" -i 1000 -n 10 2>/dev/null > "/tmp/pm-$$.txt"; then
  # shellcheck disable=SC2024
  sudo powermetrics -i 1000 -n 10 2>/dev/null > "/tmp/pm-$$.txt"
fi
grep -iE "average frequency|HW active frequency|die temperature|^Fan|thermal level|plimit|prochot|pressure level|package power|CPU Power" "/tmp/pm-$$.txt" \
  | sed 's/^ */  /' | awk '!seen[$0]++' | head -60

# numbers for the verdict
FRAC=$(grep -oE "fraction of nominal: [0-9.]+" "/tmp/pm-$$.txt" | awk '{s+=$4; n++} END{if (n) printf "%.0f", s/n}')
TEMP=$(grep -iE "CPU die temperature" "/tmp/pm-$$.txt" | grep -oE "[0-9.]+ C" | awk '{s+=$1; n++} END{if (n) printf "%.0f", s/n}')
PRESS=$(grep -i "pressure level" "/tmp/pm-$$.txt" | awk -F: '{print $2}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
LIMIT=$(pmset -g therm | grep -oE "CPU_Speed_Limit *= *[0-9]+" | grep -oE "[0-9]+$")
KT=$(top -l 3 -s 2 -stats command,cpu 2>/dev/null | awk '$1=="kernel_task"{v=$2} END{printf "%.0f", v}')
rm -f "/tmp/pm-$$.txt"

hdr "Verdict (pattern matching, not a diagnosis)"
echo "  avg frequency vs nominal: ${FRAC:-n/a}%   CPU die temp: ${TEMP:-n/a} C   thermal pressure: ${PRESS:-n/a}"
echo "  CPU_Speed_Limit: ${LIMIT:-not reported}   kernel_task now: ${KT:-0}%"
BDPROCHOT=0
if [ "$ARCH" = x86_64 ] && [ -n "$FRAC" ] && [ "$FRAC" -lt 45 ] && [ -n "$TEMP" ] && [ "$TEMP" -lt 75 ]; then
  BDPROCHOT=1
  cat <<'EOF'
  -> Low clock speed while the CPU is NOT hot. On 2013-2016 Intel MacBooks this
     matches BD PROCHOT: a hardware warning line that pins the CPU near 800 MHz.
     Usual causes: worn battery, a non-Apple or underpowered charger, a damaged
     charger or MagSafe port, a faulty sensor. Try the original charger,
     compare battery vs charger, reset the SMC, check battery condition.
     Do not disable BD PROCHOT with third-party kexts or MSR tools: that hides
     the warning, it does not fix the cause.
EOF
fi
HOT=0
[ -n "$LIMIT" ] && [ "$LIMIT" -lt 100 ] && HOT=1
[ -n "$TEMP" ] && [ "$TEMP" -ge 90 ] && HOT=1
[ "${KT:-0}" -ge 50 ] && HOT=1
[ -n "$PRESS" ] && [ "$PRESS" != "Nominal" ] && HOT=1
if [ "$BDPROCHOT" = 1 ]; then
  : # printed above
elif [ "$HOT" = 1 ]; then
  cat <<'EOF'
  -> Thermal throttling: the Mac is slowing itself down because it is hot.
     This is protection, not a setting to switch off. Fix the heat: clean the
     fans and vents (on older Macs often also new thermal paste, by a repair
     shop), hard flat surface, find and stop the process causing the load,
     check whether an external display or charger makes it worse.
EOF
else
  cat <<'EOF'
  -> No sign of throttling in this sample. If the Mac still feels slow, the
     cause is elsewhere: run diagnose.sh (memory pressure, disk space, startup
     items, crash loops) and sample again under the load that feels slow.
EOF
fi

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"
sleep 1
