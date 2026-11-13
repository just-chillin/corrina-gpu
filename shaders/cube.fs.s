; Fragment shader: textured, lit, with a procedural dot in the middle of each
; face (the branch).
; varyings: 0..1 uv, 2 diffuse     uniforms: 28 dot radius^2, 29..31 dot colour
    IN   r0, 0
    IN   r1, 1
    IN   r2, 2
    TEX  r3, r0, r1
; unpack ARGB8888 into Q16.16 channels
    LDI  r8, 255
    SHRI r4, r3, 16
    AND  r4, r4, r8
    SHLI r4, r4, 8
    SHRI r5, r3, 8
    AND  r5, r5, r8
    SHLI r5, r5, 8
    AND  r6, r3, r8
    SHLI r6, r6, 8
; inside the dot?
    LDF  r9, 0.5
    SUB  r10, r0, r9
    MULF r10, r10, r10
    SUB  r11, r1, r9
    MULF r11, r11, r11
    ADD  r10, r10, r11
    UNI  r11, 28
    SLT  r12, r10, r11
    BZ   r12, shade
    UNI  r4, 29
    UNI  r5, 30
    UNI  r6, 31
shade:
    MULF r4, r4, r2
    MULF r5, r5, r2
    MULF r6, r6, r2
    OUT  0, r4
    OUT  1, r5
    OUT  2, r6
    LDF  r7, 1.0
    OUT  3, r7
    HALT
