/*
 * FXG-1 GPU: QEMU PCI Express endpoint that forwards BAR0 accesses to an
 * external Verilator simulation of the RTL, and performs bus-master DMA and
 * MSI on its behalf. Drop into hw/misc/ and add to hw/misc/meson.build:
 *     system_ss.add(files('fxg.c'))
 *
 *   -device fxg,socket=/tmp/fxg.sock
 */
#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/pcie.h"
#include "hw/pci/msi.h"
#include "hw/qdev-properties.h"
#include <sys/un.h>
#include "fxg_proto.h"

#define TYPE_FXG "fxg"
OBJECT_DECLARE_SIMPLE_TYPE(FxgState, FXG)

struct FxgState {
    PCIDevice parent_obj;
    MemoryRegion mmio;
    QEMUTimer *timer;
    char *sockpath;
    int fd;
    bool irq;
};

static bool fxg_io(FxgState *s, void *buf, size_t len, bool wr)
{
    uint8_t *p = buf;
    while (len && s->fd >= 0) {
        ssize_t n = wr ? write(s->fd, p, len) : read(s->fd, p, len);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            error_report("fxg: simulator connection lost");
            close(s->fd);
            s->fd = -1;
            break;
        }
        p += n;
        len -= n;
    }
    return s->fd >= 0;
}

/* Send one request, service DMA until the reply comes back. */
static uint64_t fxg_xfer(FxgState *s, uint32_t type, uint64_t addr, uint64_t data)
{
    PCIDevice *pdev = PCI_DEVICE(s);
    struct fxg_msg m = { .type = type, .addr = addr, .data = data };

    if (!fxg_io(s, &m, sizeof(m), true)) {
        return ~0ull;
    }
    for (;;) {
        if (!fxg_io(s, &m, sizeof(m), false)) {
            return ~0ull;
        }
        if (m.type == FXG_DMA_READ || m.type == FXG_DMA_WRITE) {
            g_autofree uint8_t *buf = g_malloc0(m.len);
            if (m.type == FXG_DMA_WRITE) {
                fxg_io(s, buf, m.len, false);
                pci_dma_write(pdev, m.addr, buf, m.len);
            } else {
                struct fxg_msg r = { .type = FXG_DMA_DATA, .len = m.len,
                                     .addr = m.addr };
                pci_dma_read(pdev, m.addr, buf, m.len);
                fxg_io(s, &r, sizeof(r), true);
                fxg_io(s, buf, m.len, true);
            }
            continue;
        }
        break; /* FXG_REPLY */
    }

    bool irq = m.addr & FXG_FLAG_IRQ;
    if (irq != s->irq) {
        s->irq = irq;
        if (msi_enabled(pdev)) {
            if (irq) {
                msi_notify(pdev, 0);
            }
        } else {
            pci_set_irq(pdev, irq);
        }
    }
    if (m.addr & FXG_FLAG_BUSY) {
        /* The GPU is rendering: keep its clock running from the main loop. */
        timer_mod(s->timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 100000);
    }
    return m.data;
}

static void fxg_tick(void *opaque)
{
    fxg_xfer(opaque, FXG_TICK, 0, 0);
}

static uint64_t fxg_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    return fxg_xfer(opaque, FXG_MMIO_READ, addr, 0);
}

static void fxg_mmio_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    fxg_xfer(opaque, FXG_MMIO_WRITE, addr, val);
}

static const MemoryRegionOps fxg_mmio_ops = {
    .read = fxg_mmio_read,
    .write = fxg_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
    .impl  = { .min_access_size = 4, .max_access_size = 4 },
};

static void fxg_realize(PCIDevice *pdev, Error **errp)
{
    FxgState *s = FXG(pdev);
    struct sockaddr_un sa = { .sun_family = AF_UNIX };

    if (!s->sockpath) {
        error_setg(errp, "fxg: 'socket' property is required");
        return;
    }
    s->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", s->sockpath);
    if (s->fd < 0 || connect(s->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        error_setg_errno(errp, errno, "fxg: cannot connect to %s", s->sockpath);
        return;
    }

    pci_config_set_interrupt_pin(pdev->config, 1);
    memory_region_init_io(&s->mmio, OBJECT(s), &fxg_mmio_ops, s, "fxg-mmio", 4096);
    pci_register_bar(pdev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);

    if (pci_bus_is_express(pci_get_bus(pdev))) {
        pcie_endpoint_cap_init(pdev, 0);
    }
    if (msi_init(pdev, 0, 1, true, false, errp) < 0) {
        return;
    }
    s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, fxg_tick, s);
}

static void fxg_exit(PCIDevice *pdev)
{
    FxgState *s = FXG(pdev);

    timer_free(s->timer);
    msi_uninit(pdev);
    if (s->fd >= 0) {
        close(s->fd);
    }
}

static Property fxg_props[] = {
    DEFINE_PROP_STRING("socket", FxgState, sockpath),
    DEFINE_PROP_END_OF_LIST(),
};

static void fxg_class_init(ObjectClass *oc, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(oc);

    k->realize = fxg_realize;
    k->exit = fxg_exit;
    k->vendor_id = PCI_VENDOR_ID_REDHAT; /* 0x1b36: no vendor ID of our own */
    k->device_id = 0x4658;               /* "FX" */
    k->revision = 1;
    k->class_id = 0x0302;                /* display controller, 3D */
    set_bit(DEVICE_CATEGORY_DISPLAY, dc->categories);
    device_class_set_props(dc, fxg_props);
    dc->desc = "FXG-1 GPU (Verilator co-simulation)";
}

static const TypeInfo fxg_info = {
    .name = TYPE_FXG,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(FxgState),
    .class_init = fxg_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { },
    },
};

static void fxg_register_types(void)
{
    type_register_static(&fxg_info);
}
type_init(fxg_register_types)
