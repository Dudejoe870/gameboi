package gameboi

import "base:intrinsics"
import "core:math/bits"
import "core:fmt"

// TODO: Implement actual cycle-accuracy by
// doing the individual steps of the instruction
// on the appropriate cycles.
cpu_step :: proc(state: ^Emulator_State) {
	cpu := &state.cpu
	
	if cpu.cycle_wait > 0 {
		cpu.cycle_wait -= 1
		return
	}

	if cpu.ime {
		pending_interrupts := cpu.interrupt_enable & cpu.interrupt_flag

		interrupt_handler: Maybe(u16) = nil
		if .Vblank in pending_interrupts {
			interrupt_handler = 0x40
			cpu.interrupt_flag -= { .Vblank }
		} else if .Lcd in pending_interrupts {
			interrupt_handler = 0x48
			cpu.interrupt_flag -= { .Lcd }
		} else if .Timer in pending_interrupts {
			interrupt_handler = 0x50
			cpu.interrupt_flag -= { .Timer }
		} else if .Serial in pending_interrupts {
			interrupt_handler = 0x58
			cpu.interrupt_flag -= { .Serial }
		} else if .Joypad in pending_interrupts {
			interrupt_handler = 0x60
			cpu.interrupt_flag -= { .Joypad }
		}
		if address, ok := interrupt_handler.?; ok {
			cpu.ime = false

			memory_write_16(state, cpu.sp, cpu.pc)
			cpu.sp -= 2

			cpu.pc = address
			cpu.cycle_wait = 4
			return
		}
	}

	if cpu.ime_enable_latch {
		cpu.ime = true
		cpu.ime_enable_latch = false
	}

	flags := _cpu_get_flags(cpu)

	opcode := memory_read(state^, cpu.pc)
	opcode_block := (opcode & 0b11000000) >> 6

	main_block: switch opcode_block {
	case 0:
		if opcode == 0x00 { // nop
			cpu.pc += 1
			return
		}

		sub_op := opcode & 0b00000111
		switch sub_op {
		case 0b001: 
			operand := (opcode & 0b00110000) >> 4
			#partial switch r16 in _cpu_decode_r16(cpu, operand) {
			case Cpu_Decoded_Register_16:
				if opcode & 0b00001000 > 0 { // add hl, r16
					a := cpu.rf._16[.HL]
					b := r16^
					cpu.rf._16[.HL], flags.carry = intrinsics.overflow_add(a, b)
					flags.half_carry = ((a & 0xFFF) + (b & 0xFFF)) & 0x1000 > 0
					flags.subtraction = false
					
					cpu.pc += 1
					cpu.cycle_wait = 1
				} else { // ld r16, imm16
					imm := memory_read_16(state^, cpu.pc + 1)
					r16^ = imm
					
					cpu.pc += 3
					cpu.cycle_wait = 2
				}
			case:
				panic("Unsupported operand!")
			}
			return
		case 0b010:
			operand := (opcode & 0b00110000) >> 4
			r_or_w  := (opcode & 0b00001000) > 0
			#partial switch r16mem in _cpu_decode_r16mem(cpu, operand) {
			case Cpu_Decoded_Address:
				if r_or_w { // ld a, [r16mem]
					cpu.rf._8[.A] = memory_read(state^, r16mem)
				} else { // ld [r16mem], a
					memory_write(state, r16mem, cpu.rf._8[.A])
				}
			case:
				panic("Unsupported operand!")
			}
			cpu.pc += 1
			cpu.cycle_wait = 1
			return
		case 0b000:
			if opcode & 0b00100000 > 0 { // jr cond, imm8
				cond := (opcode & 0b00011000) >> 3
				if _cpu_decode_cond(cpu^, cond) {
					cpu.pc = u16(i16(cpu.pc + 2) + i16(transmute(i8)memory_read(state^, cpu.pc + 1)))
					cpu.cycle_wait = 2
				} else {
					cpu.pc += 2
					cpu.cycle_wait = 1
				}
			} else {
				sub_sub_op := (opcode & 0b00011000) >> 3
				switch sub_sub_op {
				case 0b01: // ld [imm16], sp
					imm := memory_read_16(state^, cpu.pc + 1)
					memory_write_16(state, imm, cpu.sp)
					cpu.pc += 3
					cpu.cycle_wait = 4
				case 0b11: // jr imm8
					cpu.pc = u16(i16(cpu.pc + 2) + i16(transmute(i8)memory_read(state^, cpu.pc + 1)))
					cpu.cycle_wait = 2
				case 0b10: // stop
					panic("The stop instruction isn't currently supported... it's weird.")
				}
			}
			return
		case 0b011:
			operand := (opcode & 0b00110000) >> 4
			should_decrement := (opcode & 0b00001000) > 0
			#partial switch r16 in _cpu_decode_r16(cpu, operand) {
			case Cpu_Decoded_Register_16:
				if should_decrement { // dec r16
					r16^ -= 1
				} else { // inc r16
					r16^ += 1
				}
			case:
				panic("Unsupported operand!")
			}
			cpu.pc += 1
			cpu.cycle_wait = 1
			return
		case 0b100: // inc r8
			operand := (opcode & 0b00111000) >> 3
			#partial switch r8 in _cpu_decode_r8(cpu, operand) {
			case Cpu_Decoded_Register_8:
				original_value := r8^
				r8^ += 1
				
				flags.zero = r8^ == 0
				flags.subtraction = false
				flags.half_carry = original_value & 0xF == 0xF
			case Cpu_Decoded_Address:
				value := memory_read(state^, r8)
				result := value + 1
				memory_write(state, r8, result)
				
				flags.zero = result == 0
				flags.subtraction = false
				flags.half_carry = value & 0xF == 0xF
				
				cpu.cycle_wait = 2
			case:
				panic("Unsupported operand!")
			}
			cpu.pc += 1
			return
		case 0b101: // dec r8
			operand := (opcode & 0b00111000) >> 3
			#partial switch r8 in _cpu_decode_r8(cpu, operand) {
			case Cpu_Decoded_Register_8:
				original_value := r8^
				r8^ -= 1
				
				flags.zero = r8^ == 0
				flags.subtraction = true
				flags.half_carry = original_value & 0xF == 0x0
			case Cpu_Decoded_Address:
				value := memory_read(state^, r8)
				result := value - 1
				memory_write(state, r8, result)
				
				flags.zero = result == 0
				flags.subtraction = true
				flags.half_carry = value & 0xF == 0x0
				
				cpu.cycle_wait = 2
			case:
				panic("Unsupported operand!")
			}
			cpu.pc += 1
			return
		case 0b110: // ld r8, imm8
			dest := (opcode & 0b00111000) >> 3
			imm := memory_read(state^, cpu.pc + 1)
			#partial switch r8 in _cpu_decode_r8(cpu, dest) {
			case Cpu_Decoded_Register_8:
				r8^ = imm
				cpu.cycle_wait = 1
			case Cpu_Decoded_Address:
				memory_write(state, r8, imm)
				cpu.cycle_wait = 2
			case:
				panic("Unsupported operand!")
			}
			cpu.pc += 2
			return
		case 0b111:
			sub_sub_op := (opcode & 0b00111000) >> 3
			switch sub_sub_op {
			case 0b000: // rlca
				flags.carry = cpu.rf._8[.A] & 0b10000000 > 0
				cpu.rf._8[.A] = bits.rotate_left8(cpu.rf._8[.A], 1)
				
				flags.zero = false
				flags.subtraction = false
				flags.half_carry = false
			case 0b001: // rrca
				flags.carry = cpu.rf._8[.A] & 0b00000001 > 0
				cpu.rf._8[.A] = bits.rotate_left8(cpu.rf._8[.A], -1)
				
				flags.zero = false
				flags.subtraction = false
				flags.half_carry = false
			case 0b010: // rla
				carry_bit: u8 = 1 if flags.carry else 0
				flags.carry = cpu.rf._8[.A] & 0b10000000 > 0
				cpu.rf._8[.A] = (bits.rotate_left8(cpu.rf._8[.A], 1) & ~u8(0x01)) | carry_bit
				
				flags.zero = false
				flags.subtraction = false
				flags.half_carry = false
			case 0b011: // rra
				carry_bit: u8 = 1 if flags.carry else 0
				flags.carry = cpu.rf._8[.A] & 0b00000001 > 0
				cpu.rf._8[.A] = (bits.rotate_left8(cpu.rf._8[.A], -1) & ~u8(0x80)) | (carry_bit << 7)
				
				flags.zero = false
				flags.subtraction = false
				flags.half_carry = false
			case 0b100: // daa
				if flags.subtraction {
					adjustment: u8
					if flags.half_carry {
						adjustment += 0x06
					}
					if flags.carry {
						adjustment += 0x60
					}
					cpu.rf._8[.A], flags.carry = intrinsics.overflow_sub(cpu.rf._8[.A], adjustment)
				} else {
					adjustment: u8
					if flags.half_carry || cpu.rf._8[.A] & 0xF > 0x9 {
						adjustment += 0x06
					}
					if flags.carry || cpu.rf._8[.A] > 0x99 {
						adjustment += 0x60
					}
					cpu.rf._8[.A], flags.carry = intrinsics.overflow_add(cpu.rf._8[.A], adjustment)
				}
				flags.zero = cpu.rf._8[.A] == 0
				flags.half_carry = false
			case 0b101: // cpl
				cpu.rf._8[.A] = ~cpu.rf._8[.A]
				flags.subtraction = true
				flags.half_carry = true
			case 0b110: // scf
				flags.subtraction = false
				flags.half_carry = false
				flags.carry = true
			case 0b111: // ccf
				flags.subtraction = false
				flags.half_carry = false
				flags.carry = !flags.carry
			}
			cpu.pc += 1
			return
		}
	case 1: // ld r8, r8 (most of the time)
		dest   := (opcode & 0b00111000) >> 3
		source := (opcode & 0b00000111)
		if dest == 0b110 && source == 0b110 { // halt
			fmt.println("halt not currently implemented...")
			cpu.pc += 1
			return
		}
		
		value: u8
		#partial switch source_r8 in _cpu_decode_r8(cpu, source) {
		case Cpu_Decoded_Register_8:
			value = source_r8^
		case Cpu_Decoded_Address:
			value = memory_read(state^, source_r8)
			cpu.cycle_wait = 1
		case:
			panic("Unsupported operand!")
		}

		#partial switch dest_r8 in _cpu_decode_r8(cpu, dest) {
		case Cpu_Decoded_Register_8:
			dest_r8^ = value
		case Cpu_Decoded_Address:
			memory_write(state, dest_r8, value)
			cpu.cycle_wait = 1
		case:
			panic("Unsupported operand!")
		}
		cpu.pc += 1
		return
	case 2: // 8-bit arithmetic
		operand := (opcode & 0b00000111)

		a := cpu.rf._8[.A]

		b: u8
		#partial switch r8 in _cpu_decode_r8(cpu, operand) {
		case Cpu_Decoded_Register_8:
			b = r8^
		case Cpu_Decoded_Address:
			b = memory_read(state^, r8)
			cpu.cycle_wait = 1
		case:
			panic("Unsupported operand!")
		}

		sub_op := (opcode & 0b00111000) >> 3
		switch sub_op {
		case 0b001: // adc a, r8
			b += 1 if flags.carry else 0
			fallthrough
		case 0b000: // add a, r8
			cpu.rf._8[.A], flags.carry = intrinsics.overflow_add(a, b)
			flags.zero = cpu.rf._8[.A] == 0
			flags.half_carry = ((a & 0xF) + (b & 0xF)) & 0x10 > 0
			flags.subtraction = false
		case 0b011: // sbc a, r8
			b += 1 if flags.carry else 0
			fallthrough
		case 0b010: // sub a, r8
			cpu.rf._8[.A], flags.carry = intrinsics.overflow_sub(a, b)
			flags.zero = cpu.rf._8[.A] == 0
			flags.half_carry = (b & 0xF) > (a & 0xF)
			flags.subtraction = true
		case 0b100: // and a, r8
			cpu.rf._8[.A] = a & b
			flags.zero = cpu.rf._8[.A] == 0
			flags.subtraction = false
			flags.half_carry = true
			flags.carry = false
		case 0b101: // xor a, r8
			cpu.rf._8[.A] = a ~ b
			flags.zero = cpu.rf._8[.A] == 0
			flags.subtraction = false
			flags.half_carry = false
			flags.carry = false
		case 0b110: // or a, r8
			cpu.rf._8[.A] = a | b
			flags.zero = cpu.rf._8[.A] == 0
			flags.subtraction = false
			flags.half_carry = false
			flags.carry = false
		case 0b111: // cp a, r8
			flags.zero = a == b
			flags.subtraction = true
			flags.half_carry = (b & 0xF) > (a & 0xF)
			flags.carry = b > a
		}
		cpu.pc += 1
		return
	case 3:
		sub_op := (opcode & 0b00000111)
		switch sub_op {
		case 0b110:
			a := cpu.rf._8[.A]
			b := memory_read(state^, cpu.pc + 1)
			
			sub_sub_op := (opcode & 0b00111000) >> 3
			switch sub_sub_op {
			case 0b001: // adc a, imm8
				b += 1 if flags.carry else 0
				fallthrough
			case 0b000: // add a, imm8
				cpu.rf._8[.A], flags.carry = intrinsics.overflow_add(a, b)
				flags.zero = cpu.rf._8[.A] == 0
				flags.half_carry = ((a & 0xF) + (b & 0xF)) & 0x10 > 0
				flags.subtraction = false
			case 0b011: // sbc a, imm8
				b += 1 if flags.carry else 0
				fallthrough
			case 0b010: // sub a, imm8
				cpu.rf._8[.A], flags.carry = intrinsics.overflow_sub(a, b)
				flags.zero = cpu.rf._8[.A] == 0
				flags.half_carry = (b & 0xF) > (a & 0xF)
				flags.subtraction = true
			case 0b100: // and a, imm8
				cpu.rf._8[.A] = a & b
				flags.zero = cpu.rf._8[.A] == 0
				flags.subtraction = false
				flags.half_carry = true
				flags.carry = false
			case 0b101: // xor a, imm8
				cpu.rf._8[.A] = a ~ b
				flags.zero = cpu.rf._8[.A] == 0
				flags.subtraction = false
				flags.half_carry = false
				flags.carry = false
			case 0b110: // or a, imm8
				cpu.rf._8[.A] = a | b
				flags.zero = cpu.rf._8[.A] == 0
				flags.subtraction = false
				flags.half_carry = false
				flags.carry = false
			case 0b111: // cp a, imm8
				flags.zero = a == b
				flags.subtraction = true
				flags.half_carry = (b & 0xF) > (a & 0xF)
				flags.carry = b > a
			}
			cpu.pc += 2
			cpu.cycle_wait = 1
			return
		case 0b000:
			if opcode & 0b00100000 > 0 {
				imm := memory_read(state^, cpu.pc + 1)
				sub_sub_op := (opcode & 0b00011000) >> 3
				switch sub_sub_op {
				case 0: // ldh [imm8], a
					memory_write(state, 0xFF00 + u16(imm), cpu.rf._8[.A])
					cpu.cycle_wait = 2
				case 1: // add sp, imm8
					a := cpu.sp
					b := transmute(u16)i16(transmute(i8)imm)
					
					cpu.sp, flags.carry = intrinsics.overflow_add(a, b)
					flags.zero = false
					flags.subtraction = false
					flags.half_carry = ((a & 0xF) + (b & 0xF)) & 0x10 > 0
					cpu.cycle_wait = 3
				case 2: // ldh a, [imm8]
					cpu.rf._8[.A] = memory_read(state^, 0xFF00 + u16(imm))
					cpu.cycle_wait = 2
				case 3: // ld hl, sp + imm8
					a := cpu.sp
					b := transmute(u16)i16(transmute(i8)imm)
					
					cpu.rf._16[.HL], flags.carry = intrinsics.overflow_add(a, b)
					flags.zero = false
					flags.subtraction = false
					flags.half_carry = ((a & 0xF) + (b & 0xF)) & 0x10 > 0
					cpu.cycle_wait = 2
				}
				cpu.pc += 2
				return
			} else { // ret cond
				cond := (opcode & 0b00111000) >> 3
				if _cpu_decode_cond(cpu^, cond) {
					cpu.sp += 2
					cpu.pc = memory_read_16(state^, cpu.sp)
					cpu.cycle_wait = 4
				} else {
					cpu.pc += 1
					cpu.cycle_wait = 1
				}
				return
			}
		case 0b001:
			if opcode & 0b00001000 > 0 {
				if opcode & 0b00100000 > 0 {
					sub_sub_op := (opcode & 0b00011000) >> 3
					switch sub_sub_op {
					case 0b01: // jp hl
						cpu.pc = cpu.rf._16[.HL]
						return
					case 0b11: // ld sp, hl
						cpu.sp = cpu.rf._16[.HL]
						cpu.pc += 1
						cpu.cycle_wait = 1
						return
					}
				} else { // ret
					enable_interrupts := (opcode & 0b00010000) > 0
					cpu.sp += 2
					cpu.pc = memory_read_16(state^, cpu.sp)
					cpu.cycle_wait = 3

					if enable_interrupts { // reti
						cpu.ime = true
					}
					return
				}
			} else { // pop r16stk
				operand := (opcode & 0b00110000) >> 4
				#partial switch r16 in _cpu_decode_r16stk(cpu, operand) {
				case Cpu_Decoded_Register_16:
					cpu.sp += 2
					r16^ = memory_read_16(state^, cpu.sp)
				case:
					panic("Unsupported operand!")
				}
				cpu.pc += 1
				cpu.cycle_wait = 2
				return
			}
		case 0b010:
			if opcode & 0b00100000 > 0 {
				sub_sub_op := (opcode & 0b00011000) >> 3
				switch sub_sub_op {
				case 0: // ldh [c], a
					memory_write(state, 0xFF00 + u16(cpu.rf._8[.C]), cpu.rf._8[.A])
					cpu.pc += 1
					cpu.cycle_wait = 1
					return
				case 1: // ld [imm16], a
					imm := memory_read_16(state^, cpu.pc + 1)
					memory_write(state, imm, cpu.rf._8[.A])
					cpu.pc += 3
					cpu.cycle_wait = 3
					return
				case 2: // ldh a, [c]
					cpu.rf._8[.A] = memory_read(state^, 0xFF00 + u16(cpu.rf._8[.C]))
					cpu.pc += 1
					cpu.cycle_wait = 1
					return
				case 3: // ld a, [imm16]
					imm := memory_read_16(state^, cpu.pc + 1)
					cpu.rf._8[.A] = memory_read(state^, imm)
					cpu.pc += 3
					cpu.cycle_wait = 3
					return
				}
			} else { // jp cond, imm16
				imm := memory_read_16(state^, cpu.pc + 1)
				cond := (opcode & 0b00011000) >> 3
				if _cpu_decode_cond(cpu^, cond) {
					cpu.pc = imm
					cpu.cycle_wait = 3
				} else {
					cpu.pc += 3
					cpu.cycle_wait = 2
				}
				return
			}
		case 0b011:
			sub_sub_op := (opcode & 0b00111000) >> 3
			switch sub_sub_op {
			case 0b000: // jp imm16
				imm := memory_read_16(state^, cpu.pc + 1)
				cpu.pc = imm
				cpu.cycle_wait = 3
				return
			case 0b001: // 0xCB prefixed instructions
				cb_opcode := memory_read(state^, cpu.pc + 1)
				cb_block := (cb_opcode & 0b11000000) >> 6
				operand := (cb_opcode & 0b00000111)
				decoded_operand := _cpu_decode_r8(cpu, operand)
				
				switch cb_block {
				case 0:
					cb_sub_op := (cb_opcode & 0b00111000) >> 3
					switch cb_sub_op {
					case 0b000: // rlc r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b10000000 > 0
							
							r8^ = bits.rotate_left8(r8^, 1)
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b10000000 > 0
							
							result := bits.rotate_left8(value, 1)
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					case 0b001: // rrc r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b00000001 > 0
							
							r8^ = bits.rotate_left8(r8^, -1)
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b00000001 > 0
							
							result := bits.rotate_left8(value, -1)
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					case 0b010: // rl r8
						carry_bit: u8 = 1 if flags.carry else 0

						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b10000000 > 0
							
							r8^ = (bits.rotate_left8(r8^, 1) & ~u8(0x01)) | carry_bit
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b10000000 > 0
							
							result := (bits.rotate_left8(value, 1) & ~u8(0x01)) | carry_bit
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					case 0b011: // rr r8
						carry_bit: u8 = 1 if flags.carry else 0

						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b00000001 > 0
							
							r8^ = (bits.rotate_left8(r8^, -1) & ~u8(0x80)) | (carry_bit << 7)
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b00000001 > 0
							
							result := (bits.rotate_left8(value, -1) & ~u8(0x80)) | (carry_bit << 7)
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					case 0b100: // sla r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b10000000 > 0
							
							r8^ <<= 1
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b10000000 > 0
							
							result := value << 1
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					case 0b101: // sra r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b00000001 > 0
							
							r8^ = transmute(u8)(transmute(i8)r8^ >> 1)
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b00000001 > 0
							
							result := transmute(u8)(transmute(i8)value >> 1)
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						cpu.pc += 2
						return
					case 0b110: // swap r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							r8^ = ((r8^ & 0xF) << 4) | ((r8^ & 0xF0) >> 4)
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							
							result := ((value & 0xF) << 4) | ((value & 0xF0) >> 4)
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						flags.carry = false
						cpu.pc += 2
						return
					case 0b111: // srl r8
						#partial switch r8 in decoded_operand {
						case Cpu_Decoded_Register_8:
							flags.carry = r8^ & 0b00000001 > 0
							
							r8^ >>= 1
							
							flags.zero = r8^ == 0
							cpu.cycle_wait = 1
						case Cpu_Decoded_Address:
							value := memory_read(state^, r8)
							flags.carry = value & 0b00000001 > 0
							
							result := value >> 1
							memory_write(state, r8, result)
							
							flags.zero = result == 0
							cpu.cycle_wait = 3
						case:
							panic("Unsupported operand!")
						}
						
						flags.subtraction = false
						flags.half_carry = false
						
						cpu.pc += 2
						return
					}
				case 1: // bit b3, r8
					bit_index := (cb_opcode & 0b00111000) >> 3
					#partial switch r8 in decoded_operand {
					case Cpu_Decoded_Register_8:
						flags.zero = r8^ & (1 << bit_index) == 0
						cpu.cycle_wait = 1
					case Cpu_Decoded_Address:
						flags.zero = memory_read(state^, r8) & (1 << bit_index) == 0
						cpu.cycle_wait = 2
					case:
						panic("Unsupported operand!")
					}
					
					flags.subtraction = false
					flags.half_carry = true
					
					cpu.pc += 2
					return
				case 2: // res b3, r8
					bit_index := (cb_opcode & 0b00111000) >> 3
					#partial switch r8 in decoded_operand {
					case Cpu_Decoded_Register_8:
						r8^ &= ~(1 << bit_index)
						cpu.cycle_wait = 1
					case Cpu_Decoded_Address:
						value := memory_read(state^, r8)
						memory_write(state, r8, value & ~(1 << bit_index))
						cpu.cycle_wait = 2
					case:
						panic("Unsupported operand!")
					}
					
					cpu.pc += 2
					return
				case 3: // set b3, r8
					bit_index := (cb_opcode & 0b00111000) >> 3
					#partial switch r8 in decoded_operand {
					case Cpu_Decoded_Register_8:
						r8^ |= 1 << bit_index
						cpu.cycle_wait = 1
					case Cpu_Decoded_Address:
						value := memory_read(state^, r8)
						memory_write(state, r8, value | (1 << bit_index))
						cpu.cycle_wait = 2
					case:
						panic("Unsupported operand!")
					}
					
					cpu.pc += 2
					return
				}
			case 0b110: // di
				cpu.ime = false
				cpu.ime_enable_latch = false
				cpu.pc += 1
				return
			case 0b111: // ei
				cpu.ime_enable_latch = true
				cpu.pc += 1
				return
			}
		case 0b100: // call cond, imm16
			if opcode & 0b00100000 > 0 {
				break main_block // Not a valid opcode
			}
			cond := (opcode & 0b00011000) >> 3
			imm := memory_read_16(state^, cpu.pc + 1)
			if _cpu_decode_cond(cpu^, cond) {
				memory_write_16(state, cpu.sp, cpu.pc + 3)
				cpu.sp -= 2
				
				cpu.pc = imm
				cpu.cycle_wait = 5
			} else {
				cpu.pc += 3
				cpu.cycle_wait = 2
			}
			return
		case 0b101:
			if opcode & 0b00001000 > 0 { // call imm16
				if opcode & 0b00110000 > 0 {
					break main_block // Not a valid opcode
				}
				imm := memory_read_16(state^, cpu.pc + 1)

				memory_write_16(state, cpu.sp, cpu.pc + 3)
				cpu.sp -= 2
				
				cpu.pc = imm
				cpu.cycle_wait = 5
				return
			} else { // push r16stk
				operand := (opcode & 0b00110000) >> 4
				#partial switch r16 in _cpu_decode_r16stk(cpu, operand) {
				case Cpu_Decoded_Register_16:
					memory_write_16(state, cpu.sp, r16^)
					cpu.sp -= 2
				case:
					panic("Unsupported operand!")
				}
				cpu.pc += 1
				cpu.cycle_wait = 3
				return
			}
		case 0b111: // rst tgt3
			target := (opcode & 0b00111000) >> 3

			cpu.pc = u16(target) << 4
			cpu.cycle_wait = 3
			return
		}
	}

	panic("Unimplemented SM83 instruction!")
}

Cpu_Decoded_Operand :: union {
	Cpu_Decoded_Register_8,
	Cpu_Decoded_Register_16,
	Cpu_Decoded_Address,
}

Cpu_Decoded_Register_16 :: ^u16
Cpu_Decoded_Register_8 :: ^u8
Cpu_Decoded_Address :: u16

_cpu_decode_r8 :: #force_inline proc(cpu: ^Cpu_State, operand: u8) -> Cpu_Decoded_Operand {
	switch operand {
	case 0:
		return &cpu.rf._8[.B]
	case 1:
		return &cpu.rf._8[.C]
	case 2:
		return &cpu.rf._8[.D]
	case 3:
		return &cpu.rf._8[.E]
	case 4:
		return &cpu.rf._8[.H]
	case 5:
		return &cpu.rf._8[.L]
	case 6:
		return cpu.rf._16[.HL]
	case 7:
		return &cpu.rf._8[.A]
	}
	panic("Operand out of range!!!")
}

_cpu_decode_r16 :: #force_inline proc(cpu: ^Cpu_State, operand: u8) -> Cpu_Decoded_Operand {
	switch operand {
	case 0:
		return &cpu.rf._16[.BC]
	case 1:
		return &cpu.rf._16[.DE]
	case 2:
		return &cpu.rf._16[.HL]
	case 3:
		return &cpu.sp
	}
	panic("Operand out of range!!!")
}

_cpu_decode_r16stk :: #force_inline proc(cpu: ^Cpu_State, operand: u8) -> Cpu_Decoded_Operand {
	switch operand {
	case 0:
		return &cpu.rf._16[.BC]
	case 1:
		return &cpu.rf._16[.DE]
	case 2:
		return &cpu.rf._16[.HL]
	case 3:
		return &cpu.rf._16[.AF]
	}
	panic("Operand out of range!!!")
}

_cpu_decode_r16mem :: #force_inline proc(cpu: ^Cpu_State, operand: u8) -> Cpu_Decoded_Operand {
	switch operand {
	case 0:
		return cpu.rf._16[.BC]
	case 1:
		return cpu.rf._16[.DE]
	case 2: // [hl+]
		value := cpu.rf._16[.HL]
		cpu.rf._16[.HL] += 1
		return value
	case 3: // [hl-]
		value := cpu.rf._16[.HL]
		cpu.rf._16[.HL] -= 1
		return value
	}
	panic("Operand out of range!!!")
}

_cpu_decode_cond :: #force_inline proc(cpu: Cpu_State, operand: u8) -> bool {
	flags := Cpu_Flags(cpu.rf._8[.F])
	switch operand {
	case 0:
		return !flags.zero
	case 1:
		return flags.zero
	case 2:
		return !flags.carry
	case 3:
		return flags.carry
	}
	panic("Operand out of range!!!")
}

