package main

import "base:builtin"
import "core:hash"
import "core:time"
import rl "vendor:raylib"


Screen_Size :: [2]i32{1920, 1080}
Dim :: 100

        
Draw_Size := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
size      := cast(f32) Draw_Size

Kernel :: 3
Tile_Size :: rl.Rectangle{0,0,Kernel,Kernel}

Collapse :: struct {
    grid:  Array(Cell), 
    tiles: Array(Tile),
    // adjacency: map[Key]bool,
}

Cell :: union {
    Tile,
    [dynamic]int,
}

Tile :: struct {
    color:     rl.Color,
    sockets:   [4]Socket,
    frequency: u32,
    hash:      u32,
}
Socket :: struct {
    center: [3]Color3,
    side:   [3]Color3,
}
Color3 :: [3]u8
Color4 :: [4]u8

Delta := [Direction] [2]int {
    .West  = {-1,  0},
    .North = { 0, -1},
    .East  = {+1,  0},
    .South = { 0, +1},
}

Direction :: enum { East, North, South, West }

the_font: rl.Font
font_scale :: 32
cps := [?]rune {
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ',',';','.',':','-','_','#','\'','+','*','~','´','`','?','\\','=','}',')',']','(','[','/','{','&','%','$','§','"','!','^','°',' ',
    'µ',
    '1','2','3','4','5','6','7','8','9','0',
    'Α', 'α', 'Β', 'β', 'Γ', 'γ', 'Δ', 'δ', 'Ε', 'ε', 'Ζ', 'ζ', 'Η', 'η', 'Θ', 'θ', 'Ι', 'ι', 'Κ', 'κ', 'Λ', 'λ', 'Μ', 'μ', 'Ν', 'ν', 'Ξ', 'ξ', 'Ο', 'ο', 'Π', 'π', 'Ρ', 'ρ', 'Σ', 'σ', 'ς', 'Τ', 'τ', 'Υ', 'υ', 'Φ', 'φ', 'Χ', 'χ', 'Ψ', 'ψ', 'Ω', 'ω',
}

neighbours, update, render, pick_and_collapse, collect: time.Duration
main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(144)
    
    camera := rl.Camera2D { zoom = 1 }
    
    the_font = rl.LoadFontEx(`.\Caladea-Regular.ttf`, font_scale, &cps[0], len(cps))
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    city := rl.LoadImage("./city.png")
    collapse: Collapse

    collapse.tiles = make_array(&arena, Tile, 256)
    collapse.grid  = make_array(&arena, Cell, Dim*Dim)
    
    extract_tiles(&collapse, city)
    
    entangle_grid(&collapse)
    
    entropy := seed_random_series()//0x75658663)
    
    lowest_indices := make_array(&arena, [2]int, Dim*Dim)
    lowest_cardinality := max(u32)
    to_check := make_array(&arena, Check, Dim*Dim)
    
    using collapse
    
    for !rl.WindowShouldClose() {
        
        update_start := time.now()
        pick_and_collapse = 0
        collect = 0
        neighbours = 0
        
        for cast(f32) time.duration_seconds(time.since(update_start)) < 0.00694 {
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
                        if len(options) == 0 {
                            entangle_grid(&collapse)
                        } else {
                            collapse_cell(&collapse, cell, index, tiles.data[options[0]], &to_check)
                        }
                    }
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
                    collapse_cell(&collapse, lowest_cell, lowest_index, pick, &to_check)
                }
                
                clear(&lowest_indices)
                lowest_cardinality = max(u32)
            }
            
            pick_and_collapse += time.since(pick_and_collapse_start)
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
            collect += time.since(collect_start)
        }
        
        update = time.since(update_start)
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

        for y in 0..<Dim {
            for x in 0..<Dim {
                cell := &grid.data[y*Dim + x]
                
                p := get_screen_p(x, y)
                
                switch value in cell^ {
                  case Tile:
                    rl.DrawRectangleRec({p.x, p.y, size, size}, value.color)
                    
                  case [dynamic]int:
                    if len(value) == 0 {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        should_collapse, tile := draw_options(&collapse, value, p, size)
                        if should_collapse {
                            collapse_cell(&collapse, cell, {x,y}, tile, &to_check)
                        }
                    }
                }
            }
        }
        
        rl.EndMode2D()
        render = time.since(render_start)
        
        buffer: [256]u8
        x, y: f32 = 10, 10
        text := format_string(buffer[:], "Update %", update, flags = {.AppendZero})
        rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, cast(f32) time.duration_seconds(update) < rl.GetFrameTime() ? rl.WHITE : rl.RED)
        y += font_scale
        text = format_string(buffer[:], "  pick and collapse %", pick_and_collapse, flags = {.AppendZero})
        y += font_scale
        rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, cast(f32) time.duration_seconds(update) < rl.GetFrameTime() ? rl.WHITE : rl.RED)
        text = format_string(buffer[:], "  get neighbours %", neighbours, flags = {.AppendZero})
        rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, cast(f32) time.duration_seconds(update) < rl.GetFrameTime() ? rl.WHITE : rl.RED)
        y += font_scale
        text = format_string(buffer[:], "  collect %", collect, flags = {.AppendZero})
        rl.DrawTextEx(the_font, cast(cstring) raw_data(text), {x, y} , font_scale, 2, cast(f32) time.duration_seconds(update) < rl.GetFrameTime() ? rl.WHITE : rl.RED)
        y += font_scale
        text = format_string(buffer[:], "Render %", render, flags = {.AppendZero})
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
    } else when !false {
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

extract_tiles :: proc (using collapse: ^Collapse, city: rl.Image) {
    assert(city.format == .UNCOMPRESSED_R8G8B8A8)
    pixels := (cast([^]Color4) city.data)[:city.width * city.height]
    
    for min_y in 0..<city.height {
        for min_x in 0..<city.width {
            sub_pixels: FixedArray(cast(i64) (Kernel*Kernel), Color3)
            
            for dy in 0..<Kernel {
                for dx in 0..<Kernel {
                    x := (min_x + cast(i32) dx) % city.width
                    y := (min_y + cast(i32) dy) % city.height
                    
                    pixel := pixels[y * city.width + x].rgb
                    append(&sub_pixels, pixel)
                }
            }
            
            tile: Tile
            pixels := sub_pixels.data
            
            w := Kernel
            h := Kernel
            // east
            for y in 0..<h {
                x := w-1
                m := x-1
                tile.sockets[0].center[y] = pixels[y*w + m]
                tile.sockets[0].side[y]   = pixels[y*w + x]
            }
            // north
            for x in 0..<w {
                y := 0
                m := y+1
                tile.sockets[1].center[x] = pixels[m*w + x]
                tile.sockets[1].side[x]   = pixels[y*w + x]
            }
            
            // west
            for y in 0..<h {
                x := 0
                m := x+1
                tile.sockets[2].center[y] = pixels[y*w + m]
                tile.sockets[2].side[y]   = pixels[y*w + x]
            }
            
            // south
            for x in 0..<w {
                y := h-1
                m := y-1
                tile.sockets[3].center[x] = pixels[m*w + x]
                tile.sockets[3].side[x]   = pixels[y*w + x]
            }
            
            {
                center := sub_pixels.data[1*Kernel+1]
                c := hash.djb2((cast([^]u8) &center)[:size_of(center)])
                e := hash.djb2((cast([^]u8) &tile.sockets[0])[:size_of(tile.sockets[0])])
                n := hash.djb2((cast([^]u8) &tile.sockets[1])[:size_of(tile.sockets[1])])
                w := hash.djb2((cast([^]u8) &tile.sockets[2])[:size_of(tile.sockets[2])])
                s := hash.djb2((cast([^]u8) &tile.sockets[3])[:size_of(tile.sockets[3])])
                
                hash_0 := [?]u32{c, n, e, s, w}
                
                tile.hash = hash.djb2((cast([^]u8) &hash_0)[:size_of(hash_0)])
            }
            
            present: ^Tile
            loop: for &it in slice(tiles) {
                if tile.hash == it.hash {
                    present = &it
                    break loop
                }
            }
            
            if present != nil {
                present.frequency += 1
            } else {
                tile.color.rgb = sub_pixels.data[1*Kernel+1]
                tile.color.a = 255
                tile.frequency = 1
                append(&tiles, tile)
            }
        }
    }

}

entangle_grid :: proc(using collapse: ^Collapse) {
    clear(&grid)
    
    for _ in 0..<len(grid.data) {
        options := make([dynamic]int)
        for _, i in slice(tiles) {
            builtin.append(&options, i)
        }
        append(&grid, options)
    }
}

Check :: struct {
    index: [2]int,
    depth: u32,
}

collapse_cell :: proc (using collapse: ^Collapse, cell: ^Cell, index: [2]int, pick: Tile, to_check: ^Array(Check), depth: u32 = 20) {
    options := cell.([dynamic]int)
    cell ^= pick
    delete(options)
    
    add_neighbours :: proc (to_check: ^Array(Check), index: [2]int, depth: u32) {
        neighbours_start := time.now()
        defer neighbours += time.since(neighbours_start)
        
        for n in Delta {
            next := n + index
            next = (next + Dim) % Dim
            
            ok := true
            if ok {
                for entry in slice(to_check) {
                    if entry.index == next {
                        ok = false
                        break
                    }
                }
            }
            
            if ok {
                append(to_check, Check {next, depth-1})
            }
        }
    }
    
    add_neighbours(to_check, index, depth)
    
    //
    // Check all neighbours
    //
    for index: i64; index < to_check.count; index += 1 {
        next := to_check.data[index]
        x := next.index.x
        y := next.index.y
        other := &grid.data[y*Dim + x]
        
        if options, ok := &other.([dynamic]int); ok {
            if reduce_entropy(collapse, other, options, {x, y}) && next.depth > 0 {
                add_neighbours(to_check, {x, y}, next.depth)
            }
        }
    }
}

reduce_entropy :: proc (using collapse: ^Collapse, cell: ^Cell, options: ^[dynamic]int, p: [2]int) -> (changed: b32) {
    #reverse for tile_index, index in options {
        option := tiles.data[tile_index]
        
        ok := true
        ok &&= matches(collapse, option, p, .West)
        ok &&= matches(collapse, option, p, .North)
        ok &&= matches(collapse, option, p, .East)
        ok &&= matches(collapse, option, p, .South)
        
        if !ok {
            changed = true
            builtin.unordered_remove(options, index)
        }
    }
    
    return changed
}

matches :: proc(using collapse: ^Collapse, a: Tile, p: [2]int, direction: Direction) -> (result: b32) {
    p := p
    p += Delta[direction]
    p = (p + Dim) % Dim
    
    assert(!(p.x < 0 || p.x >= Dim || p.y < 0 || p.y >= Dim))
    if p.x < 0 || p.x >= Dim || p.y < 0 || p.y >= Dim do return true
    next := grid.data[p.y*Dim + p.x]
    
    switch &value in next {
      case [dynamic]int: 
        result = false 
        for index in value {
            b := tiles.data[index]
            result ||= matches_tile(collapse, a, b, direction)
        }
      case Tile:
        result = matches_tile(collapse, a, value, direction)
    }
    
    return result
}

matches_tile :: proc(using collapse: ^Collapse, a, b: Tile, direction: Direction) -> (result: b32) {
    a_side, b_side: int = ---, ---
    switch direction {
      case .West:  a_side, b_side = 2, 0
      case .North: a_side, b_side = 1, 3
      case .East:  a_side, b_side = 0, 2
      case .South: a_side, b_side = 3, 1
    }
    
    result = true
    result &&= a.sockets[a_side].side   == b.sockets[b_side].center
    result &&= a.sockets[a_side].center == b.sockets[b_side].side
    
    return result
}

get_screen_p :: proc (x, y: int) -> (result: v2) {
    result = vec_cast(f32, x, y) * cast(f32) Draw_Size
    
    result.x += (cast(f32) Screen_Size.x - (size * Dim)) * 0.5
    result.y += size * 0.5
    
    return result
}
