#!/bin/zsh
# A/B CPU measurement of the running app in different render modes.
# Works with the display asleep (timer-driven frames) unless LIVE=1.
# usage: scripts/ab_cpu.sh [seconds] — prints one line per mode.
set -u
cd "${0:A:h}/.."
APP=build/DerivedData/Build/Products/Release/Chilk.app
N=${1:-12}
LOG=${TMPDIR:-/tmp}/chilk-ab.log
modes=(
  "rig idle30 (default):"
  "rig idle60:CHILK_IDLE_FPS=60"
  "vector idle30 (old):CHILK_CG_RENDER=1"
)
[ -n "${MODES:-}" ] && modes=(${(s:;:)MODES})
for entry in "${modes[@]}"; do
  name=${entry%%:*}; envs=${entry#*:}
  pkill -x Chilk 2>/dev/null; sleep 0.6; rm -f $LOG
  args=(--env CHILK_DEBUG=$LOG --env CHILK_IGNORE_POINTER=1)
  [ "${LIVE:-0}" = 1 ] || args+=(--env CHILK_TIMER_DRIVER=1)
  for e in ${=envs}; do args+=(--env $e); done
  open "${args[@]}" $APP
  sleep 4
  cpu=$(./scripts/cpu.sh $N | sed -E 's/.*avg CPU ([0-9.]+)%.*/\1/')
  stat=$(tail -1 $LOG 2>/dev/null | sed -E 's/^[0-9]+ s: //')
  printf "%-16s CPU %5s%%  | %s\n" "$name" "$cpu" "${stat:-no stats}" | tr -s '\n'
done
pkill -x Chilk 2>/dev/null
