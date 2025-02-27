package gameboi

import "base:intrinsics"

import "core:fmt"
import "core:os"
import "core:math/bits"
import rl "vendor:raylib"

Emulator_State :: struct {
	cpu: Cpu_State,
	ppu: Ppu_State,
	mem: Memory_State,
	timer: Timer_State,
	
	cycle_timer: int,
	screen_texture: rl.Texture2D,
}

state: Emulator_State

main :: proc() {
	assert(len(os.args) > 2, "Not enough arguments, need the rom and bootrom!")

	rom_data, ok := os.read_entire_file(os.args[1])
	assert(ok, "Couldn't read rom file!")
	defer delete(rom_data)
	
	bootrom_data: []u8
	bootrom_data, ok = os.read_entire_file(os.args[2])
	assert(ok, "Couldn't read bootrom file!")
	defer delete(bootrom_data)
	assert(len(bootrom_data) == 256, "Currently doesn't support CGB bootroms!")

	timer_init(&state.timer)
	memory_init(&state.mem, bootrom_data, rom_data)
	cpu_init(&state.cpu)
	ppu_init(&state.ppu)
	
	rl.InitWindow(160 * 6, 144 * 6, "gameboi")
	assert(rl.IsWindowReady(), "Unable to initialize window")
	defer rl.CloseWindow()
	
	{
		initial_screen := rl.GenImageColor(160, 144, rl.BLACK)
		state.screen_texture = rl.LoadTextureFromImage(initial_screen)
		rl.SetTextureFilter(state.screen_texture, .POINT)
		rl.UnloadImage(initial_screen)
	}
	defer rl.UnloadTexture(state.screen_texture)
	
	for {
		if rl.WindowShouldClose() {
			break
		}
		step(&state)
		if state.ppu.v_counter == 144 && state.ppu.h_counter == 0 {
			rl.BeginDrawing()
			rl.ClearBackground(rl.BLACK)
			rl.UpdateTexture(state.screen_texture, raw_data(&state.ppu.screen_pixel_data))
			rl.DrawTexturePro(state.screen_texture, {
				x = 0, y = 0,
				width = 160, height = 144,
			}, {
				x = 0, y = 0,
				width = f32(rl.GetRenderWidth()), height = f32(rl.GetRenderHeight()),
			}, { 0, 0 }, 0, rl.WHITE)
			rl.DrawFPS(32, 32)
			rl.EndDrawing()
		}
	}
}

// Steps every "dot", 2^22 Hz (≅ 4.194 MHz)
step :: proc(state: ^Emulator_State) {
	ppu_step(state)

	// TODO: CGB Double-speed mode
	// the length of a dot stays the same in this mode.
	if state.cycle_timer >= 4 {
		cpu_step(state)
		
		timer_step(state)
		state.cycle_timer = 0
	}
	
	state.cycle_timer += 1
}

