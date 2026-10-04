#!/bin/zsh
# Average CPU of the running Chilk over N seconds (default 20).
pid=$(pgrep -x Chilk) || { echo "Chilk is not running"; exit 1; }
n=${1:-20}
total=0
for i in $(seq 1 $n); do
  c=$(ps -o %cpu= -p $pid | tr -d ' ')
  total=$(echo "$total + $c" | bc)
  sleep 1
done
echo "Chilk pid $pid: avg CPU $(echo "scale=1; $total / $n" | bc)% over ${n}s, RSS $(( $(ps -o rss= -p $pid) / 1024 )) MB"
