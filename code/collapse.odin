package main

import "base:builtin"
import "core:hash"
import "core:math"
import "core:time"
import rl "vendor:raylib"

Kernel :: 3

Collapse :: struct {
    grid:    []Cell, 
    tiles:   Array(Tile),
    sockets: map[u32]u32,
    next_socket_index: u32,
    
    dimension: [2]int,
    
    to_check: Array(Check),
    lowest_indices: Array([2]int),
    wrap_x: b32,
    wrap_y: b32,
    max_depth:  u32,
    
    center: i32,
}

Cell :: union {
    Tile,
    WaveFunction,
}

WaveFunction :: struct {
    states: SuperPosition,
    
    entropy: f32,
    compatible_states: [Direction]SuperPosition,
}

// s[0] means is tiles[0] possible
// we assume boolean possibility for now, but could change to real probability which allows for real valued effects and renormilization
SuperPosition :: []b32

Tile :: struct {
    center: []rl.Color, // Center*Center
    
    sockets_index: [Direction]u32,
    frequency: u32,
    hash:      u32,
    
    texture: rl.Texture,
}

Socket :: struct {
    pixels: []rl.Color, // 2*center * Kernel*center
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

init_collapse :: proc (collapse: ^Collapse, arena: ^Arena, tile_count: u32, dimension: [2]int, wrap_x, wrap_y: b32, max_depth: u32, center: i32 = 1) {
    collapse.wrap_x = wrap_x
    collapse.wrap_y = wrap_y
    
    collapse.dimension = dimension
    cell_count := collapse.dimension.x * collapse.dimension.y
    collapse.tiles          = make_array(arena, Tile,   tile_count)
    collapse.grid           = make([]Cell,  cell_count)
    collapse.to_check       = make_array(arena, Check,  cell_count)
    collapse.lowest_indices = make_array(arena, [2]int, cell_count)
    collapse.center = center
    collapse.max_depth = max_depth
}


extract_tiles :: proc (using collapse: ^Collapse, img: rl.Image) {
    assert(img.format == .UNCOMPRESSED_R8G8B8A8)
    pixels := (cast([^]rl.Color) img.data)[:img.width * img.height]
    
    tile_pixels := make([dynamic]rl.Color, Kernel*center * Kernel*center, context.temp_allocator)
    for min_y in 0..<img.height/center {
        for min_x in 0..<img.width/center {
            clear(&tile_pixels)
            
            tile: Tile
            for ky in i32(0)..<Kernel*center {
                for kx in i32(0)..<Kernel*center {
                    x := (min_x*center + kx) % img.width
                    y := (min_y*center + ky) % img.height
                    pixel := pixels[y*img.width+x]
                    append_elems(&tile_pixels, pixel)
                }
            }
            
            tile_pixels := tile_pixels[:]
            rw := 3 * center
            {
                west, east: Socket
                west.pixels = make([]rl.Color, 2*center * Kernel*center)
                east.pixels = make([]rl.Color, 2*center * Kernel*center)
                
                sw := 2 * center
                for y in 0..<3 * center {
                    for x in 0..<sw {
                        west.pixels[y*sw + x] = tile_pixels[y*rw + x]
                        east.pixels[y*sw + x] = tile_pixels[y*rw + x+center]
                    }
                }
                
                west_hash := hash.djb2(slice_to_bytes(west.pixels))
                if west_hash not_in sockets {
                    sockets[west_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.West] = sockets[west_hash]
                
                east_hash := hash.djb2(slice_to_bytes(east.pixels))
                if east_hash not_in sockets {
                    sockets[east_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.East] = sockets[east_hash]
            }
            
            {
                south, north: Socket
                south.pixels = make([]rl.Color, 2*center * Kernel*center)
                north.pixels = make([]rl.Color, 2*center * Kernel*center)
                
                sw := 3 * center
                for y in 0..<2 * center {
                    for x in 0..<sw {
                        south.pixels[y*sw + x] = tile_pixels[(y+center)*rw + x]
                        north.pixels[y*sw + x] = tile_pixels[y*rw + x]
                    }
                }
                
                north_hash := hash.djb2(slice_to_bytes(north.pixels))
                if north_hash not_in sockets {
                    sockets[north_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.North] = sockets[north_hash]
                
                south_hash := hash.djb2(slice_to_bytes(south.pixels))
                if south_hash not_in sockets {
                    sockets[south_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.South] = sockets[south_hash]
            }
            
            {
                tile.center = make([]rl.Color, center*center)
                cw := center
                for y in 0..<center {
                    for x in 0..<cw {
                        tile.center[y*cw + x] = tile_pixels[(y+center)*rw + x]
                    }
                }
                
                data := make([dynamic]u8, context.temp_allocator)
                for &it in tile.center do append_elems(&data, ..to_bytes(&it))
                for &it in tile.sockets_index do append_elems(&data, ..to_bytes(&it))
                tile.hash = hash.djb2(data[:])
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
                tile.frequency = 1
                temp:= rl.Image {
                    data    = raw_data(tile_pixels), 
                    width   = center*Kernel, 
                    height  = center*Kernel, 
                    mipmaps = 1, 
                    format = .UNCOMPRESSED_R8G8B8A8,
                }
                tile.texture = rl.LoadTextureFromImage(temp)
                append(&tiles, tile)
            }
        }
    }
}

entangle_grid :: proc(using collapse: ^Collapse) {
    for &cell in grid {
        if wave, ok := cell.(WaveFunction); ok {
            delete(wave.states)
            
            for &c in wave.compatible_states {
                delete(c)
            }
        } else {
            cell = WaveFunction{}
        }
        
    }
    
    clear(&to_check)
    
    for &cell in grid {
        wave := &cell.(WaveFunction)
        
        wave.states = make(SuperPosition, tiles.count)
        for &it in wave.states do it = true
        for &c in wave.compatible_states {
            c = make(SuperPosition, tiles.count)
            for &it in c do it = true
        }
    }
    
    for y in 0..<dimension.y {
        for x in 0..<dimension.x {
            cell := &grid[y * dimension.x + x]
            wave := &cell.(WaveFunction)
            recompute_wavefunction(collapse, wave, {x,y})
        }
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
        lowest_cell  := &grid[lowest_index.y * dimension.x + lowest_index.x]
        
        wave := lowest_cell.(WaveFunction)
        total_freq: u32
        for state, tile_index in wave.states do if state do total_freq += tiles.data[tile_index].frequency
        choice := random_between_u32(entropy, 0, total_freq)
        
        pick: Tile
        for state, tile_index in wave.states {
            if !state do continue
            option := tiles.data[tile_index]
            if choice <= option.frequency {
                pick = option
                break
            }
            choice -= option.frequency
        }
        
        collapse_cell_and_check_all_neighbours(collapse, lowest_cell, lowest_index, pick)
    }
    
    _collapse += time.since(collapse_start)
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
            cell := &grid[index]
            
            if wave, ok := &cell.(WaveFunction); ok {
                // @speed can this be done with fewer loops?
                all_states_zero := true
                for state in wave.states {
                    if !state do continue
                    
                    all_states_zero = false
                    break
                }
                if all_states_zero {
                    result = false
                    break loop
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
    
    _collect += time.since(collect_start)
    return result
}

collapse_cell_and_check_all_neighbours :: proc (using collapse: ^Collapse, cell: ^Cell, index: [2]int, pick: Tile) {
    collapse_cell(cell, pick)
    // @todo(viktor): this will also readd the collapsed
    add_neighbours(collapse, index, max_depth)
    check_all_neighbours(collapse)
}

collapse_cell :: proc (cell: ^Cell, pick: Tile) {
    wave := cell.(WaveFunction)
    cell ^= pick
    delete(wave.states)
}


add_neighbours :: proc (using collapse: ^Collapse, index: [2]int, depth: u32) {
    start := time.now()
    defer _add_neighbours += time.since(start)
    
    for direction in Direction {
        cell, next := get_neighbour(collapse, index, direction)
        
        ok := cell != nil
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

// 30s on city
// 10s on city

check_all_neighbours :: proc (using collapse: ^Collapse) {
    for index: i64; index < to_check.count; index += 1 {
        next := to_check.data[index]
        p := next.index
        x := p.x
        y := p.y
        
        cell := &grid[y*dimension.x + x]
        
        if wave, ok := &cell.(WaveFunction); ok {
            changed: b32
            // @todo(viktor): @speed O(n*m)
            
            for &c, direction in wave.compatible_states{
                for &state, tile_index in wave.states {
                    if !state do continue
                    a := tiles.data[tile_index]
                    
                    matches: b32
                    {
                        start := time.now()
                        defer _matches += time.since(start)
                        
                        next, _ := get_neighbour(collapse, p, direction)
                        if next != nil {
                            switch &value in next {
                              case WaveFunction:
                                matches = false
                                for n_state, n_tile_index in value.states {
                                    if !n_state do continue
                                    b := tiles.data[n_tile_index]
                                    if matches_tile(a, b, direction) {
                                        matches = true
                                        break
                                    }
                                }
                              case Tile:
                                matches = matches_tile(a, value, direction)
                            }
                        } else {
                            matches = true
                        }
                    }
                    
                    c[tile_index] = matches
                    
                    if !c[tile_index] {
                        changed = true
                        state = false
                    }
                }
            }
            
            if changed {
                recompute_wavefunction(collapse, wave, p)
                if next.depth > 0 {
                    add_neighbours(collapse, p, next.depth)
                }
            }
        }
    }
}

get_neighbour :: proc (using collapse: ^Collapse, p: [2]int, direction: Direction) -> (cell: ^Cell, next: [2]int) {
    ok := true
    next = p + Delta[direction]
    if wrap_x {
        next.x = (next.x + dimension.x) % dimension.x
    } else {
        if next.x < 0 || next.x >= dimension.x {
            ok = false
        }
    }
    if wrap_y {
        next.y = (next.y + dimension.y) % dimension.y
    } else {
        if next.y < 0 || next.y >= dimension.y {
            ok = false
        }
    }
    
    if ok {
        cell = &grid[next.y*dimension.x + next.x]
    }
    return cell, next
}

matches_tile :: proc(a, b: Tile, direction: Direction) -> (result: b32) {
    a_side, b_side := direction, Opposite_Direction[direction]
    
    result = a.sockets_index[a_side] == b.sockets_index[b_side]
    
    return result
}

recompute_wavefunction :: proc (using collapse: ^Collapse, wave: ^WaveFunction, p: [2]int) {
    // Update entropy
    when !false {
        total_frequency: f32
        for state, tile_index in wave.states {
            if !state do continue
            total_frequency += cast(f32) tiles.data[tile_index].frequency
        }
        
        wave.entropy = 0
        for state, tile_index in wave.states {
            if !state do continue
            
            frequency := cast(f32) tiles.data[tile_index].frequency
            probability := frequency / total_frequency
            // Shannon entropy is the negative sum of P * log2(P)
            wave.entropy -= probability * math.log2(probability)
        }
    } else {
        wave.entropy = 0
        for state in wave.states {
            if !state do continue
            wave.entropy += 1
        }
    }
}
