package gameboi

Ppu_State :: struct {
	h_counter: int,
	v_counter: u8,
	mode: Ppu_Mode_State,

	vram: [8192]u8,
	oam: [160]u8,

	scroll_y: u8,
	scroll_x: u8,

	screen_pixel_data: [160 * 144]u32,
	screen_palette: [4]u32,
}

DEFAULT_PALETTE :: [4]u32 {
	0xFFFFFFFF,
	0xFF7F7F7F,
	0xFF3F3F3F,
	0xFF000000,
}

Ppu_Mode_State :: union {
	Ppu_Oam_Scan_State,
	Ppu_Pixel_Write_State,
	Ppu_Horizontal_Blank_State,
	Ppu_Vertical_Blank_State,
}

Ppu_Oam_Scan_State :: struct {
	cycle_counter: int,
}

Ppu_Pixel_Write_State :: struct {
	cycle_counter: int,
	pixel_x: int,
}

Ppu_Horizontal_Blank_State :: struct {
	
}

Ppu_Vertical_Blank_State :: struct {
	
}

ppu_init :: proc(ppu: ^Ppu_State) {
	ppu.screen_palette = DEFAULT_PALETTE
	ppu.mode = Ppu_Oam_Scan_State {}
}

ppu_step :: proc(state: ^Emulator_State) {
	ppu := &state.ppu
	
	switch &mode in ppu.mode {
	case Ppu_Oam_Scan_State:
		mode.cycle_counter += 1
		if mode.cycle_counter == 80 {
			ppu.mode = Ppu_Pixel_Write_State {}
			break
		}
	case Ppu_Pixel_Write_State:
		if mode.cycle_counter >= 12 {
			_ppu_render_pixel(ppu, mode.pixel_x, int(ppu.v_counter))
			mode.pixel_x += 1
		}
		
		mode.cycle_counter += 1
		// TODO: Simulate Mode 3 (Pixel Write) cycle penalties.
		if mode.cycle_counter == 172 {
			ppu.mode = Ppu_Horizontal_Blank_State {}
			break
		}
	case Ppu_Horizontal_Blank_State:
	case Ppu_Vertical_Blank_State:
	}

	ppu.h_counter += 1
	if ppu.h_counter == 456 {
		ppu.h_counter = 0
		ppu.v_counter += 1
		if ppu.v_counter == 144 {
			ppu.mode = Ppu_Vertical_Blank_State {}
			cpu_raise_interrupts(&state.cpu, { .Vblank })
		}
		if _, is_vblank := ppu.mode.(Ppu_Vertical_Blank_State); !is_vblank {
			ppu.mode = Ppu_Oam_Scan_State {}
		}
		if ppu.v_counter == 154 {
			ppu.v_counter = 0
			ppu.mode = Ppu_Oam_Scan_State {}
		}
	}
}

_ppu_render_pixel_palette_index :: proc(ppu: ^Ppu_State, x: int, y: int) -> int {
	return 0
}

_ppu_render_pixel :: proc(ppu: ^Ppu_State, x: int, y: int) {
	palette_index := _ppu_render_pixel_palette_index(ppu, x, y)
	ppu.screen_pixel_data[x + y * 160] = ppu.screen_palette[palette_index]
}

