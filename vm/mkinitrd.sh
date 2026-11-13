#!/bin/sh
# Build a tiny initramfs that runs the demo and prints the frame on the
# console as gzip+base64 between ===BEGIN=== / ===END===.
#   vm/mkinitrd.sh out.cpio.gz demo/fxg_demo [module.ko ...]
set -e
out=$1; demo=$2; shift 2
d=$(mktemp -d)
mkdir -p $d/bin $d/dev $d/proc $d/sys $d/tmp $d/mod
cp "${BUSYBOX:-/bin/busybox}" $d/bin/busybox
for a in sh mount insmod gzip base64 poweroff cat ls dmesg; do ln -s busybox $d/bin/$a; done
cp "$demo" $d/bin/fxg_demo
i=0; for m in "$@"; do cp "$m" $d/mod/$(printf %02d $i)-$(basename "$m"); i=$((i+1)); done
cat > $d/init <<'EOS'
#!/bin/sh
mount -t devtmpfs dev /dev; mount -t proc proc /proc; mount -t sysfs sys /sys
for m in /mod/*.ko; do [ -e "$m" ] && insmod "$m"; done
ls -l /dev/dri/
/bin/fxg_demo /tmp/frame.ppm; echo "demo exit $?"
dmesg | grep -iE "fxg|drm" | tail -10
echo ===BEGIN===; gzip -c /tmp/frame.ppm | base64; echo ===END===
poweroff -f
EOS
chmod +x $d/init
(cd $d && find . | cpio -o -H newc 2>/dev/null | gzip) > "$out"
rm -rf $d
