package main

import "base:builtin"
import "core:time"
import rl "vendor:raylib"

Kernel :: 3
center :: 1

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
    
    entropy: ^RandomSeries,
    
    grid:    [] Cell, 
    tiles:   [dynamic] Tile,
    
    dimension:   v2i,
    full_region: Rectangle2i,
    
    to_check_index: int,
    to_check:       [dynamic] Check,
    
    lowest_entropies: [dynamic] ^Cell,
    
    max_frequency: f32
}

Cell :: struct {
    p: v2i,
    value: union {
        TileIndex,
        WaveFunction,
    },
}

TileIndex :: int

WaveFunction :: struct {
    // states[0] <=> tiles[0] is possible
    states:       [] b32,
    states_count: u32,
    
    total_frequency: f32,
    entropy: f32,
}

Check :: struct {
    raw_p: v2i,
    
    depth: i32,
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

Delta := [Direction] v2i {
    .East  = {+1,  0},
    .North = { 0, -1},
    .West  = {-1,  0},
    .South = { 0, +1},
}

init_collapse :: proc (collapse: ^Collapse, dimension: v2i, entropy: ^RandomSeries) {
    collapse.dimension = dimension
    collapse.entropy   = entropy
    collapse.full_region = rectangle_min_dimension(v2i{}, dimension)
    
    collapse.grid             = make([] Cell, collapse.dimension.x * collapse.dimension.y)
    collapse.tiles            = make([dynamic] Tile)
    collapse.to_check         = make([dynamic] Check)
    collapse.lowest_entropies = make([dynamic] ^Cell)
}

cell_entangle :: proc(using collapse: ^Collapse, cell: ^Cell, p: v2i) {
    cell.p = p
            
    wave, ok := &cell.value.(WaveFunction)
    if ok {
        delete(wave.states)
        wave ^= {}
    } else {
        cell.value = WaveFunction{}
        wave = &cell.value.(WaveFunction)
    }
    
    wave.total_frequency = max_frequency
    wave.states = make([] b32, len(tiles))
    wave.states_count = auto_cast len(wave.states)
    
    for &it in wave.states do it = true
    
    wave_recompute_entropy(collapse, wave)
}

entangle_grid :: proc(using collapse: ^Collapse, region: Rectangle2i, region_border_check_depth: i32 = 0) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    if max_frequency == 0 {
        for tile in tiles do max_frequency += cast(f32) tile.frequency
    }
    
    for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            wrapped := rectangle_modulus(full_region, v2i{x,y})
            cell := &grid[wrapped.x + wrapped.y * dimension.x]
            cell_entangle(collapse, cell, wrapped)
        }
    }
    
    collapse.state = .FindLowestEntropy
}

collapse_one_of_the_cells_with_lowest_entropy :: proc (using collapse: ^Collapse) -> (cell: ^Cell) {
    assert(len(lowest_entropies) != 0)
    
    cell = random_value(entropy, lowest_entropies[:])
    assert(cell != nil)
    
    wave := cell.value.(WaveFunction)
    total_freq := cast(u32) wave.total_frequency
    choice := random_between_u32(entropy, 0, total_freq)
    
    pick: TileIndex = -1
    for state, index in wave.states do if state {
        option := tiles[index]
        if choice <= option.frequency {
            pick = index
            break
        }
        choice -= option.frequency
    }
    assert(pick != -1)
    
    wave_collapse(collapse, cell, pick)
    
    return cell
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
            wrapped := rectangle_modulus(full_region, v2i{x,y})
            cell := &grid[wrapped.x + wrapped.y * dimension.x]
            
            if wave, ok := &cell.value.(WaveFunction); ok {
                collapsed_all_wavefunctions = false
                if wave.states_count == 0 {
                    no_contradictions = false
                    break loop
                } else {
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

maybe_append_to_check :: proc (using collapse: ^Collapse, p: v2i, depth: i32) {
    if depth < 0 do return
    
    in_list := false
    for entry in to_check {
        if entry.raw_p == p {
            in_list = true
            break
        }
    }
    if in_list do return
    
    append_elem(&to_check, Check { p, depth })
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

wave_collapse :: proc { wave_collapse_to_pick, wave_collapse_only_one_state }
wave_collapse_to_pick :: proc (using collapse: ^Collapse, cell: ^Cell, pick: TileIndex) {
    wave := cell.value.(WaveFunction)
    cell.value = pick
    delete(wave.states)
}

wave_collapse_only_one_state :: proc (using collapse: ^Collapse, cell: ^Cell) {
    wave := cell.value.(WaveFunction)
    assert(wave.states_count == 1)
    
    for state, index in wave.states do if state {
        cell.value = index
        delete(wave.states)
        break
    }
}

wave_remove_state :: proc (collapse: ^Collapse, cell: ^Cell, wave: ^WaveFunction, index: TileIndex) {
    wave.states_count -= 1
    wave.states[index] = false
    
    wave.total_frequency -= cast(f32) collapse.tiles[index].frequency
}

wave_recompute_entropy :: proc (using collapse: ^Collapse, wave: ^WaveFunction) {
    wave.entropy = 0
    for state, index in wave.states do if state {
        frequency := cast(f32) tiles[index].frequency
        probability := frequency / wave.total_frequency
        // Shannon entropy is the negative sum of P * log2(P)
        wave.entropy -= probability * log2(probability)
    }
}
