package main

import "core:math"
import "core:time"
import rl "vendor:raylib"

Screen_Size :: [2]i32{1920, 1080}
Dim :: 50

Draw_Size := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
size      := cast(f32) Draw_Size

Color4 :: [4]u8

the_font: rl.Font
font_scale :: 32
cps := [?]rune {
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ',',';','.',':','-','_','#','\'','+','*','~','´','`','?','\\','=','}',')',']','(','[','/','{','&','%','$','§','"','!','^','°',' ',
    'µ','@','€','²','³','<','>','|',
    '1','2','3','4','5','6','7','8','9','0',
}

_total, _update, _render, _collapse, _add_neighbours, _matches, _collect: time.Duration
_matches_count: int
main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(60)
    
    camera := rl.Camera2D { zoom = 1 }
    
    the_font = rl.LoadFontEx(`.\Caladea-Regular.ttf`, font_scale, &cps[0], len(cps))
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    city := rl.LoadImage("./dungeon.png")
    collapse: Collapse
    
    collapse.tiles    = make_array(&arena, Tile,  256)
    collapse.grid     = make_array(&arena, Cell,  Dim*Dim)
    collapse.to_check = make_array(&arena, Check, Dim*Dim)
    collapse.lowest_indices = make_array(&arena, [2]int, Dim*Dim)
    
    _total_start := time.now()
    extract_tiles(&collapse, city)
    
    entangle_grid(&collapse)
    
    entropy := seed_random_series(0x75658663)
    
    using collapse
    should_restart: b32
    t_restart: f32
    for !rl.WindowShouldClose() {
        _collapse = 0
        _collect = 0
        _add_neighbours = 0
        _matches = 0
        _matches_count = 0
        
        update_start := time.now()
        if !should_restart {
            for cast(f32) time.duration_seconds(time.since(update_start)) < 0.016 {
                if !step_observe(&collapse, &entropy) {
                    should_restart = true
                    t_restart = 5
                }
            }
        }
        _update = time.since(update_start)
        
        if should_restart {
            t_restart -= rl.GetFrameTime()
            if t_restart <= 0 {
                t_restart = 0
                should_restart = false
                entangle_grid(&collapse)
            }
        }
        
        // 
        // Render
        // 
        render_start := time.now()
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        rl.BeginMode2D(camera)
        
        for entry in slice(to_check) {
            p := get_screen_p(entry.index.x, entry.index.y)
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.YELLOW, 0.3))
        }
        
        for entry in slice(lowest_indices) {
            p := get_screen_p(entry.x, entry.y)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(color, 0.6))
        }
        
        all_done := true
        for y in 0..<Dim {
            for x in 0..<Dim {
                cell := &grid.data[y*Dim + x]
                
                p := get_screen_p(x, y)
                
                switch value in cell^ {
                  case Tile:
                    rl.DrawRectangleRec({p.x, p.y, size, size}, value.color)
                    
                  case Wave:
                    all_done = false
                    if len(value.options) == 0 {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        should_collapse, tile := draw_wave(&collapse, value, p, size)
                        if should_collapse {
                            collapse_cell_and_check_all_neighbours(&collapse, cell, {x,y}, tile)
                        }
                    }
                }
            }
        }
        
        if _total == 0 && all_done {
            _total = time.since(_total_start)
        }
        
        rl.EndMode2D()
        _render = time.since(render_start)
        
        buffer: [256]u8
        line_p := v2 {10, 10}
        draw_line(format_cstring(buffer[:], `Update %`,            _update), &line_p, font_scale, cast(f32) time.duration_seconds(_update) > rl.GetFrameTime() ? rl.RED : rl.WHITE)
        draw_line(format_cstring(buffer[:], "  collapse %",        _collapse), &line_p, font_scale)
        draw_line(format_cstring(buffer[:], "  get neighbours %",  _add_neighbours), &line_p, font_scale)
        denom := cast(time.Duration) _matches_count
        if denom == 0 do denom = 1
        draw_line(format_cstring(buffer[:], "  matches % * % = %", view_order_of_magnitude(_matches_count), _matches / denom, _matches), &line_p, font_scale)
        draw_line(format_cstring(buffer[:], "  collect %",         _collect), &line_p, font_scale)
        draw_line(format_cstring(buffer[:], "Render %",            _render),  &line_p, font_scale)
        draw_line(format_cstring(buffer[:], "Total %",             _total),   &line_p, font_scale)
        
        if should_restart {
            draw_line(format_cstring(buffer[:], "Collapse failed: restarting in %", view_seconds(t_restart, precision = 3)), &line_p, font_scale, rl.RED)
        }
        
        rl.EndDrawing()
    }
}

draw_line :: proc (text: cstring, p: ^v2, line_advance: f32, color:= rl.WHITE) {
    rl.DrawTextEx(the_font, text, p^, font_scale, 2, color)
    p.y += line_advance
}

draw_wave :: proc (using collapse: ^Collapse, wave: Wave, p: v2, size: v2) -> (should_collapse: b32, target: Tile) {
    count: u32
    when false {
        for tile, i in slice(tiles) {
            present: b32
            for it in wave.options do if tiles.data[it] == tile { present = true; break }
            if !present do continue
            
            factor := square_root(cast(f32) count)
            option_size := (size / factor)
            offset := vec_cast(f32, (i) % cast(int) factor, (i) / cast(int) factor)
            op := p + option_size * (offset+1)
            
            option_rect := rl.Rectangle {op.x, op.y, option_size.x, option_size.y}
            mouse := rl.GetMousePosition()
            if mouse.x >= option_rect.x && mouse.y >= option_rect.y && mouse.x < option_rect.x + option_rect.width && mouse.y < option_rect.y + option_rect.height {
                if rl.IsMouseButtonPressed(.LEFT) {
                    should_collapse = true
                    target = tile
                }
            }
            
            rl.DrawRectangleRec(option_rect, tile.color)
        }
    } else when false {
        sum: [4]u32
        for tile in slice(tiles) {
            present: b32
            for index in wave.options do if tiles.data[index] == tile { present = true; break }
            if !present do continue
            count += tile.frequency
            sum += tile.frequency * vec_cast(u32, cast([4]u8) tile.color)
        }
        
        color := cast(rl.Color) vec_cast(u8, (sum/count) / {1,1,1,4})
        rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, color)
    } else {
        // nothing
        unused(count)
    }
    
    return should_collapse, target
}

get_screen_p :: proc (x, y: int) -> (result: v2) {
    result = vec_cast(f32, x, y) * cast(f32) Draw_Size
    
    result.x += (cast(f32) Screen_Size.x - (size * Dim)) * 0.5
    result.y += size * 0.5
    
    return result
}
