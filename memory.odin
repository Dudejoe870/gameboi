package gameboi

import "core:fmt"

Memory_State :: struct {
	bootrom: []u8,
	rom: []u8,
	mapper: Rom_Mapper,

	ext_ram: []u8,

	ram: []u8,
	hram: [127]u8,

	joyp_select: Joyp_Select,
	joyp_dpad: Joyp_Dpad_Bits,
	joyp_buttons: Joyp_Button_Bits,

	bootrom_disable: u8,
}

Joyp_Select :: enum u8 {
	Dpad = 0b10,
	Buttons = 0b01,
	Both = 0b00,
	Neither = 0b11,
}

Joyp_Buttons :: enum {
	A = 0,
	B = 1,
	Select = 2,
	Start = 3,
}
Joyp_Button_Bits :: bit_set[Joyp_Buttons; u8]

Joyp_Dpad :: enum {
	Right = 0,
	Left = 1,
	Up = 2,
	Down = 3,
}
Joyp_Dpad_Bits :: bit_set[Joyp_Dpad; u8]

Rom_Mapper :: enum {
	None,
}

memory_init :: proc(mem: ^Memory_State, bootrom_data: []u8, rom_data: []u8) {
	mem.ram = make_slice([]u8, 8192)
	mem.bootrom = bootrom_data
	mem.rom = rom_data

	mem.joyp_select = .Neither
	mem.joyp_buttons = { }
	mem.joyp_dpad = { }
}

memory_read :: proc(state: Emulator_State, address: u16) -> u8 {
	mem := state.mem
	switch address {
	case 0x0000..=0x3FFF: // ROM Bank 00
		index := address
		if mem.bootrom_disable == 0 && index < 256 {
			return mem.bootrom[index]
		}
		return mem.rom[index]
	case 0x4000..=0x7FFF: // ROM Bank 01-NN
		index := address
		// TODO: Mapper bank switching
		return mem.rom[index]
	case 0x8000..=0x9FFF: // VRAM
		index := address - 0x8000
		return state.ppu.vram[index]
	case 0xC000..=0xDFFF: // WRAM (TODO: CGB switchable banks)
		index := address - 0xC000
		return mem.ram[index]
	case 0xE000..=0xFDFF: // Echo RAM
		index := address - 0xE000
		return mem.ram[index]
	case 0xFF00: // JOYP
		#partial switch mem.joyp_select {
		case .Buttons:
			return transmute(u8)~mem.joyp_buttons | (u8(mem.joyp_select) << 4)
		case .Dpad:
			return transmute(u8)~mem.joyp_dpad | (u8(mem.joyp_select) << 4)
		case:
			return 0x3F
		}
	case 0xFF04: // DIV
		return u8((state.timer.system_counter & 0x3FC0) >> 6)
	case 0xFF05: // TIMA
		return state.timer.tima
	case 0xFF06: // TMA
		return state.timer.tma
	case 0xFF07: // TAC
		return transmute(u8)state.timer.tac
	case 0xFF0F: // IF
		return transmute(u8)state.cpu.interrupt_flag
	case 0xFF42: // SCY
		return state.ppu.scroll_y
	case 0xFF43: // SCX
		return state.ppu.scroll_x
	case 0xFF44: // LY
		return state.ppu.v_counter
	case 0xFF50: // BANK
		return mem.bootrom_disable
	case 0xFF80..=0xFFFE: // HRAM
		index := address - 0xFF80
		return mem.hram[index]
	case 0xFFFF: // IE
		return transmute(u8)state.cpu.interrupt_enable
	}
	fmt.printfln("Read from unmapped address: %x, PC: 0x%x", address, state.cpu.pc)
	return 0
}

memory_write :: proc(state: ^Emulator_State, address: u16, value: u8) {
	mem := &state.mem
	switch address {
	case 0x8000..=0x9FFF: // VRAM
		index := address - 0x8000
		state.ppu.vram[index] = value
	case 0xC000..=0xDFFF: // WRAM (TODO: CGB switchable banks)
		index := address - 0xC000
		mem.ram[index] = value
	case 0xE000..=0xFDFF: // Echo RAM
		index := address - 0xE000
		mem.ram[index] = value
	case 0xFF00: // JOYP
		mem.joyp_select = Joyp_Select((value & 0b00110000) >> 4)
	case 0xFF04: // DIV
		state.timer.system_counter = 0
	case 0xFF05: // TIMA
		state.timer.tima_overflow_latch = false
		state.timer.tima = value
	case 0xFF06: // TMA
		state.timer.tma = value
	case 0xFF07: // TAC
		state.timer.tac = transmute(Timer_Tac)value
	case 0xFF0F: // IF
		state.cpu.interrupt_flag = transmute(Cpu_Interrupt_Bits)value
	case 0xFF42: // SCY
		state.ppu.scroll_y = value
	case 0xFF43: // SCX
		state.ppu.scroll_x = value
	case 0xFF50: // BANK
		mem.bootrom_disable = value
	case 0xFF80..=0xFFFE: // HRAM
		index := address - 0xFF80
		mem.hram[index] = value
	case 0xFFFF: // IE
		state.cpu.interrupt_enable = transmute(Cpu_Interrupt_Bits)value
	case:
		fmt.printfln("Write to unmapped address: 0x%x, value: 0x%x, PC: 0x%x", address, value, state.cpu.pc)
	}
}

memory_read_16 :: proc(state: Emulator_State, address: u16) -> u16 {
	return u16(memory_read(state, address)) | (u16(memory_read(state, address+1)) << 8)
}

memory_write_16 :: proc(state: ^Emulator_State, address: u16, value: u16) {
	memory_write(state, address,   u8(value &  0xFF))
	memory_write(state, address+1, u8(value >> 8   ))
}

