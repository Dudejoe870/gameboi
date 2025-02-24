package gameboi

import "base:intrinsics"

Timer_State :: struct {
	system_counter: u16,
	
	tma: u8,
	tac: Timer_Tac,
	tima: u8,
	
	tima_overflow_latch: bool,
}

Timer_Clock_Select :: enum u8 {
	_256_M_Cycles = 0b00,
	_4_M_Cycles   = 0b01,
	_16_M_Cycles  = 0b10,
	_64_M_Cycles  = 0b11,
}

Timer_Tac :: bit_field u8 {
	clock_select: Timer_Clock_Select | 2,
	enable: bool | 1,
}

timer_init :: proc(timer: ^Timer_State) {
	
}

timer_step :: proc(state: ^Emulator_State) {
	timer := &state.timer

	if timer.tima_overflow_latch {
		timer.tima = timer.tma
		cpu_raise_interrupts(&state.cpu, { .Timer })
		timer.tima_overflow_latch = false
	}
	
	previous_counter := timer.system_counter

	timer.system_counter += 1
	if timer.system_counter == 0x3FFF {
		timer.system_counter = 0
	}

	counter_bit_mask: u16
	switch timer.tac.clock_select {
	case ._256_M_Cycles:
		counter_bit_mask = 1 << 7
	case ._4_M_Cycles:
		counter_bit_mask = 1 << 1
	case ._16_M_Cycles:
		counter_bit_mask = 1 << 3
	case ._64_M_Cycles:
		counter_bit_mask = 1 << 5
	}

	current_bit := timer.system_counter & counter_bit_mask > 0 && timer.tac.enable
	previous_bit := previous_counter & counter_bit_mask > 0 && timer.tac.enable

	// Timer tick on falling edge :)
	if previous_bit && !current_bit {
		previous_tima := timer.tima
		timer.tima += 1
		// TIMA overflow on falling edge
		if previous_tima & 0x80 > 0 && timer.tima & 0x80 == 0 {
			timer.tima_overflow_latch = true
		}
	}
}

