#!/bin/sh
# Copy the fxg driver into a kernel tree and hook it into Kconfig, the DRM
# Makefile and the Rust UAPI bindings. Idempotent. Written against Linux 7.3.
#   driver/install.sh /path/to/linux
set -e
tree=${1:?usage: install.sh <kernel tree>}
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$tree/drivers/gpu/drm/fxg"
cp "$here"/drivers/gpu/drm/fxg/* "$tree/drivers/gpu/drm/fxg/"
cp "$here/include/uapi/drm/fxg_drm.h" "$tree/include/uapi/drm/"

grep -q 'drm/fxg/Kconfig' "$tree/drivers/gpu/drm/Kconfig" ||
	sed -i 's|^source "drivers/gpu/drm/tyr/Kconfig"|&\n\nsource "drivers/gpu/drm/fxg/Kconfig"|' \
		"$tree/drivers/gpu/drm/Kconfig"
grep -q 'CONFIG_DRM_FXG' "$tree/drivers/gpu/drm/Makefile" ||
	echo 'obj-$(CONFIG_DRM_FXG) += fxg/' >> "$tree/drivers/gpu/drm/Makefile"
grep -q 'fxg_drm.h' "$tree/rust/uapi/uapi_helper.h" ||
	sed -i 's|^#include <uapi/drm/drm.h>|&\n#include <uapi/drm/fxg_drm.h>|' \
		"$tree/rust/uapi/uapi_helper.h"
echo "fxg installed into $tree; enable CONFIG_DRM_FXG"
