package main

import rl "vendor:raylib"

Tile_Size :: rl.Rectangle{0,0,5,5}

Tile :: enum { E, NE, N, NW, W, SW, S, SE }
Cell :: struct {
    done: b32,
    options: bit_set[Tile],
}
Socket :: enum { White, Black }

Screen_Size :: [2]i32{1920, 1080}
Dim :: 27

        
Draw_Size   := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
Option_Size := Draw_Size / 10
size := cast(f32) Draw_Size

main :: proc () {
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(120)
    
    e  := rl.LoadTexture("./e.bmp")
    ne := rl.LoadTexture("./ne.bmp")
    n  := rl.LoadTexture("./n.bmp")
    nw := rl.LoadTexture("./nw.bmp")
    w  := rl.LoadTexture("./w.bmp")
    sw := rl.LoadTexture("./sw.bmp")
    s  := rl.LoadTexture("./s.bmp")
    se := rl.LoadTexture("./se.bmp")
    
    
    tiles := [?] rl.Texture { e, ne, n, nw, w, sw, s, se, }
    sockets := [Tile] [4] Socket {
        .E  = {.Black, .Black, .White, .Black},
        .NE = {.Black, .Black, .White, .White},
        .N  = {.Black, .Black, .Black, .White},
        .NW = {.White, .Black, .Black, .White},
        .W  = {.White, .Black, .Black, .Black},
        .SW = {.White, .White, .Black, .Black},
        .S  = {.Black, .White, .Black, .Black},
        .SE = {.Black, .White, .White, .Black},
    }
    
    grid: [Dim*Dim]Cell = Cell{options = ~{}}
    
    camera: rl.Camera2D = {
        zoom = 1
    }
    
    entropy := seed_random_series(0x75866563)
    
    lowest_indices := make_array(&arena, [2]int, Dim*Dim)
    lowest_cardinality := max(u32)
    to_check := make_array(&arena, [2]int, Dim*Dim)
    
    for !rl.WindowShouldClose() {
        if rl.IsKeyDown(.SPACE) {
            //
            // Pick a cell to collapse
            //
            clear(&to_check)
            
            if lowest_indices.count != 0 {
                lowest_index := random_choice(&entropy, slice(lowest_indices))^
                lowest_cell  := &grid[lowest_index.y * Dim + lowest_index.x]
                
                pick := random_choice(&entropy, 0, lowest_cardinality)
                for option in lowest_cell.options {
                    if pick == 0 {
                        lowest_cell.options = { option }
                        lowest_cell.done = true
                    }
                    pick -= 1
                }
                
                nexts := [4][2]int{{-1, 0}, {+1, 0}, {0, -1}, {0, +1}}
                for n in nexts {
                    next := n + lowest_index
                    ok := true
                    
                    if ok && (next.x < 0 || next.x >= Dim || next.y < 0 || next.y >= Dim) {
                        ok = false
                    }
                    
                    if ok {
                        for entry in slice(to_check) {
                            if entry == next {
                                ok = false
                                break
                            }
                        }
                    }
                    
                    if ok {
                        append(&to_check, next)
                    }
                }
                
                clear(&lowest_indices)
                lowest_cardinality = max(u32)
            }
            
            //
            // Check all affected neighbours
            //
            
            for next in slice(to_check) {
                x := next.x
                y := next.y
                cell := &grid[y*Dim + x]
                
                cell_ok := true
                if card(cell.options) > 1 {
                    for option in cell.options {
                        ok := true
                        socket := sockets[option]
                        // west
                        if x-1 >= 0  {
                            n := grid[(y)*Dim + (x-1)].options
                            if card(n) == 1 {
                                ns := sockets[cell_to_tile(n)]
                                ok &&= ns[0] == socket[2]
                            }
                        }
                        // north
                        if y-1 >= 0  {
                            n := grid[(y-1)*Dim + (x)].options
                            if card(n) == 1 {
                                ns := sockets[cell_to_tile(n)]
                                ok &&= ns[3] == socket[1]
                            }
                        }
                        // east
                        if x+1 < Dim {
                            n := grid[(y)*Dim + (x+1)].options
                            if card(n) == 1 {
                                ns := sockets[cell_to_tile(n)]
                                ok &&= ns[2] == socket[0]
                            }
                        }
                        // south
                        if y+1 < Dim {
                            n := grid[(y+1)*Dim + (x)].options
                            if card(n) == 1 {
                                ns := sockets[cell_to_tile(n)]
                                ok &&= ns[1] == socket[3]
                            }
                        }
                        
                        cell_ok &&= ok
                        if !ok {
                            cell.options -= {option}
                        }
                    }
                }
            }
            
            // 
            // Collect all lowest cells
            // 
            
            for y in 0..<Dim {
                for x in 0..<Dim {
                    index := y*Dim + x
                    cell := &grid[index]
                    
                    if cell.done do continue
                    
                    cardinality := cast(u32) card(cell.options)
                    if cardinality < lowest_cardinality {
                        lowest_cardinality = cardinality
                        clear(&lowest_indices)
                    }
                    if cardinality <= lowest_cardinality {
                        append(&lowest_indices, [2]int{x,y})
                    }
                }
            }
        }
        
        
        rl.BeginDrawing()
        rl.ClearBackground({0, 0x18, 0x9, 0xff})
        
        rl.BeginMode2D(camera)
        
        for entry in slice(to_check) {
            p := get_screen_p(entry.x, entry.y)
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.YELLOW, 0.3))
        }
        
        for entry in slice(lowest_indices) {
            p := get_screen_p(entry.x, entry.y)
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.GREEN, 0.3))
        }
        
        for y in 0..<Dim {
            for x in 0..<Dim {
                cell := grid[y*Dim + x]
                
                p := get_screen_p(x, y)
                
                if cell.done {
                    tile_index := cell_to_tile(cell.options)
                    tile := tiles[tile_index]
                    rl.DrawTexturePro(tile, Tile_Size, {p.x, p.y, size, size}, 0, 0, rl.WHITE)
                } else if card(cell.options) == 0 {
                    rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                } else {
                    for option in cell.options {
                        tile := tiles[option]
                        option_size := size * 0.1
                        p.x += option_size
                        rl.DrawTexturePro(tile, Tile_Size, {p.x, p.y, option_size, option_size}, 0, 0, rl.WHITE)
                    }
                }
            }
        }
        
        rl.EndMode2D()
        
        rl.EndDrawing()
    }
}

get_screen_p :: proc (x, y: int) -> (result: v2) {
    result = vec_cast(f32, x, y) * size
    result.x += (cast(f32) Screen_Size.x - (size * Dim)) * 0.5
    result.y += size * 0.5
    return result
}

// @premature_optimization
cell_to_tile :: proc (options: bit_set[Tile]) -> (result: Tile) {
    assert(card(options) == 1)
    
    for tile in Tile {
        if tile in options {
            result = tile
            break
        }
    }
    
    return result
}