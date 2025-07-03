package main

import rl "vendor:raylib"


Screen_Size :: [2]i32{1920, 1080}
Dim :: 9

        
Draw_Size   := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
Option_Size := Draw_Size / 4
Pad :: 0
size := cast(f32) Draw_Size - 2*Pad

Tile_Size :: rl.Rectangle{0,0,5,5}

Cell :: struct ($E: typeid) {
    done: b32,
    options: bit_set[E],
}

////////////////////////////////////////////////
// Sudoku Tiles
Tile :: enum { S1, S2, S3, S4, S5, S6, S7, S8, S9}
SudokuCell :: Cell(Tile)


////////////////////////////////////////////////
// Maze Tiles
MazeTile :: enum { E, NE, N, NW, W, SW, S, SE }
Socket :: enum { White, Black }
sockets := [MazeTile] [4] Socket {
    .E  = {.Black, .Black, .White, .Black},
    .NE = {.Black, .Black, .White, .White},
    .N  = {.Black, .Black, .Black, .White},
    .NW = {.White, .Black, .Black, .White},
    .W  = {.White, .Black, .Black, .Black},
    .SW = {.White, .White, .Black, .Black},
    .S  = {.Black, .White, .Black, .Black},
    .SE = {.Black, .White, .White, .Black},
}

MazeCell :: Cell(MazeTile)

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
    
    s1 := rl.LoadTexture("./1.bmp")
    s2 := rl.LoadTexture("./2.bmp")
    s3 := rl.LoadTexture("./3.bmp")
    s4 := rl.LoadTexture("./4.bmp")
    s5 := rl.LoadTexture("./5.bmp")
    s6 := rl.LoadTexture("./6.bmp")
    s7 := rl.LoadTexture("./7.bmp")
    s8 := rl.LoadTexture("./8.bmp")
    s9 := rl.LoadTexture("./9.bmp")
    _tiles := [?] rl.Texture { s1, s2, s3, s4, s5, s6, s7, s8, s9 }

    grid: [Dim*Dim] MazeCell = MazeCell{options = ~{}}
    
    camera: rl.Camera2D = {
        zoom = 1
    }
    
    entropy := seed_random_series()//(0x75658663)
    
    lowest_indices := make_array(&arena, [2]int, Dim*Dim)
    lowest_cardinality := max(u32)
    to_check := make_array(&arena, [2]int, Dim*Dim)
    
    for !rl.WindowShouldClose() {
        if rl.IsKeyPressed(.SPACE) {
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
                
                // for maze 
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
                
                // for dx in 0..<9 {
                //     if dx != lowest_index.x {
                //         append(&to_check, [2]int{dx, lowest_index.y})
                //     }
                // }
                // for dy in 0..<9 {
                //     if dy != lowest_index.y {
                //         append(&to_check, [2]int{lowest_index.x, dy})
                //     }
                // }
                
                // base_x, base_y := (lowest_index.x/3)*3, (lowest_index.y/3)*3
                // for dy in base_y..<base_y+3 {
                //     for dx in base_x..<base_x+3 {
                //         if dx != lowest_index.x {
                //             if dy != lowest_index.y {
                //                 append(&to_check, [2]int{dx, dy})
                //             }
                //         }
                //     }
                // }
                
                clear(&lowest_indices)
                lowest_cardinality = max(u32)
            }
            
            //
            // Check all effected neighbours
            //
            // @incomplete if needed neighbours of neighbours that changed need to be updated as well
            
            for next in slice(to_check) {
                x := next.x
                y := next.y
                cell := &grid[y*Dim + x]
                
                if !cell.done && card(cell.options) > 1 {
                    update_maze_cell(grid[:], cell, x, y)
                    // update_sudoku_cell(grid[:], cell, x, y)
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
                    if cardinality > 0 && cardinality < lowest_cardinality {
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
        rl.ClearBackground({0, 0x65, 0x60, 0x70})
        
        rl.BeginMode2D(camera)
        
        for entry in slice(to_check) {
            p := get_screen_p(entry.x, entry.y) + Pad
            rl.DrawRectangleRec({p.x-Pad, p.y-Pad, size+Pad*2, size+Pad*2}, rl.ColorAlpha(rl.YELLOW, 0.3))
        }
        
        for entry in slice(lowest_indices) {
            p := get_screen_p(entry.x, entry.y) + Pad
            rl.DrawRectangleRec({p.x-Pad, p.y-Pad, size+Pad*2, size+Pad*2}, rl.ColorAlpha(rl.GREEN, 0.3))
        }
        
        for y in 0..<Dim {
            for x in 0..<Dim {
                cell := &grid[y*Dim + x]
                
                p := get_screen_p(x, y) + Pad
                
                if cell.done {
                    tile_index := reduce_to_value(cell.options)
                    tile := tiles[tile_index]
                    rl.DrawTexturePro(tile, Tile_Size, {p.x, p.y, size, size}, 0, 0, rl.WHITE)
                } else if card(cell.options) == 0 {
                    rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                } else {
                    p -= Pad
                    for tile, i in MazeTile {
                        if tile not_in cell.options do continue
                        
                        option_size := cast(f32) Option_Size
                        
                        offset := vec_cast(f32, i % 3, i / 3)
                        op := p + option_size * offset
                        
                        tile_texture := tiles[tile]
                        rect := rl.Rectangle {op.x, op.y, option_size, option_size}
                        mouse := rl.GetMousePosition()
                        if mouse.x >= rect.x && mouse.y >= rect.y && mouse.x < rect.x + rect.width && mouse.y < rect.y + rect.height {
                            if rl.IsMouseButtonPressed(.LEFT) {
                                cell.options = {tile}
                                cell.done = true
                            }
                        }
                        rl.DrawTexturePro(tile_texture, Tile_Size, rect, 0, 0, rl.WHITE)
                    }
                }
            }
        }
        
        rl.EndMode2D()
        
        rl.EndDrawing()
    }
}

get_screen_p :: proc (x, y: int) -> (result: v2) {
    result = vec_cast(f32, x, y) * cast(f32) Draw_Size
    result.x += (cast(f32) Screen_Size.x - (size * Dim)) * 0.5
    result.y += size * 0.5
    return result
}

update_sudoku_cell :: proc (grid: []SudokuCell, cell: ^SudokuCell, x, y: int) {
    for option in cell.options {
        // 
        // check row
        // 
        
        for dx in 0..<Dim {
            if dx == x do continue
            other := grid[y*Dim + dx]
            if other.done {
                cell.options -= other.options
            }
        }
        
        // 
        // check column
        // 
        
        for dy in 0..<Dim {
            if dy == y do continue
            other := grid[dy*Dim + x]
            if other.done {
                cell.options -= other.options
            }
        }
        
        // 
        // check box
        // 
        
        base_x, base_y := (x/3)*3, (y/3)*3
        for dy in base_y..<base_y+3 {
            for dx in base_x..<base_x+3 {
                if x == dx && y == dy do continue
                other := grid[dy*Dim + dx]
                if other.done {
                    cell.options -= other.options
                }   
            }
        }
    }
}
update_maze_cell :: proc (grid: []MazeCell, cell: ^MazeCell, x, y: int) {
    for option in cell.options {
        ok := true
        socket := sockets[option]
        // west
        if x-1 >= 0  {
            n := grid[(y)*Dim + (x-1)].options
            if card(n) == 1 {
                ns := sockets[reduce_to_value(n)]
                ok &&= ns[0] == socket[2]
            }
        }
        // north
        if y-1 >= 0  {
            n := grid[(y-1)*Dim + (x)].options
            if card(n) == 1 {
                ns := sockets[reduce_to_value(n)]
                ok &&= ns[3] == socket[1]
            }
        }
        // east
        if x+1 < Dim {
            n := grid[(y)*Dim + (x+1)].options
            if card(n) == 1 {
                ns := sockets[reduce_to_value(n)]
                ok &&= ns[2] == socket[0]
            }
        }
        // south
        if y+1 < Dim {
            n := grid[(y+1)*Dim + (x)].options
            if card(n) == 1 {
                ns := sockets[reduce_to_value(n)]
                ok &&= ns[1] == socket[3]
            }
        }
        
        if !ok {
            cell.options -= {option}
        }
    }
}

// @premature_optimization
reduce_to_value :: proc (options: bit_set[$E]) -> (result: E) {
    assert(card(options) == 1)
    
    for tile in E {
        if tile in options {
            result = tile
            break
        }
    }
    
    return result
}