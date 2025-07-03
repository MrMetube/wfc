package main

import "base:builtin"
import rl "vendor:raylib"


Screen_Size :: [2]i32{1920, 1080}
Dim :: 9

        
Draw_Size   := min(Screen_Size.x, Screen_Size.y) / (Dim+1)
Option_Size := Draw_Size / 4
Pad :: 0
size := cast(f32) Draw_Size - 2*Pad

Tile_Size :: rl.Rectangle{0,0,5,5}

Cell :: union {
    Tile,
    [dynamic]Tile,
}

Tile :: struct {
    texture: rl.Texture2D,
    sockets: [4]Socket,
}
Socket :: struct {
    edge: [5]Color3,
}
Color3 :: [3]u8

main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(120)
    
    camera := rl.Camera2D { zoom = 1 }
    
    e  := rl.LoadTexture("./e.bmp")
    ne := rl.LoadTexture("./ne.bmp")
    n  := rl.LoadTexture("./n.bmp")
    nw := rl.LoadTexture("./nw.bmp")
    w  := rl.LoadTexture("./w.bmp")
    sw := rl.LoadTexture("./sw.bmp")
    s  := rl.LoadTexture("./s.bmp")
    se := rl.LoadTexture("./se.bmp")
    textures := [?] rl.Texture { e, ne, n, nw, w, sw, s, se, }
    tiles: [len(textures)] Tile
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    for &tile, index in tiles {
        tile.texture = textures[index]
        img := rl.LoadImageFromTexture(tile.texture)
        defer rl.UnloadImage(img)
        assert(img.format == .UNCOMPRESSED_R8G8B8)
        // 
        // Extract sockets
        // 
        
        pixels := (cast([^]Color3) img.data)[:img.width * img.height]
        
        w := cast(int) img.width
        h := cast(int) img.height
        // east
        for y in 0..<h {
            x := w-1
            tile.sockets[0].edge[y] = pixels[y*w + x]
        }
        // north
        for x in 0..<w {
            y := 0
            tile.sockets[1].edge[x] = pixels[y*w + x]
        }
        
        // west
        for y in 0..<h {
            x := 0
            tile.sockets[2].edge[y] = pixels[y*w + x]
        }
        
        // south
        for x in 0..<w {
            y := h-1
            tile.sockets[3].edge[x] = pixels[y*w + x]
        }
    }
    
    grid: [Dim*Dim]Cell
    for &cell in grid {
        options := make([dynamic]Tile)
        for tile in tiles {
            builtin.append(&options, tile)
        }
        cell = options
    }
    
    entropy := seed_random_series(0x75658663)
    
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
                
                options := lowest_cell.([dynamic]Tile)
                pick    := random_choice(&entropy, options[:])^
                collapse_cell(grid[:], lowest_cell, lowest_index, pick, &to_check)
                
                clear(&lowest_indices)
                lowest_cardinality = max(u32)
            }
            
            // 
            // Collect all lowest cells
            // 
            
            for y in 0..<Dim {
                for x in 0..<Dim {
                    index := y*Dim + x
                    cell := &grid[index]
                    
                    if options, ok := cell.([dynamic]Tile); ok {
                        cardinality := cast(u32) len(options)
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
        }
        
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        rl.BeginMode2D(camera)
        
        for entry in slice(to_check) {
            p := get_screen_p(entry.x, entry.y) + Pad
            rl.DrawRectangleRec({p.x-Pad, p.y-Pad, size+Pad*2, size+Pad*2}, rl.ColorAlpha(rl.YELLOW, 0.3))
        }
        
        for entry in slice(lowest_indices) {
            p := get_screen_p(entry.x, entry.y) + Pad
            rl.DrawRectangleRec({p.x-Pad, p.y-Pad, size+Pad*2, size+Pad*2}, rl.ColorAlpha(rl.BLUE, 0.3))
        }
        
        for y in 0..<Dim {
            for x in 0..<Dim {
                cell := &grid[y*Dim + x]
                
                p := get_screen_p(x, y) + Pad
                
                switch value in cell^ {
                  case Tile:
                    rl.DrawTexturePro(value.texture, Tile_Size, {p.x, p.y, size, size}, 0, 0, rl.WHITE)
                  case [dynamic]Tile:
                    if len(value) == 0 {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        p -= Pad
                        for tile, i in tiles {
                            present: b32
                            for it in value do if it == tile { present = true; break }
                            if !present do continue
                            
                            option_size := cast(f32) Option_Size
                            
                            offset := vec_cast(f32, i % 3, i / 3)
                            op := p + option_size * offset
                            
                            rect := rl.Rectangle {op.x, op.y, option_size, option_size}
                            mouse := rl.GetMousePosition()
                            if mouse.x >= rect.x && mouse.y >= rect.y && mouse.x < rect.x + rect.width && mouse.y < rect.y + rect.height {
                                if rl.IsMouseButtonPressed(.LEFT) {
                                    collapse_cell(grid[:], cell, {x,y}, tile, &to_check)
                                }
                            }
                            rl.DrawTexturePro(tile.texture, Tile_Size, rect, 0, 0, rl.WHITE)
                        }
                    }
                }
            }
        }
        
        rl.EndMode2D()
        
        rl.EndDrawing()
    }
}

collapse_cell :: proc (grid: []Cell, cell: ^Cell, index: [2]int, pick: Tile, to_check: ^Array([2]int)) {
    options := cell.([dynamic]Tile)
    delete(options)
    cell ^= pick
    
    // for maze 
    nexts := [4][2]int{{-1, 0}, {+1, 0}, {0, -1}, {0, +1}}
    for n in nexts {
        next := n + index
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
            append(to_check, next)
        }
    }
    
    //
    // Check all effected neighbours
    //
    // @incomplete if needed neighbours of neighbours that changed need to be updated as well
    
    for next in slice(to_check) {
        x := next.x
        y := next.y
        other := &grid[y*Dim + x]
        
        if options, ok := &other.([dynamic]Tile); ok {
            if len(options) > 1 {
                update_maze_cell(grid[:], other, options, x, y)
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

update_maze_cell :: proc (grid: []Cell, cell: ^Cell, options: ^[dynamic]Tile, x, y: int) {
    #reverse for option, index in options {
        ok := true
        socket := option.sockets
        // west
        if x-1 >= 0  {
            n := grid[(y)*Dim + (x-1)]
            if tile, _ok := n.(Tile); _ok {
                ns := tile.sockets
                ok &&= ns[0] == socket[2]
            }
        }
        // north
        if y-1 >= 0  {
            n := grid[(y-1)*Dim + (x)]
            if tile, _ok := n.(Tile); _ok {
                ns := tile.sockets
                ok &&= ns[3] == socket[1]
            }
        }
        // east
        if x+1 < Dim {
            n := grid[(y)*Dim + (x+1)]
            if tile, _ok := n.(Tile); _ok {
                ns := tile.sockets
                ok &&= ns[2] == socket[0]
            }
        }
        // south
        if y+1 < Dim {
            n := grid[(y+1)*Dim + (x)]
            if tile, _ok := n.(Tile); _ok {
                ns := tile.sockets
                ok &&= ns[1] == socket[3]
            }
        }
        
        if !ok {
            builtin.unordered_remove(options, index)
        }
    }
    
    // @incompletet handle that we could have removed all options leaving the cell invalid and the grid unsolvable
}