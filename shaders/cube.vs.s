; Vertex shader: clip = MVP * (x, y, z, 1); Lambert term from a rotated normal.
; attributes: 0..2 position, 3..4 uv, 5..7 normal
; uniforms:   0..15 MVP (row major), 16..24 normal matrix, 25..27 light dir
; outputs:    0..3 clip position, 4..5 uv, 6 diffuse
    IN   r0, 0
    IN   r1, 1
    IN   r2, 2
; row 0
    UNI  r4, 0
    MULF r5, r4, r0
    UNI  r4, 1
    MULF r6, r4, r1
    ADD  r5, r5, r6
    UNI  r4, 2
    MULF r6, r4, r2
    ADD  r5, r5, r6
    UNI  r4, 3
    ADD  r5, r5, r4
    OUT  0, r5
; row 1
    UNI  r4, 4
    MULF r5, r4, r0
    UNI  r4, 5
    MULF r6, r4, r1
    ADD  r5, r5, r6
    UNI  r4, 6
    MULF r6, r4, r2
    ADD  r5, r5, r6
    UNI  r4, 7
    ADD  r5, r5, r4
    OUT  1, r5
; row 2
    UNI  r4, 8
    MULF r5, r4, r0
    UNI  r4, 9
    MULF r6, r4, r1
    ADD  r5, r5, r6
    UNI  r4, 10
    MULF r6, r4, r2
    ADD  r5, r5, r6
    UNI  r4, 11
    ADD  r5, r5, r4
    OUT  2, r5
; row 3
    UNI  r4, 12
    MULF r5, r4, r0
    UNI  r4, 13
    MULF r6, r4, r1
    ADD  r5, r5, r6
    UNI  r4, 14
    MULF r6, r4, r2
    ADD  r5, r5, r6
    UNI  r4, 15
    ADD  r5, r5, r4
    OUT  3, r5
; uv passthrough
    IN   r4, 3
    OUT  4, r4
    IN   r4, 4
    OUT  5, r4
; n' = N * normal
    IN   r0, 5
    IN   r1, 6
    IN   r2, 7
    UNI  r4, 16
    MULF r7, r4, r0
    UNI  r4, 17
    MULF r6, r4, r1
    ADD  r7, r7, r6
    UNI  r4, 18
    MULF r6, r4, r2
    ADD  r7, r7, r6
    UNI  r4, 19
    MULF r8, r4, r0
    UNI  r4, 20
    MULF r6, r4, r1
    ADD  r8, r8, r6
    UNI  r4, 21
    MULF r6, r4, r2
    ADD  r8, r8, r6
    UNI  r4, 22
    MULF r9, r4, r0
    UNI  r4, 23
    MULF r6, r4, r1
    ADD  r9, r9, r6
    UNI  r4, 24
    MULF r6, r4, r2
    ADD  r9, r9, r6
; diffuse = max(dot(n', L), 0) * 0.75 + 0.25
    UNI  r4, 25
    MULF r5, r4, r7
    UNI  r4, 26
    MULF r6, r4, r8
    ADD  r5, r5, r6
    UNI  r4, 27
    MULF r6, r4, r9
    ADD  r5, r5, r6
    LDI  r10, 0
    MAX  r5, r5, r10
    LDF  r10, 0.75
    MULF r5, r5, r10
    LDF  r10, 0.25
    ADD  r5, r5, r10
    OUT  6, r5
    HALT
