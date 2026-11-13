#!/bin/sh
# Boot a kernel with the FXG-1 RTL attached as a PCIe device.
#   QEMU=/path/to/qemu-system-x86_64 vm/run.sh bzImage initrd.cpio.gz
# QEMU must be built with qemu/fxg.c (see README). Firmware blobs are looked
# up in the usual distro locations; override with QEMU_FW="-L dir".
here=$(cd "$(dirname "$0")" && pwd)
sock=${FXG_SOCK:-/tmp/fxg.sock}
rm -f "$sock"
"$here/../sim/obj_bridge/fxg_bridge" "$sock" &
bridge=$!
while [ ! -S "$sock" ]; do sleep 0.2; done
${QEMU:-qemu-system-x86_64} -M q35 -cpu max -m 512 -nodefaults -display none \
	-serial stdio -no-reboot ${QEMU_FW:--L /usr/share/seabios -L /usr/share/qemu} \
	-kernel "$1" -initrd "$2" -append "console=ttyS0 panic=-1 loglevel=4" \
	-device fxg,socket="$sock"
kill $bridge 2>/dev/null
