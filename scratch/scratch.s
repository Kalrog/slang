add	x0, x1, x2                      // encoding: [0x20,0x00,0x02,0x8b]
cmp	x0, #0                          // encoding: [0x1f,0x00,0x00,0xf1]
subs xzr,	x0, #0                          // encoding: [0x1f,0x00,0x00,0xf1]

mov x0, x1
	mov	x0, x1                          // encoding: [0xe0,0x03,0x01,0xaa]
orr x0, xzr, x1
	mov	x0, x1                          // encoding: [0xe0,0x03,0x01,0xaa]

cset x0, eq
	cset	x0, eq                          // encoding: [0xe0,0x17,0x9f,0x9a]
csinc x0, xzr, xzr, ne 
	cset	x0, eq                          // encoding: [0xe0,0x17,0x9f,0x9a]
ldr x0, [x1, #8]
	ldr	x0, [x1, #8]                    // encoding: [0x20,0x04,0x40,0xf9]

ldr x0, [x1, #9]
	ldur	x0, [x1, #9]                    // encoding: [0x20,0x90,0x40,0xf8]
