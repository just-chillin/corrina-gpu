# Roadmap: from FXG-1 to Vulkan

FXG-1 today is a correct small GPU, not a Vulkan-class one. This is the
ordered list of what stands between the two. Vulkan is the target rather than
OpenGL 4.5 because the driver is thinner (Mesa turns SPIR-V into NIR for you,
and there is no legacy GL state machine), and Zink then provides OpenGL 4.6 on
top of any conformant Vulkan driver.

Nothing below is started unless it says so.

## Where it stands

| Area | Vulkan 1.0 needs | FXG-1 has |
|---|---|---|
| Shader arithmetic | IEEE-754 float32, int32, bool | Q16.16 fixed point, int32 |
| Shader size | Thousands of instructions, loops, functions | 256 words, forward/backward branches, 4000-step watchdog |
| Registers | Enough for SSA after register allocation (32+ vec4) | 16 scalars |
| Stages | Vertex, fragment (+ optional geometry, tessellation, compute) | Vertex, fragment |
| Vertex input | Multiple bindings, formats, instancing, index buffers | One buffer, 32-bit words, non-indexed triangle list |
| Primitive assembly | Lists, strips, fans, lines, points; clipping to the frustum | Triangle list; whole-triangle near reject, no clipper |
| Rasteriser | Top-left rule, scissor, depth bias, MSAA optional | Edge functions, bounding-box scan; fill rule is a TODO |
| Depth/stencil | All compare ops, stencil ops | LESS only, no stencil |
| Blending | Per-target blend equations, colour mask | None (overwrite) |
| Render targets | Up to 4+ colour attachments, several formats | One ARGB8888 |
| Textures | 2D/3D/cube/array, mipmaps, linear filtering, many formats, several bound at once | One 2D power-of-two ARGB8888, nearest, repeat |
| Uniform data | Descriptor sets, UBOs, push constants | 32 words |
| Memory | Per-context virtual address space (GPU MMU) | Raw bus addresses, kernel validates every job |
| Job model | Command buffers, queues, fences, multiple contexts | One synchronous job per ioctl |
| Kernel driver | BO mmap, dma-buf export, sync objects, scheduler | BO create/read/write, blocking submit |
| Userspace | Mesa Vulkan driver, NIR backend, WSI | None; a custom ioctl demo |

## Milestones

1. **Float shader core.** Replace Q16.16 with IEEE float32: adder, multiplier,
   reciprocal and reciprocal-sqrt, float/int conversion, compares. Widen the
   register file and make registers 4-wide vectors with swizzles. Without this
   no compiler backend is possible, so it comes first.
2. **Shader ISA v2 and an assembler/disassembler pair.** Structured control
   flow, a constant pool, larger programs fetched on demand instead of copied
   into a 512-word RAM.
3. **Fixed-function completeness.** Clipper, the fill rule, scissor, full
   depth compare set, stencil, blending, colour masks, linear and mipmapped
   sampling, multiple textures and render targets.
4. **Memory and job model.** A GPU MMU with per-context page tables, command
   buffers fetched by the hardware, a job ring so submit does not block, and
   in the kernel: drm_sched, sync objects, dma-buf, BO mmap. On the Rust side
   this needs a GEM abstraction that can mmap DMA memory, which upstream does
   not have yet.
5. **NIR backend.** `nir_to_fxg`: lowering passes, register allocation,
   instruction selection. This is the largest single piece of work.
6. **Mesa Vulkan driver ("fxgvk").** Start from the runtime in `src/vulkan`:
   device, queue, pipelines, descriptor sets, render passes, WSI. First goal is
   `vkcube`, then the CTS.
7. **Zink on top** for OpenGL, once enough of the CTS passes.
8. **Performance.** A parallel fragment pipeline, tiling, a texture cache. At
   one shared shader core and one pixel at a time, FXG-1 takes about 3.2
   million clock cycles for a 320x240 cube.

Doom (2016) sits past milestone 7 and also needs several gigabytes of memory
bandwidth that a simulated or small-FPGA GPU will not have. Doom (1993) via
doomgeneric needs only a textured quad and works with the hardware as it is.
