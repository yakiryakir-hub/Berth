#!/bin/bash
# Waits for the SM-X133 volume to mount, then runs the packet-alignment
# verification: a 50 MB write is the exact case that failed before
# (chunk 1 ended on a short packet, chunk 2 stalled 60.93 s).
cd "$(dirname "$0")"

echo "[watcher] waiting for mount..."
for i in $(seq 1 180); do
  mount | grep -q webdav && break
  sleep 1
done
if ! mount | grep -q webdav; then
  echo "[watcher] TIMEOUT: no mount appeared"
  exit 1
fi
echo "[watcher] mounted: $(mount | grep webdav)"

M=$(find ~/Berth -maxdepth 2 -type d -name Download 2>/dev/null | head -1)
if [ -z "$M" ]; then echo "no Download dir found"; exit 1; fi
echo "using mount: $M"
MARK=$(wc -l < ~/Library/Logs/Berth.mtp.log 2>/dev/null || echo 0)

for MB in 4 50; do
  head -c $((MB*1024*1024)) /dev/urandom > /tmp/v$MB.bin
  SRC=$(shasum -a 256 /tmp/v$MB.bin | cut -d' ' -f1)
  T0=$(python3 -c 'import time;print(time.time())')
  cp /tmp/v$MB.bin "$M/verify$MB.bin"; RC=$?
  T1=$(python3 -c 'import time;print(time.time())')
  SZ=$(stat -f%z "$M/verify$MB.bin" 2>/dev/null || echo ABSENT)
  DST=$(shasum -a 256 "$M/verify$MB.bin" 2>/dev/null | cut -d' ' -f1 || echo unreadable)
  if [ "$SRC" = "$DST" ]; then OK="SHA-MATCH"; else OK="SHA-MISMATCH"; fi
  python3 -c "
d=$T1-$T0; s=$MB*1048576
print('%2d MB  cp_rc=$RC  ondevice=$SZ  %.2fs  %.1f MB/s  $OK' % ($MB, d, s/d/1e6 if d>0 else 0))"
done

echo "=== errors ==="
grep -E "mtp error|403" ~/Library/Logs/Berth.log 2>/dev/null | tail -4 || echo "(none)"
echo "=== trace tail ==="
tail -n +$((MARK+1)) ~/Library/Logs/Berth.mtp.log 2>/dev/null | tail -20
