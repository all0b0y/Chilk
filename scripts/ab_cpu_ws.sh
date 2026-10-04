#!/bin/zsh
# CPU of Chilk AND WindowServer (GPU compositing moves work there) per render mode, display awake.
# usage: scripts/ab_cpu_ws.sh [seconds]
set -u
cd "${0:A:h}/.."
APP=build/DerivedData/Build/Products/Release/Chilk.app
N=${1:-15}
ws=$(pgrep -x WindowServer)
avg() {  # avg CPU of pid $1 over N seconds
  local total=0
  for i in $(seq 1 $N); do total=$(echo "$total + $(ps -o %cpu= -p $1 | tr -d ' ')" | bc); sleep 1; done
  echo "scale=1; $total / $N" | bc
}
measure() {  # $1 name, $2 chilk pid or empty
  if [ -n "$2" ]; then
    avg $2 > /tmp/chilk_cpu.$$ & local p=$!
    local w=$(avg $ws); wait $p; local c=$(cat /tmp/chilk_cpu.$$)
  else
    local w=$(avg $ws); local c="-"
  fi
  printf "%-26s Chilk %5s%%   WindowServer %5s%%\n" "$1" "$c" "$w"
}
pkill -x Chilk 2>/dev/null; sleep 1
measure "baseline (no Chilk)" ""
for entry in "rig, idle 30 fps (default):" "rig, 60 fps always:CHILK_IDLE_FPS=60" "old CPU path, idle 30 fps:CHILK_CG_RENDER=1"; do
  name=${entry%%:*}; envs=${entry#*:}
  pkill -x Chilk 2>/dev/null; sleep 0.8
  args=(--env CHILK_IGNORE_POINTER=1)
  for e in ${=envs}; do args+=(--env $e); done
  open "${args[@]}" $APP; sleep 4
  measure "$name" "$(pgrep -x Chilk)"
done
pkill -x Chilk 2>/dev/null; sleep 0.5; open $APP
rm -f /tmp/chilk_cpu.$$
