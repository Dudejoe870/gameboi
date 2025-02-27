package gameboi

Ppu_State :: struct {
	h_counter: int,
	v_counter: u8,
	mode: Ppu_Mode_State,

	lcd_control: Lcd_Control,
	
	vram: [8192]u8,
	oam: [160]u8,
	vram_accessor: Ppu_Memory_Accessor,
	oam_accessor: Ppu_Memory_Accessor,

	window_x: u8,
	window_y: u8,

	scroll_y: u8,
	scroll_x: u8,

	bg_win_palette: u8,
	object_palette_0: u8,
	object_palette_1: u8,

	screen_pixel_data: [160 * 144]u32,
	screen_palette: [4]u32,
}

Ppu_Memory_Accessor :: enum {
	Cpu,
	Ppu,
}

Ppu_Obj_Size :: enum u8 {
	_8x8 = 0,
	_8x16 = 1,
}

Ppu_Tilemap_Area :: enum {
	_9800 = 0,
	_9C00 = 1,
}

Ppu_Tile_Addressing_Mode :: enum {
	Unsigned = 0,
	Signed = 1,
}

Lcd_Control :: bit_field u8 {
	bg_win_enable: bool | 1, // TODO: Means something different in CGB mode
	obj_enable: bool | 1,
	obj_size: Ppu_Obj_Size | 1,
	bg_tilemap_area: Ppu_Tilemap_Area | 1,
	tilemap_addressing_mode: Ppu_Tile_Addressing_Mode | 1,
	win_enable: bool | 1,
	win_tilemap_area: Ppu_Tilemap_Area | 1,
	lcd_enable: bool | 1,
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
	pixel_x: u8,
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

	if !ppu.lcd_control.lcd_enable {
		for &pixel in ppu.screen_pixel_data {
			pixel = 0x00000000
		}
		state.ppu.vram_accessor = .Cpu
		state.ppu.oam_accessor = .Cpu
		return
	}
	
	switch &mode in ppu.mode {
	case Ppu_Oam_Scan_State:
		ppu.vram_accessor = .Cpu
		ppu.oam_accessor = .Ppu
		
		mode.cycle_counter += 1
		if mode.cycle_counter == 80 {
			ppu.mode = Ppu_Pixel_Write_State {}
			break
		}
	case Ppu_Pixel_Write_State:
		ppu.vram_accessor = .Ppu
		
		if mode.cycle_counter >= 12 {
			_ppu_render_pixel(ppu, mode.pixel_x, ppu.v_counter)
			mode.pixel_x += 1
		}
		
		mode.cycle_counter += 1
		// TODO: Simulate Mode 3 (Pixel Write) cycle penalties.
		if mode.cycle_counter == 172 {
			ppu.mode = Ppu_Horizontal_Blank_State {}
			break
		}
	case Ppu_Horizontal_Blank_State:
		ppu.vram_accessor = .Cpu
		ppu.oam_accessor = .Cpu
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

_ppu_render_pixel_palette_index :: proc(ppu: ^Ppu_State, x: u8, y: u8) -> u8 {
	bg_x := x + ppu.scroll_x
	bg_y := y + ppu.scroll_y

	bg_tile_x := bg_x / 8
	bg_tile_y := bg_y / 8

	win_x := x + (ppu.window_x - 7)
	win_y := y + ppu.window_y

	win_tile_x := win_x / 8
	win_tile_y := win_y / 8

	bg_tilemap_offset: u16 = 0x1800
	if ppu.lcd_control.bg_tilemap_area == ._9C00 {
		bg_tilemap_offset |= 0x0400
	}
	bg_tilemap_offset |=  u16(bg_tile_x) & 0x1F
	bg_tilemap_offset |= (u16(bg_tile_y) & 0x1F) << 5
	
	win_tilemap_offset: u16 = 0x1800
	if ppu.lcd_control.win_tilemap_area == ._9C00 {
		win_tilemap_offset |= 0x0400
	}
	win_tilemap_offset |=  u16(win_tile_x) & 0x1F
	win_tilemap_offset |= (u16(win_tile_y) & 0x1F) << 5

	bg_tile_id  := _ppu_read_vram(ppu, bg_tilemap_offset)
	win_tile_id := _ppu_read_vram(ppu, win_tilemap_offset)

	bg_tile_data_offset: u16
	win_tile_data_offset: u16
	switch ppu.lcd_control.tilemap_addressing_mode {
	case .Unsigned:
		bg_tile_data_offset = u16(bg_tile_id) * 16
		win_tile_data_offset = u16(win_tile_id) * 16
	case .Signed:
		bg_tile_data_offset = u16(0x1000 + (i16(transmute(i8)bg_tile_id) * 16))
		win_tile_data_offset = u16(0x1000 + (i16(transmute(i8)win_tile_id) * 16))
	}

	bg_pixel_x := bg_x % 8
	bg_pixel_y := bg_y % 8

	win_pixel_x := win_x % 8
	win_pixel_y := win_y % 8

	bg_tile_line_offset := bg_tile_data_offset + u16(bg_pixel_y * 2)

	bg_tile_lsb := (_ppu_read_vram(ppu, bg_tile_line_offset  ) >> (7 - bg_pixel_x)) & 1
	bg_tile_msb := (_ppu_read_vram(ppu, bg_tile_line_offset+1) >> (7 - bg_pixel_x)) & 1

	bg_tile_palette_index := bg_tile_lsb | (bg_tile_msb << 1)
	bg_tile_color := (ppu.bg_win_palette >> (bg_tile_palette_index * 2)) & 0b11
	
	return bg_tile_color
}

_ppu_render_pixel :: proc(ppu: ^Ppu_State, x: u8, y: u8) {
	palette_index := _ppu_render_pixel_palette_index(ppu, x, y)
	ppu.screen_pixel_data[int(x) + int(y) * 160] = ppu.screen_palette[palette_index]
}

_ppu_read_vram :: proc(ppu: ^Ppu_State, offset: u16) -> u8 {
	if ppu.vram_accessor == .Cpu {
		return 0xFF
	}
	return ppu.vram[offset]
}

_ppu_read_oam :: proc(ppu: ^Ppu_State, offset: u8) -> u8 {
	if ppu.oam_accessor == .Cpu {
		return 0xFF
	}
	return ppu.oam[offset]
}

