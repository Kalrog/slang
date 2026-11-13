.text
.globl _add3
.p2align 2
_add3:
  add x0, x0, x1
  add x0, x0, x2
  ret


	movz	w0, #42                         // encoding: [0x40,0x05,0x80,0x52]
                                        // =0x2a
	movz	x0, #0                          // encoding: [0x00,0x00,0x80,0x52]
                                        // =0x0
	movz	x0, #0                          // encoding: [0x00,0x00,0x80,0xd2]
                                        // =0x0