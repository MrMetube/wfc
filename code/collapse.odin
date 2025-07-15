package main

import "base:builtin"
import "core:hash"
import "core:math"
import "core:time"
import rl "vendor:raylib"

Center :: 2
Kernel :: 3

Collapse :: struct {
    grid:    Array(Cell), 
    tiles:   Array(Tile),
    sockets: map[Socket]u32,
    next_socket_index: u32,
    
    dimension: [2]int,
    
    to_check: Array(Check),
    lowest_indices: Array([2]int),
    wrap_x: b32,
    wrap_y: b32,
}

Cell :: union {
    Tile,
    Wave,
}

Wave :: struct {
    entropy: f32,
    options_count_when_entropy_was_calculated: int,
    options: [dynamic]int,
}

Tile :: struct {
    center:        [Center*Center]rl.Color,
    sockets_index: [Direction]u32,
    frequency:     u32,
}

Socket :: struct {
    pixels: [2*Center * Kernel*Center]rl.Color,
}

Direction :: enum { East=0, North=1, South=2, West=3 }
Opposite_Direction := [Direction] Direction {
    .East  = .West,
    .North = .South,
    .West  = .East,
    .South = .North,
}
Delta := [Direction] [2]int {
    .East  = {+1,  0},
    .North = { 0, -1},
    .West  = {-1,  0},
    .South = { 0, +1},
}

Check :: struct {
    index: [2]int,
    depth: u32,
}

init_collapse :: proc (collapse: ^Collapse, arena: ^Arena, tile_count: u32, dimension: [2]int, wrap_x, wrap_y: b32) {
    collapse.wrap_x = wrap_x
    collapse.wrap_y = wrap_y
    
    collapse.dimension = dimension
    cell_count := collapse.dimension.x * collapse.dimension.y
    collapse.tiles          = make_array(arena, Tile,   tile_count)
    collapse.grid           = make_array(arena, Cell,   cell_count)
    collapse.to_check       = make_array(arena, Check,  cell_count)
    collapse.lowest_indices = make_array(arena, [2]int, cell_count)
}


extract_tiles :: proc (using collapse: ^Collapse, img: rl.Image) {
    assert(img.format == .UNCOMPRESSED_R8G8B8A8)
    pixels := (cast([^]rl.Color) img.data)[:img.width * img.height]
    
    cell_rect := rectangle_min_dimension(i32(0), 0, Center, Center)
    
    for min_y in 0..<img.height/Center {
        for min_x in 0..<img.width/Center {
            surroundings: FixedArray(Kernel*Center * Kernel*Center, rl.Color)
            
            for ky in i32(0)..<Kernel*Center {
                for kx in i32(0)..<Kernel*Center {
                    x := (min_x*Center + kx) % img.width
                    y := (min_y*Center + ky) % img.height
                    pixel := pixels[y*img.width+x]
                    append(&surroundings, pixel)
                }
            }
            
            raw_sur := slice(&surroundings)
            
            tile: Tile
            rw :: 3 * Center
            {
                west, east: Socket
                sw :: 2 * Center
                for y in 0..<3 * Center {
                    for x in 0..<sw {
                        west.pixels[y*sw + x] = raw_sur[y*rw + x]
                        east.pixels[y*sw + x] = raw_sur[y*rw + x+Center]
                    }
                }
                
                if west not_in sockets {
                    sockets[west] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.West] = sockets[west]
                
                if east not_in sockets {
                    sockets[east] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.East] = sockets[east]
            }
            
            {
                south, north: Socket
                sw :: 3 * Center
                for y in 0..<2 * Center {
                    for x in 0..<sw {
                        south.pixels[y*sw + x] = raw_sur[(y+Center)*rw + x]
                        north.pixels[y*sw + x] = raw_sur[y*rw + x]
                    }
                }
                
                if north not_in sockets {
                    sockets[north] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.North] = sockets[north]
                
                if south not_in sockets {
                    sockets[south] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.South] = sockets[south]
            }
            
            {
                for y in 0..<Center {
                    for x in 0..<Center {
                        tile.center[y*Center+x] = raw_sur[(y+Kernel)*(Center*Kernel)+(x+Kernel)]
                    }
                }
            }
            
            present: ^Tile
            loop: for &it in slice(tiles) {
                if tile.center == it.center && tile.sockets_index == it.sockets_index {
                    present = &it
                    break loop
                }
            }
            
            if present != nil {
                present.frequency += 1
            } else {
                tile.frequency = 1
                append(&tiles, tile)
            }
        }
    }
}

entangle_grid :: proc(using collapse: ^Collapse) {
    clear(&grid)
    clear(&to_check)
    
    for _ in 0..<len(grid.data) {
        options := make([dynamic]int)
        for _, i in slice(tiles) {
            builtin.append(&options, i)
        }
        append(&grid, Wave { options = options })
    }
}

step_observe :: proc (using collapse: ^Collapse, entropy: ^RandomSeries) -> (result: bool) {
    lowest_entropy := PositiveInfinity
    //
    // Pick a cell to collapse
    //
    collapse_start := time.now()
    clear(&to_check)
    
    if lowest_indices.count != 0 {
        lowest_index := random_choice(entropy, slice(lowest_indices))^
        lowest_cell  := &grid.data[lowest_index.y * dimension.x + lowest_index.x]
        
        wave := lowest_cell.(Wave)
        total_freq: u32
        for index in wave.options do total_freq += tiles.data[index].frequency
        choice := random_between_u32(entropy, 0, total_freq)
        
        pick: Tile
        for index in wave.options {
            option := tiles.data[index]
            if choice <= option.frequency {
                pick = option
                break
            }
            choice -= option.frequency
        }
        
        collapse_cell_and_check_all_neighbours(collapse, lowest_cell, lowest_index, pick)
    }
    
    _collapse += time.since(collapse_start)
    // // 
    // // Collapse all cells with only 1 options left
    // // 
    // for y in 0..<dimension {
    //     for x in 0..<dimension {
    //         index := y*dimension + x
    //         cell := &grid.data[index]
            
    //         if wave, ok := cell.(Wave); ok {
    //             if len(wave.options) == 1 {
    //                 collapse_cell(cell, tiles.data[(cell^).(Wave).options[0]])
    //                 add_neighbours(collapse, index, 10000)
    //             }
    //         }
    //     }
    // }
    // check_all_neighbours(collapse)
    // 
    // Collect all lowest cells
    // 
    collect_start := time.now()
    clear(&lowest_indices)
    lowest_entropy = max(f32)
    
    result = true
    
    loop: for y in 0..<dimension.y {
        for x in 0..<dimension.x {
            index := y*dimension.x + x
            cell := &grid.data[index]
            
            if wave, ok := cell.(Wave); ok {
                if len(wave.options) == 0 {
                    result = false
                    break loop
                }
                
                if wave.options_count_when_entropy_was_calculated != len(wave.options) {
                    wave.options_count_when_entropy_was_calculated = len(wave.options)
                    when false  {
                        total_frequency: f32
                        for option in wave.options {
                            total_frequency += cast(f32) tiles.data[option].frequency
                        }
                        
                        wave.entropy = 0
                        for option in wave.options {
                            frequency := cast(f32) tiles.data[option].frequency
                            probability := frequency / total_frequency
                            // Shannon entropy is the negative sum of P * log2(P)
                            wave.entropy -= probability * math.log2(probability)
                        }
                    } else {
                        wave.entropy = cast(f32) len(wave.options)
                    }
                        
                        
                    if lowest_entropy > wave.entropy {
                        lowest_entropy = wave.entropy
                        clear(&lowest_indices)
                    }
                    
                    if lowest_entropy >= wave.entropy {
                        append(&lowest_indices, [2]int{x,y})
                    }
                }
            }
        }
    }
    
    _collect += time.since(collect_start)
    return result
}

collapse_cell_and_check_all_neighbours :: proc (using collapse: ^Collapse, cell: ^Cell, index: [2]int, pick: Tile, depth: u32 = 100000) {
    collapse_cell(cell, pick)
    add_neighbours(collapse, index, depth)
    check_all_neighbours(collapse)
}

collapse_cell :: proc (cell: ^Cell, pick: Tile) {
    wave := cell.(Wave)
    cell ^= pick
    delete(wave.options)
}


add_neighbours :: proc (using collapse: ^Collapse, index: [2]int, depth: u32 = 100000) {
    start := time.now()
    defer _add_neighbours += time.since(start)
    
    for n in Delta {
        next := n + index

        ok := true
        if wrap_x {
            next.x = (next.x + dimension.x) % dimension.x
        } else {
            if next.x >= dimension.x || next.x < 0 {
                ok = false
            }
        }
        if wrap_y {
            next.y = (next.y + dimension.y) % dimension.y
        } else {
            if next.y >= dimension.y || next.y < 0 {
                ok = false
            }
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
            append(&to_check, Check {next, depth-1})
        }
    }
}

check_all_neighbours :: proc (using collapse: ^Collapse) {
    for index: i64; index < to_check.count; index += 1 {
        next := to_check.data[index]
        x := next.index.x
        y := next.index.y
        cell := &grid.data[y*dimension.x + x]
        
        if wave, ok := &cell.(Wave); ok {
            if reduce_entropy(collapse, cell, wave, {x, y}) {
                if next.depth > 0 {
                    add_neighbours(collapse, {x, y}, next.depth)
                }
            }
        }
    }
}

reduce_entropy :: proc (using collapse: ^Collapse, cell: ^Cell, wave: ^Wave, p: [2]int) -> (changed: b32) {
    // @todo(viktor): @speed O(n*m)
    // n := len(wave.options) and m := [1..4]*len(next.options) with next := grid[n+direction]
    // 
    // 
    #reverse for tile_index, index in wave.options {
        option := tiles.data[tile_index]
        
        for direction in Direction {
            if !matches(collapse, option, p, direction) {
                changed = true
                builtin.unordered_remove(&wave.options, index)
                break
            }
        }
    }
    
    return changed
}

matches :: proc(using collapse: ^Collapse, a: Tile, p: [2]int, direction: Direction) -> (result: bool) {
    start := time.now()
    defer _matches += time.since(start)
    
    p := p
    p += Delta[direction]
    if wrap_x {
        p.x = (p.x + dimension.x) % dimension.x
    } else {
        if p.x < 0 || p.x >= dimension.x {
            result = true
        }
    }
    if wrap_y {
        p.y = (p.y + dimension.y) % dimension.y
    } else {
        if p.y < 0 || p.y >= dimension.y {
            result = true
        }
    }
    
    if !result {
        next := grid.data[p.y*dimension.x + p.x]

        switch &value in next {
          case Wave:
            result = false 
            for index in value.options {
                b := tiles.data[index]
                result ||= matches_tile(a, b, direction)
                if result do break
            }
          case Tile:
            result = matches_tile(a, value, direction)
        }
    }
    
    return result
}

matches_tile :: proc(a, b: Tile, direction: Direction) -> (result: bool) {
    a_side, b_side := direction, Opposite_Direction[direction]
    
    result = a.sockets_index[a_side] == b.sockets_index[b_side]
    
    return result
}
