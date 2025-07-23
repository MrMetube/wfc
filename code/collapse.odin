package main

import "base:builtin"
import "core:hash"
import "core:math"
import "core:time"
import rl "vendor:raylib"

Kernel :: 3

CollapseState :: enum {
    Uninitialized,
    PickNextCell,
    Propagation,
    Contradiction,
    Done,
}

Collapse :: struct {
    state: CollapseState,
    grid:    [] Cell, 
    tiles:   [dynamic] Tile,
    sockets: map[u32]u32,
    next_socket_index: u32,
    
    dimension: [2]i32,
    
    to_check_index: int,
    to_check: [dynamic] Check,
    
    lowest_entropies: Array(^Cell),
    wrap: [2]b32,
    max_depth:  u32,
    
    center: i32,
}

Cell :: struct {
    checked: b32,
    changed: b32,
    
    p: [2]i32,
    value: union {
        TileIndex,
        WaveFunction,
    },
}

TileIndex :: int

WaveFunction :: struct {
    states: SuperPosition,
    states_count: u32,
    entropy: f32,
}

// s[0] means is tiles[0] possible
// we assume boolean possibility for now, but could change to real probability which allows for real valued effects and renormilization
SuperPosition :: []b32

Check :: struct {
    raw_p: [2]i32,
    
    depth: u32,
}

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
Delta := [Direction] [2]i32 {
    .East  = {+1,  0},
    .North = { 0, -1},
    .West  = {-1,  0},
    .South = { 0, +1},
}

init_collapse :: proc (collapse: ^Collapse, arena: ^Arena, dimension: [2]i32, wrap_x, wrap_y: b32, max_depth: u32, center: i32 = 1) {
    collapse.wrap.x = wrap_x
    collapse.wrap.y = wrap_y
    
    collapse.dimension = dimension
    collapse.center = center // size of the center of a tile
    collapse.max_depth = max_depth
    
    cell_count := collapse.dimension.x * collapse.dimension.y
    collapse.grid             = make([] Cell, cell_count)
    collapse.tiles            = make([dynamic] Tile)
    collapse.to_check         = make([dynamic] Check)
    collapse.lowest_entropies = make_array(arena, ^Cell, cell_count)
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
            len := 2*center * Kernel*center
            {
                west, east: Socket
                west.pixels = make([]rl.Color, len, context.temp_allocator)
                east.pixels = make([]rl.Color, len, context.temp_allocator)
                
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
                south.pixels = make([]rl.Color, len, context.temp_allocator)
                north.pixels = make([]rl.Color, len, context.temp_allocator)
                
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
                
                data := make([dynamic]u8)
                defer delete(data)
                for &it in tile.center        do append_elems(&data, ..to_bytes(&it))
                for &it in tile.sockets_index do append_elems(&data, ..to_bytes(&it))
                tile.hash = hash.djb2(data[:])
            }
            
            if present, ok := is_present(collapse, tile); ok {
                present.frequency += 1
            } else {
                temp := rl.Image {
                    data    = raw_data(tile_pixels), 
                    width   = center*Kernel, 
                    height  = center*Kernel, 
                    mipmaps = 1, 
                    format = .UNCOMPRESSED_R8G8B8A8,
                }
                tile.texture = rl.LoadTextureFromImage(temp)
                tile.frequency = 1
                append_elem(&tiles, tile)
            }
        }
    }
}

is_present :: proc (using collapse: ^Collapse, tile: Tile) -> (result: ^Tile, ok: bool) {
    loop: for &it in tiles {
        if tile.hash == it.hash {
            result = &it
            break loop
        }
    }
    
    return result, result != nil
}

entangle_grid :: proc(using collapse: ^Collapse, region: Rectangle2i) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            cell := &grid[y * dimension.x + x]
            cell.changed = false
            cell.checked = false
            
            if wave, ok := cell.value.(WaveFunction); ok {
                delete(wave.states)
                wave.states_count = 0
            } else {
                cell.value = WaveFunction{}
            }
            wave := &cell.value.(WaveFunction)
            
            wave.states = make(SuperPosition, len(tiles))
            wave.states_count = auto_cast len(wave.states)
            for &it in wave.states do it = true
        }
    }
    
    for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            cell := &grid[y * dimension.x + x]
            cell.p = {x, y}
            wave := &cell.value.(WaveFunction)
            recompute_wavefunction(collapse, wave)
        }
    }
    
    collapse.state = .Propagation
}

pick_next_cell :: proc (using collapse: ^Collapse, entropy: ^RandomSeries) -> (lowest_cell: ^Cell, pick: TileIndex) {
    if lowest_entropies.count != 0 {
        lowest_cell = random_value(entropy, slice(lowest_entropies))
        
        wave := lowest_cell.value.(WaveFunction)
        total_freq: u32
        for state, tile_index in wave.states do if state do total_freq += tiles[tile_index].frequency
        choice := random_between_u32(entropy, 0, total_freq)
        
        for state, tile_index in wave.states {
            if !state do continue
            option := tiles[tile_index]
            if choice <= option.frequency {
                pick = tile_index
                break
            }
            choice -= option.frequency
        }
    }
    
    return lowest_cell, pick
}

find_lowest_entropy :: proc (using collapse: ^Collapse, region: Rectangle2i) -> (next_state: CollapseState) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    no_contradictions := true
    lowest_entropy := PositiveInfinity
    
    collapsed_all_wavefunctions := true
    loop: for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            cell := &grid[x + y * dimension.x]
            cell.checked = false
            cell.changed = false
            
            if wave, ok := &cell.value.(WaveFunction); ok {
                collapsed_all_wavefunctions = false
                if wave.states_count == 0 {
                    no_contradictions = false
                    break loop
                }
                
                if lowest_entropy > wave.entropy {
                    lowest_entropy = wave.entropy
                    clear(&lowest_entropies)
                }
                
                if lowest_entropy == wave.entropy {
                    append(&lowest_entropies, cell)
                }
            }
        }
    }
    
    next_state = .PickNextCell
    if no_contradictions {
        if collapsed_all_wavefunctions {
            next_state = .Done
        }
    } else {
        next_state = .Contradiction
    }
    
    return next_state
}

collapse_cell :: proc (using collapse: ^Collapse, cell: ^Cell, pick: TileIndex) {
    wave := cell.value.(WaveFunction)
    cell.value = pick
    delete(wave.states)
    
    add_neighbours(collapse, cell, max_depth)
}

add_neighbours :: proc (using collapse: ^Collapse, cell: ^Cell, depth: u32) {
    for delta in Delta {
        p := cell.p + delta
        
        ok := true
        for entry in to_check {
            if entry.raw_p == p {
                ok = false
                break
            }
        }
        if !ok do continue
        
        append_elem(&to_check, Check { p, depth-1 })
    }
}

matches :: proc (using collapse: ^Collapse, a: TileIndex, cell: ^Cell, direction: Direction) -> (result: b32) {
    start := time.now()
    defer _matches += time.since(start)
    
    next, _ := get_neighbour(collapse, cell.p, direction)
    if next != nil {
        switch &value in next.value {
          case WaveFunction:
            result = false
            for b_state, b in value.states do if b_state {
                if matches_tile(collapse, a, b, direction) {
                    result = true
                    break
                }
            }
            
          case TileIndex:
            result = matches_tile(collapse, a, value, direction)
        }
    } else {
        result = true
    }
    
    return result
}

matches_tile :: proc(using collapse: ^Collapse, a_index, b_index: TileIndex, direction: Direction) -> (result: b32) {
    a_side, b_side := direction, Opposite_Direction[direction]
    
    a := tiles[a_index]
    b := tiles[b_index]
    result = a.sockets_index[a_side] == b.sockets_index[b_side]
    
    return result
}

get_neighbour :: proc (using collapse: ^Collapse, p: [2]i32, direction: Direction) -> (cell: ^Cell, next: [2]i32) {
    ok := true
    next = p + Delta[direction]
    
    if wrap.x {
        next.x = (next.x + dimension.x) % dimension.x
    } else {
        if next.x < 0 || next.x >= dimension.x {
            ok = false
        }
    }
    
    if wrap.y {
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

recompute_wavefunction :: proc (using collapse: ^Collapse, wave: ^WaveFunction) {
    // Update entropy
    when true {
        total_frequency: f32
        for state, tile_index in wave.states {
            if !state do continue
            total_frequency += cast(f32) tiles[tile_index].frequency
        }
        
        wave.entropy = 0
        for state, tile_index in wave.states {
            if !state do continue
            
            frequency := cast(f32) tiles[tile_index].frequency
            probability := frequency / total_frequency
            // Shannon entropy is the negative sum of P * log2(P)
            wave.entropy -= probability * math.log2(probability)
        }
    } else {
        wave.entropy = wave.states_count
    }
}
