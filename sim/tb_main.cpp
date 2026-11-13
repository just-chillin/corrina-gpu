// Standalone testbench: flat host memory, the shared demo scene, PPM out.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "fxg_sim.h"
#include "fxg_regs.h"
#include "fxg_scene.h"
#include "fxg_shaders.h"

struct FlatMem : FxgMemory {
    std::vector<uint32_t> w;
    uint64_t oob = 0;
    explicit FlatMem(size_t bytes) : w(bytes / 4) {}
    uint32_t read32(uint64_t a) override { if (a / 4 >= w.size()) { oob++; return 0; } return w[a / 4]; }
    void write32(uint64_t a, uint32_t v) override { if (a / 4 >= w.size()) { oob++; return; } w[a / 4] = v; }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *out = argc > 1 ? argv[1] : "frame.ppm";
    float angle = argc > 2 ? atof(argv[2]) : 0.9f;
    const int W = 320, H = 240;
    const uint64_t RT = 0x100000, Z = 0x200000, VTX = 0x10000, VS = 0x20000,
                   FS = 0x21000, UNI = 0x22000, TEX = 0x30000;
    FlatMem mem(4 << 20);
    FxgSim sim(&mem);

    if (sim.read(FXG_REG_ID) != FXG_ID_VALUE) { fprintf(stderr, "bad ID\n"); return 1; }

    fxg_scene_build(angle, (float)W / H, &mem.w[VTX / 4], &mem.w[UNI / 4], &mem.w[TEX / 4]);
    for (size_t i = 0; i < sizeof(fxg_cube_vs) / 4; i++) mem.w[VS / 4 + i] = fxg_cube_vs[i];
    for (size_t i = 0; i < sizeof(fxg_cube_fs) / 4; i++) mem.w[FS / 4 + i] = fxg_cube_fs[i];

    sim.write64(FXG_REG_RT_ADDR, RT);
    sim.write64(FXG_REG_Z_ADDR, Z);
    sim.write(FXG_REG_RT_DIM, W | H << 16);
    sim.write64(FXG_REG_VTX_ADDR, VTX);
    sim.write(FXG_REG_VTX_COUNT, FXG_SCENE_VERTS);
    sim.write(FXG_REG_VTX_STRIDE, FXG_SCENE_STRIDE);
    sim.write64(FXG_REG_VS_ADDR, VS);
    sim.write(FXG_REG_VS_LEN, sizeof(fxg_cube_vs) / 4);
    sim.write64(FXG_REG_FS_ADDR, FS);
    sim.write(FXG_REG_FS_LEN, sizeof(fxg_cube_fs) / 4);
    sim.write64(FXG_REG_TEX_ADDR, TEX);
    sim.write(FXG_REG_TEX_DIM, FXG_SCENE_TEX_LOG2 | FXG_SCENE_TEX_LOG2 << 8);
    sim.write64(FXG_REG_UNI_ADDR, UNI);
    sim.write(FXG_REG_UNI_COUNT, 32);
    sim.write(FXG_REG_CLEAR_COLOR, 0xff101828);
    sim.write(FXG_REG_CLEAR_DEPTH, FXG_DEPTH_MAX);
    sim.write(FXG_REG_FLAGS, FXG_FLAG_CLEAR_COLOR | FXG_FLAG_CLEAR_DEPTH |
              FXG_FLAG_DEPTH_TEST | FXG_FLAG_DEPTH_WRITE | FXG_FLAG_CULL_BACK);
    sim.write(FXG_REG_IRQ_ENABLE, 1);
    sim.write(FXG_REG_CTRL, FXG_CTRL_START);

    while (!sim.irq()) {
        sim.tick();
        if (sim.cycles() > 400000000ull) { fprintf(stderr, "timeout\n"); return 1; }
    }
    uint32_t st = sim.read(FXG_REG_STATUS);
    printf("done: status=%u cycles=%u pixels=%u oob=%llu\n", st,
           sim.read(FXG_REG_PERF_CYCLES), sim.read(FXG_REG_PERF_PIXELS),
           (unsigned long long)mem.oob);

    uint32_t hash = 2166136261u;   // FNV-1a over the colour target
    for (int i = 0; i < W * H * 4; i++)
        hash = (hash ^ ((mem.w[RT / 4 + i / 4] >> (8 * (i & 3))) & 0xff)) * 16777619u;
    printf("frame hash %08x\n", hash);

    FILE *f = fopen(out, "wb");
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; i++) {
        uint32_t p = mem.w[RT / 4 + i];
        fputc(p >> 16, f); fputc(p >> 8, f); fputc(p, f);
    }
    fclose(f);
    return (st & FXG_STATUS_FAULT) || mem.oob ? 1 : 0;
}
