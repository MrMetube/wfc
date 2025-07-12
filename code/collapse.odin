package main

import "base:builtin"
import "core:hash"
import "core:time"
import rl "vendor:raylib"

Kernel :: 3

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

Direction :: enum { East, North, South, West }
Delta := [Direction] [2]int {
    .West  = {-1,  0},
    .North = { 0, -1},
    .East  = {+1,  0},
    .South = { 0, +1},
}


Check :: struct {
    index: [2]int,
    depth: u32,
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
                // @cleanup why is there no way to hash a bunch of values with begin -> hash.. -> end?
                center := sub_pixels.data[1*Kernel+1]
                c := hash.djb2(to_bytes(&center))
                e := hash.djb2(to_bytes(&tile.sockets[0]))
                n := hash.djb2(to_bytes(&tile.sockets[1]))
                w := hash.djb2(to_bytes(&tile.sockets[2]))
                s := hash.djb2(to_bytes(&tile.sockets[3]))
                
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
