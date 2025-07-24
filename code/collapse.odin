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
    
    grid:    [] Cell, 
    tiles:   [dynamic] Tile,
    
    dimension:   v2i,
    full_region: Rectangle2i,
    
    to_check_index: int,
    to_check:       [dynamic] Check,
    max_depth:      u32,
    
    lowest_entropies: [dynamic] ^Cell,
}

Cell :: struct {
    checked: b32,
    changed: b32,
    
    p: v2i,
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
    raw_p: v2i,
    
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
Delta := [Direction] v2i {
    .East  = {+1,  0},
    .North = { 0, -1},
    .West  = {-1,  0},
    .South = { 0, +1},
}

init_collapse :: proc (collapse: ^Collapse, dimension: v2i, max_depth: u32) {
    collapse.dimension = dimension
    collapse.full_region = rectangle_min_dimension(v2i{}, dimension)
    collapse.max_depth = max_depth
    
    collapse.grid             = make([] Cell, collapse.dimension.x * collapse.dimension.y)
    collapse.tiles            = make([dynamic] Tile)
    collapse.to_check         = make([dynamic] Check)
    collapse.lowest_entropies = make([dynamic] ^Cell)
}

entangle_grid :: proc(using collapse: ^Collapse, region: Rectangle2i, check_region_border := false) {
    clear(&lowest_entropies)
    clear(&to_check)
    to_check_index = 0
    
    max_frequency: f32
    for tile in tiles do max_frequency += cast(f32) tile.frequency
    
    for y in region.min.y..<region.max.y {
        for x in region.min.x..<region.max.x {
            wrapped := rectangle_modulus(full_region, v2i{x,y})
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
    
    if check_region_border {
        for y in region.min.y..<region.max.y {
            append_to_check(collapse, {region.min.x, y}, 1)
            append_to_check(collapse, {region.max.x-1, y}, 1)
        }
        for x in region.min.x..<region.max.x {
            append_to_check(collapse, {x, region.min.y}, 1)
            append_to_check(collapse, {x, region.max.y-1}, 1)
        }
        collapse.state = .Propagation
    } else {
        collapse.state = .FindLowestEntropy
    }
    
}

collapse_one_of_the_cells_with_lowest_entropy :: proc (using collapse: ^Collapse, entropy: ^RandomSeries) -> (cell: ^Cell) {
    assert(len(lowest_entropies) != 0)
    
    cell = random_value(entropy, lowest_entropies[:])
    assert(cell != nil)
    
    wave := cell.value.(WaveFunction)
    total_freq := cast(u32) wave.total_frequency
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

append_to_check :: proc (using collapse: ^Collapse, p: v2i, depth: u32) {
    not_in_list := true
    for entry in to_check {
        if entry.raw_p == p {
            not_in_list = false
            break
        }
    }
    
    if not_in_list {
        append_elem(&to_check, Check { p, depth })
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
        wave.entropy = 0
        for state, index in wave.states do if state {
            frequency := cast(f32) tiles[index].frequency
            probability := frequency / wave.total_frequency
            // Shannon entropy is the negative sum of P * log2(P)
            wave.entropy -= probability * log2(probability)
        }
    } else {
        wave.entropy = cast(f32) wave.states_count
    }
}
