/* The demo scene (a lit, textured, spinning cube), built once and used by both
 * the RTL testbench and the userspace demo so they render the same frame. */
#ifndef FXG_SCENE_H
#define FXG_SCENE_H
#include <math.h>
#include <stdint.h>
#include <string.h>

#define FXG_SCENE_VERTS  36
#define FXG_SCENE_STRIDE 8
#define FXG_SCENE_TEX_LOG2 6

static inline uint32_t fxg_fix(float f) { return (uint32_t)(int32_t)lrintf(f * 65536.0f); }

static inline void fxg_mat4_mul(float *o, const float *a, const float *b)
{
    float t[16];
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++) {
            t[r * 4 + c] = 0;
            for (int k = 0; k < 4; k++)
                t[r * 4 + c] += a[r * 4 + k] * b[k * 4 + c];
        }
    memcpy(o, t, sizeof(t));
}

/* vtx: 36 * 8 words, uni: 32 words, tex: 64 * 64 words */
static inline void fxg_scene_build(float angle, float aspect,
                                   uint32_t *vtx, uint32_t *uni, uint32_t *tex)
{
    static const float faces[6][6] = { /* normal, tangent */
        { 1, 0, 0,  0, 1, 0 }, { -1, 0, 0,  0, 0, 1 },
        { 0, 1, 0,  0, 0, 1 }, { 0, -1, 0,  1, 0, 0 },
        { 0, 0, 1,  1, 0, 0 }, { 0, 0, -1,  0, 1, 0 },
    };
    static const float corner[4][2] = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } };
    static const int order[6] = { 0, 1, 2, 0, 2, 3 };   /* CCW from outside */
    uint32_t *v = vtx;

    for (int f = 0; f < 6; f++) {
        const float *n = faces[f], *t = faces[f] + 3;
        float b[3] = { n[1] * t[2] - n[2] * t[1], n[2] * t[0] - n[0] * t[2],
                       n[0] * t[1] - n[1] * t[0] };
        for (int i = 0; i < 6; i++) {
            const float *c = corner[order[i]];
            for (int k = 0; k < 3; k++)
                *v++ = fxg_fix(n[k] + c[0] * t[k] + c[1] * b[k]);
            *v++ = fxg_fix((c[0] + 1) * 0.5f);
            *v++ = fxg_fix((c[1] + 1) * 0.5f);
            for (int k = 0; k < 3; k++)
                *v++ = fxg_fix(n[k]);
        }
    }

    float ca = cosf(angle), sa = sinf(angle);
    float cb = cosf(angle * 0.7f), sb = sinf(angle * 0.7f);
    float ry[16] = { ca, 0, sa, 0,  0, 1, 0, 0,  -sa, 0, ca, 0,  0, 0, 0, 1 };
    float rx[16] = { 1, 0, 0, 0,  0, cb, -sb, 0,  0, sb, cb, 0,  0, 0, 0, 1 };
    float model[16], view[16] = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, -4.5f,  0, 0, 0, 1 };
    float zn = 1.0f, zf = 12.0f, fy = 1.0f / tanf(0.5f * 50.0f * (float)M_PI / 180.0f);
    float proj[16] = { fy / aspect, 0, 0, 0,  0, fy, 0, 0,
                       0, 0, (zf + zn) / (zn - zf), 2 * zf * zn / (zn - zf),
                       0, 0, -1, 0 };
    float mvp[16];

    fxg_mat4_mul(model, ry, rx);
    fxg_mat4_mul(mvp, view, model);
    fxg_mat4_mul(mvp, proj, mvp);
    for (int i = 0; i < 16; i++)
        uni[i] = fxg_fix(mvp[i]);
    for (int r = 0; r < 3; r++)       /* rotation only, so normal matrix = model */
        for (int c = 0; c < 3; c++)
            uni[16 + r * 3 + c] = fxg_fix(model[r * 4 + c]);
    uni[25] = fxg_fix(0.37f); uni[26] = fxg_fix(0.56f); uni[27] = fxg_fix(0.74f);
    uni[28] = fxg_fix(0.035f);                               /* dot radius^2 */
    uni[29] = fxg_fix(1.0f); uni[30] = fxg_fix(0.78f); uni[31] = fxg_fix(0.2f);

    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++) {
            int chk = ((x >> 3) ^ (y >> 3)) & 1;
            uint32_t r = chk ? 230 : 40 + x * 2, g = chk ? 230 : 70 + y,
                     bl = chk ? 235 : 160;
            tex[y * 64 + x] = 0xff000000u | r << 16 | g << 8 | bl;
        }
}
#endif
