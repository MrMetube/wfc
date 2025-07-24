package main

import "base:builtin"
import "core:hash"
import "core:math"
import "core:time"
import rl "vendor:raylib"

Kernel :: 3

CollapseState :: enum {
    // @todo(viktor): remove this
    Uninitialized, 
    
    FindLowestEntropy,
    CollapseCell,
    Propagation,
    Contradiction,
    Done,
}

Collapse :: struct {
    state: CollapseState,
    
    grid:    [] Cell, 
    tiles:   [dynamic] Tile,
    
    dimension: [2]i32,
    
    to_check_index: int,
    to_check: [dynamic] Check,
    
    lowest_entropies: [dynamic]^Cell,
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
    
    total_frequency: f32,
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

init_collapse :: proc (collapse: ^Collapse, dimension: [2]i32, max_depth: u32, center: i32 = 1) {
    collapse.dimension = dimension
    collapse.center = center // size of the center of a tile
    collapse.max_depth = max_depth
    
    collapse.grid             = make([] Cell, collapse.dimension.x * collapse.dimension.y)
    collapse.tiles            = make([dynamic] Tile)
    collapse.to_check         = make([dynamic] Check)
    collapse.lowest_entropies = make([dynamic] ^Cell)
}

extract_tiles :: proc (using collapse: ^Collapse, img: rl.Image) {
    sockets := make(map[u32]u32, context.temp_allocator)
    next_socket_index: u32
    
    Socket :: struct {
        pixels: []rl.Color, // 2*center * Kernel*center
    }
    
    assert(img.format == .UNCOMPRESSED_R8G8B8A8)
    pixels := (cast([^]rl.Color) img.data)[:img.width * img.height]
    
    tile_pixels := make([dynamic]rl.Color, Kernel*center * Kernel*center, context.temp_allocator)
    data := make([dynamic]u8, context.temp_allocator)
    
    for min_y in 0..<img.height/center {
        for min_x in 0..<img.width/center {
            clear(&tile_pixels)
            clear(&data)
            
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

entangle_grid :: proc(using collapse: ^Collapse, region, full_region: Rectangle2i) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    max_frequency: f32
    for tile in tiles do max_frequency += cast(f32) tile.frequency
    
    for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            wrapped := rectangle_modulus(full_region, [2]i32{x,y})
            cell := &grid[wrapped.x + wrapped.y * dimension.x]
            
            cell.changed = false
            cell.checked = false
            cell.p = wrapped
            
            wave, ok := &cell.value.(WaveFunction)
            if ok {
                delete(wave.states)
                wave ^= {}
            } else {
                cell.value = WaveFunction{}
                wave = &cell.value.(WaveFunction)
            }
            
            wave.total_frequency = max_frequency
            wave.states = make(SuperPosition, len(tiles))
            wave.states_count = auto_cast len(wave.states)
            
            for &it in wave.states do it = true
            
            wave_recompute_entropy(collapse, wave)
        }
    }
    
    collapse.state = .FindLowestEntropy
}

collapse_one_of_the_cells_with_lowest_entropy :: proc (using collapse: ^Collapse, entropy: ^RandomSeries) -> (cell: ^Cell) {
    assert(len(lowest_entropies) != 0)
    
    cell = random_value(entropy, lowest_entropies[:])
    assert(cell != nil)
    
    wave := cell.value.(WaveFunction)
    total_freq: u32
    for state, tile_index in wave.states do if state do total_freq += tiles[tile_index].frequency
    choice := random_between_u32(entropy, 0, total_freq)
    
    pick: TileIndex
    for state, tile_index in wave.states {
        if !state do continue
        option := tiles[tile_index]
        if choice <= option.frequency {
            pick = tile_index
            break
        }
        choice -= option.frequency
    }
    
    wave_collapse(collapse, cell, pick)
    
    return cell
}

find_lowest_entropy :: proc (using collapse: ^Collapse, region, full_region: Rectangle2i) -> (next_state: CollapseState) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    no_contradictions := true
    lowest_entropy := PositiveInfinity
    
    collapsed_all_wavefunctions := true
    loop: for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            wrapped := rectangle_modulus(full_region, [2]i32{x,y})
            cell := &grid[wrapped.x + wrapped.y * dimension.x]
            
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
                    append_elem(&lowest_entropies, cell)
                }
            }
        }
    }
    
    next_state = .CollapseCell
    if no_contradictions {
        if collapsed_all_wavefunctions {
            next_state = .Done
        }
    } else {
        next_state = .Contradiction
    }
    
    return next_state
}

add_neighbour :: proc (using collapse: ^Collapse, p: [2]i32, depth: u32) {
    not_in_list := true
    for entry in to_check {
        if entry.raw_p == p {
            not_in_list = false
            break
        }
    }
    
    if not_in_list {
        append_elem(&to_check, Check { p, depth-1 })
    }
}

get_next_check :: proc (collapse: ^Collapse) -> (check: Check, ok: b32) {
    if collapse.to_check_index < len(collapse.to_check) {
        ok = true
        check = collapse.to_check[collapse.to_check_index]
        collapse.to_check_index += 1
    }
    return check, ok
}

matches :: proc (using collapse: ^Collapse, a: TileIndex, b: ^Cell, direction: Direction) -> (result: b32) {
    start := time.now()
    defer _matches += time.since(start)
    
    switch &value in b.value {
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
    
    return result
}

matches_tile :: proc(using collapse: ^Collapse, a_index, b_index: TileIndex, direction: Direction) -> (result: b32) {
    a_side, b_side := direction, Opposite_Direction[direction]
    
    a := tiles[a_index]
    b := tiles[b_index]
    result = a.sockets_index[a_side] == b.sockets_index[b_side]
    
    return result
}

wave_collapse :: proc (using collapse: ^Collapse, cell: ^Cell, pick: TileIndex) {
    wave := cell.value.(WaveFunction)
    cell.value = pick
    delete(wave.states)
}

wave_remove_state :: proc (collapse: ^Collapse, cell: ^Cell, wave: ^WaveFunction, state_index: TileIndex) {
    cell.changed = true
    wave.states[state_index] = false
    wave.states_count -= 1
    wave.total_frequency -= cast(f32) collapse.tiles[state_index].frequency
}

wave_recompute_entropy :: proc (using collapse: ^Collapse, wave: ^WaveFunction) {
    when true {
        before := wave.total_frequency
        wave.total_frequency = 0
        for state, index in wave.states do if state {
            wave.total_frequency += cast(f32) tiles[index].frequency
        }
        assert(abs(wave.total_frequency - before) < 0.0001)
        
        wave.entropy = 0
        for state, index in wave.states do if state {
            frequency := cast(f32) tiles[index].frequency
            probability := frequency / wave.total_frequency
            // Shannon entropy is the negative sum of P * log2(P)
            wave.entropy -= probability * math.log2(probability)
        }
    } else {
        wave.entropy = cast(f32) wave.states_count
    }
}
