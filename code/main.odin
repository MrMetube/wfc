package main

import "base:builtin"
import "core:hash"
import "core:time"
import rl "vendor:raylib"


Screen_Size :: [2]i32{1920, 1080}
Dim :: 50

        
Draw_Size   := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
Option_Size := Draw_Size / 8
size := cast(f32) Draw_Size

Kernel :: 3
Tile_Size :: rl.Rectangle{0,0,Kernel,Kernel}

Cell :: union {
    Tile,
    [dynamic]Tile,
}

Tile :: struct {
    // @Incomplete add a count to not store the same tile multiple times
    color: rl.Color,
    sockets: [4]Socket,
    frequency: u32,
    hash: u32,
}
Socket :: struct {
    center: [3]Color3,
    side:   [3]Color3,
}
Color3 :: [3]u8
Color4 :: [4]u8

main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(120)
    
    camera := rl.Camera2D { zoom = 1 }
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    city := rl.LoadImage("./flower.png")
    tiles := make_array(&arena, Tile, 2048)
    
    {
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
                
                sub_image := rl.Image {
                    data   = &sub_pixels.data[0],
                    width  = Kernel, height = Kernel,
                    format = .UNCOMPRESSED_R8G8B8,
                    mipmaps = 1,
                }
                
                tile: Tile
                {
                    img := sub_image
                    sub_pixels := (cast([^]Color3) img.data)[:img.width * img.height]
                    
                    w := cast(int) img.width
                    h := cast(int) img.height
                    // east
                    for y in 0..<h {
                        x := w-1
                        m := x-1
                        tile.sockets[0].center[y] = sub_pixels[y*w + m]
                        tile.sockets[0].side[y]   = sub_pixels[y*w + x]
                    }
                    // north
                    for x in 0..<w {
                        y := 0
                        m := y+1
                        tile.sockets[1].center[x] = sub_pixels[m*w + x]
                        tile.sockets[1].side[x]   = sub_pixels[y*w + x]
                    }
                    
                    // west
                    for y in 0..<h {
                        x := 0
                        m := x+1
                        tile.sockets[2].center[y] = sub_pixels[y*w + m]
                        tile.sockets[2].side[y]   = sub_pixels[y*w + x]
                    }
                    
                    // south
                    for x in 0..<w {
                        y := h-1
                        m := y-1
                        tile.sockets[3].center[x] = sub_pixels[m*w + x]
                        tile.sockets[3].side[x]   = sub_pixels[y*w + x]
                    }
                    
                    tile.hash = hash.djb2((cast([^]u8) &sub_pixels[0])[: len(sub_pixels)*size_of(Color3)])
                }
                
                present: ^Tile
                for &it in slice(tiles) {
                    if tile.hash == it.hash {
                        present = &it
                        break
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
    
    grid := make_array(&arena, Cell, Dim*Dim)
    
    
    init_grid(&grid, slice(tiles))
    
    entropy := seed_random_series()//0x75658663)
    
    lowest_indices := make_array(&arena, [2]int, Dim*Dim)
    lowest_cardinality := max(u32)
    to_check := make_array(&arena, Check, Dim*Dim)
    
    update, render: time.Duration
    for !rl.WindowShouldClose() {
        
        update_start := time.now()
        //
        // Pick a cell to collapse
        //
        clear(&to_check)
        
        if lowest_indices.count != 0 {
            if lowest_cardinality == 1 {
                for index in slice(lowest_indices) {
                    cell  := &grid.data[index.y * Dim + index.x]
                    options := cell.([dynamic]Tile)
                    if len(options) == 0 {
                        init_grid(&grid, slice(tiles))
                    } else {
                        collapse_cell(slice(grid), cell, index, options[0], &to_check)
                    }
                }
            } else {
                lowest_index := random_choice(&entropy, slice(lowest_indices))^
                lowest_cell  := &grid.data[lowest_index.y * Dim + lowest_index.x]
                
                options := lowest_cell.([dynamic]Tile)
                total_freq: u32
                for option in options do total_freq += option.frequency
                choice := random_between_u32(&entropy, 0, total_freq)
                
                pick: Tile
                for option in options {
                    if choice <= option.frequency {
                        pick = option
                        break
                    }
                    choice -= option.frequency
                }
                collapse_cell(slice(grid), lowest_cell, lowest_index, pick, &to_check)
            }
            
            clear(&lowest_indices)
            lowest_cardinality = max(u32)
        }
        
        // 
        // Collect all lowest cells
        // 
        
        for y in 0..<Dim {
            for x in 0..<Dim {
                index := y*Dim + x
                cell := &grid.data[index]
                
                if options, ok := cell.([dynamic]Tile); ok {
                    cardinality := cast(u32) len(options)
                    if cardinality > 0 && cardinality < lowest_cardinality {
                        lowest_cardinality = cardinality
                        clear(&lowest_indices)
                    }
                    if cardinality > 0 && cardinality <= lowest_cardinality {
                        append(&lowest_indices, [2]int{x,y})
                    }
                }
            }
        }
        update = time.since(update_start)
        
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
                    
                  case [dynamic]Tile:
                    if len(value) == 0 {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        // count: u32
                        // sum: [4]u32
                        // for tile, i in slice(tiles) {
                        //     present: b32
                        //     for it in value do if it == tile { present = true; break }
                        //     if !present do continue
                        //     count += tile.frequency
                        //     sum += tile.frequency * vec_cast(u32, cast([4]u8) tile.color)
                        // }
                        
                        // color := cast(rl.Color) vec_cast(u8, sum/count)
                        // for tile, i in slice(tiles) {
                        //     present: b32
                        //     for it in value do if it == tile { present = true; break }
                        //     if !present do continue
                            
                        //     option_size := cast(f32) Option_Size
                            
                        //     offset := vec_cast(f32, (i) % 7, (i) / 7)
                        //     op := p + option_size * (offset+1)
                            
                        //     option_rect := rl.Rectangle {op.x, op.y, option_size, option_size}
                        //     mouse := rl.GetMousePosition()
                        //     if mouse.x >= option_rect.x && mouse.y >= option_rect.y && mouse.x < option_rect.x + option_rect.width && mouse.y < option_rect.y + option_rect.height {
                        //         if rl.IsMouseButtonPressed(.LEFT) {
                        //             collapse_cell(slice(grid), cell, {x,y}, tile, &to_check)
                        //         }
                        //     }
                            
                        //     rl.DrawRectangleRec({p.x, p.y, size, size}, color)
                        // }
                    }
                }
            }
        }
        
        rl.EndMode2D()
        render = time.since(render_start)
        
        buffer: [256]u8
        text := format_string(buffer[:], "Update % Render %", update, render, flags = {.AppendZero})
        rl.DrawText(cast(cstring) raw_data(text), 10,  10, 20, rl.RED)
        
        rl.EndDrawing()
    }
}
init_grid :: proc(grid: ^Array(Cell), tiles: []Tile) {
    clear(grid)
    
    for _ in 0..<len(grid.data) {
        options := make([dynamic]Tile)
        for tile in tiles {
            builtin.append(&options, tile)
        }
        append(grid, options)
    }
}

Check :: struct {
    index: [2]int,
    depth: u32,
}

collapse_cell :: proc (grid: []Cell, cell: ^Cell, index: [2]int, pick: Tile, to_check: ^Array(Check), depth: u32 = 15) {
    options := cell.([dynamic]Tile)
    cell ^= pick
    delete(options)
    
    add_neighbours :: proc (to_check: ^Array(Check), index: [2]int, depth: u32) {
        nexts := [4][2]int{{-1, 0}, {+1, 0}, {0, -1}, {0, +1}} 
        for n in nexts {
            next := n + index
            ok := true
            
            if ok && (next.x < 0 || next.x >= Dim || next.y < 0 || next.y >= Dim) {
                ok = false
            }
            
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
    // Check all effected neighbours
    //
    for index: i64; index < to_check.count; index += 1 {
        next := to_check.data[index]
        x := next.index.x
        y := next.index.y
        other := &grid[y*Dim + x]
        
        if options, ok := &other.([dynamic]Tile); ok {
            if update_maze_cell(grid[:], other, options, x, y) && next.depth > 0 {
                add_neighbours(to_check, {x, y}, next.depth)
            }
        }
    }
}

get_screen_p :: proc (x, y: int) -> (result: v2) {
    result = vec_cast(f32, x, y) * cast(f32) Draw_Size
    result.x += (cast(f32) Screen_Size.x - (size * Dim)) * 0.5
    result.y += size * 0.5
    return result
}

update_maze_cell :: proc (grid: []Cell, cell: ^Cell, options: ^[dynamic]Tile, x, y: int) -> (changed: b32) {
    #reverse for option, index in options {
        ok := true
        sockets := option.sockets
        // west
        if x-1 >= 0  {
            n := grid[(y)*Dim + (x-1)]
            ok &&= matches(sockets, n, 2, 0)
        }
        // north
        if y-1 >= 0  {
            n := grid[(y-1)*Dim + (x)]
            ok &&= matches(sockets, n, 1, 3)
        }
        // east
        if x+1 < Dim {
            n := grid[(y)*Dim + (x+1)]
            ok &&= matches(sockets, n, 0, 2)
        }
        // south
        if y+1 < Dim {
            n := grid[(y+1)*Dim + (x)]
            ok &&= matches(sockets, n, 3, 1)
        }
        
        if !ok {
            changed = true
            builtin.unordered_remove(options, index)
        }
    }
    
    return changed
}

matches :: proc(sockets: [4]Socket, next: Cell, a_side, b_side: int) -> (result: b32) {
    switch &value in next {
      case [dynamic]Tile: 
        result = false 
        for option in value {
            result ||= matches(sockets, option, a_side, b_side)
        }
      case Tile:
        result = true
        result &&= sockets[a_side].side   == value.sockets[b_side].center
        result &&= sockets[a_side].center == value.sockets[b_side].side
    }
    return result
}