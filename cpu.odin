package gameboi

Cpu_State :: struct {
	cycle_wait: int,

	// register file
	rf: struct #raw_union {
		_16: [Cpu_16bit_Register]u16,
		_8: [Cpu_8bit_Register]u8,
	},

	pc: u16,
	sp: u16,

	ime: bool,
	
	ime_enable_latch: bool,

	interrupt_enable: Cpu_Interrupt_Bits,
	interrupt_flag: Cpu_Interrupt_Bits,
}

Cpu_Interrupts :: enum {
	Vblank = 0,
	Lcd = 1,
	Timer = 2,
	Serial = 3,
	Joypad = 4,
}

Cpu_Interrupt_Bits :: bit_set[Cpu_Interrupts; u8]

Cpu_Flags :: bit_field u8 {
	_: int | 4,
	carry: bool | 1,
	half_carry: bool | 1,
	subtraction: bool | 1,
	zero: bool | 1,
}

Cpu_16bit_Register :: enum {
	AF,
	BC,
	DE,
	HL,
}

when ODIN_ENDIAN == .Big {
	Cpu_8bit_Register :: enum {
		A, F,
		B, C,
		D, E,
		H, L,
	}
} else {
	Cpu_8bit_Register :: enum {
		F, A,
		C, B,
		E, D,
		L, H,
	}
}

cpu_init :: proc(cpu: ^Cpu_State) {
	cpu_reset(cpu)
}

cpu_reset :: proc(cpu: ^Cpu_State) {
	
}

cpu_raise_interrupts :: proc(cpu: ^Cpu_State, interrupts: Cpu_Interrupt_Bits) {
	cpu.interrupt_flag |= interrupts
}

_cpu_get_flags :: proc(cpu: ^Cpu_State) -> ^Cpu_Flags {
	return cast(^Cpu_Flags)&cpu.rf._8[.F]
}

