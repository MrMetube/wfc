package main

import "core:time"
import rl "vendor:raylib"

Screen_Size :: [2]i32{1920, 1080}
Dim :: 200

        
Draw_Size := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
size      := cast(f32) Draw_Size

Tile_Size :: rl.Rectangle{0,0,Kernel,Kernel}

Color4 :: [4]u8

the_font: rl.Font
font_scale :: 32
cps := [?]rune {
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ',',';','.',':','-','_','#','\'','+','*','~','´','`','?','\\','=','}',')',']','(','[','/','{','&','%','$','§','"','!','^','°',' ',
    'µ','@','€','²','³',
    '1','2','3','4','5','6','7','8','9','0',
}

_total, _update, _render, _collapse, _add_neighbours, _matches, _matches_tile, _collect: time.Duration
main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(60)
    
    camera := rl.Camera2D { zoom = 1 }
    
    the_font = rl.LoadFontEx(`.\Caladea-Regular.ttf`, font_scale, &cps[0], len(cps))
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    city := rl.LoadImage("./city.png")
    collapse: Collapse
    
    collapse.tiles    = make_array(&arena, Tile,  256)
    collapse.grid     = make_array(&arena, Cell,  Dim*Dim)
    collapse.to_check = make_array(&arena, Check, Dim*Dim)
    
    _total_start := time.now()
    extract_tiles(&collapse, city)
    
    entangle_grid(&collapse)
    
    entropy := seed_random_series(0x75658663)
    
    lowest_indices := make_array(&arena, [2]int, Dim*Dim)
    lowest_cardinality := max(u32)
    
    using collapse
    
    for !rl.WindowShouldClose() {
        update_start := time.now()
        _collapse = 0
        _collect = 0
        _add_neighbours = 0
        _matches = 0
        _matches_tile = 0
        
        for cast(f32) time.duration_seconds(time.since(update_start)) < 0.016 {
            //
            // Pick a cell to collapse
            //
            pick_and_collapse_start := time.now()
            clear(&to_check)
            
            if lowest_indices.count != 0 {
                if lowest_cardinality == 1 {
                    for index in slice(lowest_indices) {
                        cell  := &grid.data[index.y * Dim + index.x]
                        options := cell.([dynamic]int)
                        assert(len(options) != 0)
                        collapse_cell(cell, tiles.data[options[0]])
                    }
                    
                    for index in slice(lowest_indices) {
                        add_neighbours(&collapse, index)
                    }
                    
                    check_all_neighbours(& collapse)
                } else {
                    lowest_index := random_choice(&entropy, slice(lowest_indices))^
                    lowest_cell  := &grid.data[lowest_index.y * Dim + lowest_index.x]
                    
                    options := lowest_cell.([dynamic]int)
                    total_freq: u32
                    for index in options do total_freq += tiles.data[index].frequency
                    choice := random_between_u32(&entropy, 0, total_freq)
                    
                    pick: Tile
                    for index in options {
                        option := tiles.data[index]
                        if choice <= option.frequency {
                            pick = option
                            break
                        }
                        choice -= option.frequency
                    }
                    collapse_cell_and_check_all_neighbours(&collapse, lowest_cell, lowest_index, pick)
                }
                
                clear(&lowest_indices)
                lowest_cardinality = max(u32)
            }
            
            _collapse += time.since(pick_and_collapse_start)
            // 
            // Collect all lowest cells
            // 
            collect_start := time.now()
            
            loop: for y in 0..<Dim {
                for x in 0..<Dim {
                    index := y*Dim + x
                    cell := &grid.data[index]
                    
                    if options, ok := cell.([dynamic]int); ok {
                        cardinality := cast(u32) len(options)
                        if cardinality < lowest_cardinality {
                            lowest_cardinality = cardinality
                            clear(&lowest_indices)
                        }
                        if cardinality <= lowest_cardinality {
                            append(&lowest_indices, [2]int{x,y})
                        }
                        if lowest_cardinality == 0 {
                            entangle_grid(&collapse)
                            println("Collapse failed: restarting.")
                            break loop
                        }
                    }
                }
            }
            _collect += time.since(collect_start)
        }
        
        _update = time.since(update_start)
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
            color := lowest_cardinality == 1 ? rl.PURPLE : rl.BLUE
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
                    
                  case [dynamic]int:
                    all_done = false
                    if len(value) == 0 {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        should_collapse, tile := draw_options(&collapse, value, p, size)
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
        x, y: f32 = 10, 10
            text := format_string(buffer[:], "Update %", _update, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, cast(f32) time.duration_seconds(_update) < rl.GetFrameTime() ? rl.WHITE : rl.RED)
        y += font_scale
            text = format_string(buffer[:], "  pick and collapse %", _collapse, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
            text = format_string(buffer[:], "  get neighbours %", _add_neighbours, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
            text = format_string(buffer[:], "  matches %", _matches, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
            text = format_string(buffer[:], "  matches_tile %", _matches_tile, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
            text = format_string(buffer[:], "  collect %", _collect, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
            text = format_string(buffer[:], "Render %", _render, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        y += font_scale
        y += font_scale
            text = format_string(buffer[:], "Total %", _total, flags = {.AppendZero})
            rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, rl.WHITE)
        
        rl.EndDrawing()
    }
}

draw_options :: proc (using collapse: ^Collapse, value: [dynamic]int, p: v2, size: v2) -> (should_collapse: b32, target: Tile) {
    count: u32
    when false {
        for tile, i in slice(tiles) {
            present: b32
            for it in value do if tiles.data[it] == tile { present = true; break }
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
            for index in value do if tiles.data[index] == tile { present = true; break }
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
