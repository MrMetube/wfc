package main

import "base:intrinsics"
import rl "vendor:raylib"

// @note(viktor): All images only work with this N anyways and its out of scope to have it differ
N: i32 : 3

Collapse :: struct {
    states:   [dynamic] State,
    overlaps: [/* State_Id * len(states) + State_Id */] Direction_Mask,
    
    steps: [dynamic] Step,
    search_metric: Search_Metric,
    
    cells: [dynamic] Cell,
}

State_Id      :: distinct u32
Collapse_Step :: distinct i32

Invalid_State :: max(State_Id)

Search_Metric :: enum { States, Entropy }

State :: struct {
    _id:        State_Id,
    frequency: f32,
    middle:    v4,
}

////////////////////////////////////////////////

Step :: struct {
    step:  Collapse_Step,
    state: Step_State,
    
    // Search
    found: [dynamic] ^Cell,
    // Pick
    to_be_collapsed: ^Cell,
    // Collapse
    pickable_indices: [dynamic] int,
    // Propagate
    changes:        [dynamic] ^Cell,
    changes_cursor: int,
}

Step_State :: enum i32 {
    Search,
    Pick,
    Collapse,
    Propagate,
}

Step_Result :: struct {
    kind: enum { Continue, Next, Complete, Rewind },
    
    rewind_to: Collapse_Step,
}

////////////////////////////////////////////////

Cell :: struct {
    p: v2, 
    
    states:     [] State_Entry,
    neighbours: [] Neighbour,
    
    flags:  Cell_Flags,
    metric: f32,
    
    // Visual only
    points: [] v2, // for rendering the voronoi cell
}

Cell_Flags :: bit_set[enum { collapsed, dirty, edge }; u8]

Direction_Mask :: bit_set[Direction; u8]

Neighbour :: struct {
    cell: ^Cell,
    mask: Direction_Mask,
    strictness: u8,
}

State_Entry :: bit_field i32 {
    removed: bool          |  1,
    at:      Collapse_Step | 31,
}

////////////////////////////////////////////////

collapse_reset :: proc (c: ^Collapse) {
    clear(&c.states)
    for step in c.steps do delete_step(step)
    clear(&c.steps)
    
    delete(c.overlaps)
    c.overlaps = nil
}

////////////////////////////////////////////////

get_direction_mask :: proc (sampling_direction: v2, strictness: u8) -> (result: Direction_Mask) {
    threshold := cos((cast(f32) strictness) / 16 * Tau)
    result = get_direction_mask_with_threshold(sampling_direction, threshold)
    return result
}
get_direction_mask_with_threshold :: proc (sampling_direction: v2, threshold: f32) -> (result: Direction_Mask) {
    for other in Direction {
        sampling_normal := normalize(sampling_direction)
        other_normal    := normalized_direction(other)
        
        closeness := dot(sampling_normal, other_normal)
        if closeness >= threshold {
            result += { other }
        }
    }
    
    return result
}

////////////////////////////////////////////////

step_update :: #force_no_inline proc (c: ^Collapse, entropy: ^RandomSeries, current: ^Step) -> (result: Step_Result) {
    spall_proc()
    assert(c.states != nil)
    
    result.kind = .Continue
    
    switch current.state {
      case .Search:
        spall_scope("Find next cell to be collapsed")
        
        spall_begin("Update dirty metrics")
        switch c.search_metric {
          case .Entropy:
            for &cell in c.cells do if .dirty in cell.flags {
                cell.flags -= { .dirty }
                
                total_frequency: f32
                for state, id in cell.states do if !state.removed {
                    frequency := c.states[id].frequency
                    
                    total_frequency += frequency
                }
                
                entropy: f32
                for state, id in cell.states do if !state.removed {
                    frequency := c.states[id].frequency
                    
                    probability := frequency / total_frequency
                    
                    entropy -= probability * log2(probability)
                }
                
                cell.metric = entropy
            }
            
          case .States: 
            for &cell in c.cells do if .dirty in cell.flags {
                cell.flags -= { .dirty }
                
                for state in cell.states do if !state.removed {
                    cell.metric += 1
                }
            }
        }
        
        spall_end()
        
        spall_begin("Search metric")
        lowest := +Infinity
        for &cell in c.cells do if .collapsed not_in cell.flags {
            if lowest > cell.metric {
                lowest = cell.metric
                clear(&current.found)
            }
            
            if lowest == cell.metric {
                append(&current.found, &cell)
            }
        }
        spall_end()
        
        if len(current.found) == 0 {
            result.kind = .Complete
        } else {
            current.state = .Pick
        }
        
      case .Pick:
        spall_scope("Pick a cell from the found")
        
        assert(current.to_be_collapsed == nil)
        
        if len(current.found) == 0 {
            result.kind = .Rewind
            result.rewind_to = current.step - 1
        } else {
            index := random_index(entropy, current.found)
            current.to_be_collapsed = current.found[index]
            unordered_remove(&current.found, index)
            
            assert(.collapsed not_in current.to_be_collapsed.flags)
            
            clear(&current.pickable_indices)
            for &state, index in current.to_be_collapsed.states do if !state.removed {
                append(&current.pickable_indices, index)
            }
            
            current.state = .Collapse
        }
        
      case .Collapse:
        spall_scope("Collapse chosen cell")
        
        assert(current.to_be_collapsed != nil)
        
        if len(current.pickable_indices) == 0 {
            result.kind = .Rewind 
        } else {
            cell := current.to_be_collapsed
            assert(.collapsed not_in cell.flags)
            
            total: f32
            for index in current.pickable_indices {
                assert(!cell.states[index].removed)
                total += c.states[index].frequency
            }
            
            target := random_between(entropy, f32, 0, total)
            append_change_if_not_already_scheduled(current, cell)
            
            pick := Invalid_State
            pickable_index := -1
            for index, pick_index in current.pickable_indices {
                target -= c.states[index].frequency
                
                if target <= 0 {
                    pick = cast(State_Id) index
                    pickable_index = pick_index
                    break
                }
            }
            
            if pick != Invalid_State {
                for &state, id in cell.states do if !state.removed {
                    if cast(State_Id) id != pick {
                        state.removed = true
                        state.at = current.step
                    }
                }
                
                unordered_remove(&current.pickable_indices, pickable_index)
                cell.flags += { .collapsed, .dirty }
            } else {
                result.rewind_to = current.step
                result.kind = .Rewind 
            }
        }
        
        current.state = .Propagate
        
      case .Propagate:
        spall_scope("Propagate changes")
        
        assert(len(current.changes) != 0)
        
        change: ^Cell
        for change == nil && current.changes_cursor < len(current.changes) {
            change = current.changes[current.changes_cursor]
            current.changes_cursor += 1
        }
        
        assert(change != nil)
        if change != nil {
            DoBits :: false
            when DoBits {
                change_states_ := make([] u64, 1 + len(change.states) / 64, context.temp_allocator)
                
                for state, state_index in change.states do if !state.removed {
                    index := state_index / 64
                    bit_index := cast(u64) state_index % 64
                    change_states_[index] |= 1 << bit_index
                }
            }
            
            propagate_remove: for &neighbour in change.neighbours {
                cell := neighbour.cell
                if .collapsed in cell.flags do continue
                if .edge in cell.flags do continue
                
                states_count := 0
                did_change := false
                
                when DoBits {
                    cell_states_ := make([] u64, 1 + len(cell.states) / 64, context.temp_allocator)
                    
                    for state, state_index in cell.states do if !state.removed {
                        index := state_index / 64
                        bit_index := cast(u64) state_index % 64
                        cell_states_[index] |= 1 << bit_index
                    }
                }
                
                spall_begin("recalc states")
                when !DoBits {
                    count := len(c.states)
                    recalc_states: for &from, from_id in cell.states do if !from.removed {
                        supported := false
                        inner: for to, to_id in change.states do if !to.removed {
                            #no_bounds_check overlap := c.overlaps[from_id * count + to_id]
                            masked := overlap & neighbour.mask
                            if masked != {} {
                                states_count += 1
                                supported = true
                                break inner
                            }
                        }
                        
                        if !supported {
                            from.removed = true
                            from.at = current.step
                            did_change = true
                        }
                    }
                } else {
                    count_trailing_zeros :: intrinsics.count_trailing_zeros
                    
                    #no_bounds_check for from, from_removed_index in cell_states_ {
                        from_it := from
                        from_index := from_removed_index * 64
                        recalc_states: for from_it != 0 {
                            from_zeros := count_trailing_zeros(from_it)
                            
                            from_it >>= from_zeros
                            if from_it & 1 == 0 do continue
                            
                            from_index += cast(int) from_zeros
                            if from_index >= len(c.states) do break recalc_states
                            
                            defer from_it >>= 1
                            defer from_index += 1
                            
                            tos: for to, to_removed_index in change_states_ {
                                to_it := to
                                
                                to_index := to_removed_index * 64
                                for to_it != 0 {
                                    to_zeros := count_trailing_zeros(to_it)
                                    
                                    to_it >>= to_zeros
                                    if to_it & 1 == 0 do continue
                                    
                                    to_index += cast(int) to_zeros
                                    if to_index >= len(c.states) do break tos
                                    
                                    defer to_it >>= 1
                                    defer to_index += 1
                                    
                                    overlap := c.overlaps[from_index * len(c.states) + to_index]
                                    masked := overlap & neighbour.mask
                                    if masked != {} {
                                        states_count += 1
                                        continue recalc_states
                                    }
                                }
                            }
                            
                            state := &cell.states[from_index]
                            state.removed = true
                            state.at = current.step
                            did_change = true
                        }
                    }
                }
                spall_end()
                
                if did_change {
                    append_change_if_not_already_scheduled(current, cell)
                    
                    if states_count == 0 {
                        entropy := seed_random_series()
                        // @note(viktor): maybe increase strictness for solved cells
                        for &cell in c.cells {
                            for &n in cell.neighbours {
                                if .collapsed in n.cell.flags {
                                        if random_between(&entropy, f32, 0, 1) < cooling_chance {
                                        if n.strictness > 1 {
                                            n.strictness -= 1
                                            n.mask = get_direction_mask(cell.p - n.cell.p, n.strictness)
                                        }
                                    }
                                } else {
                                    if n.strictness < 8 {
                                        if random_between(&entropy, f32, 0, 1) < heating_chance {
                                            n.strictness += 1
                                            n.mask = get_direction_mask(cell.p - n.cell.p, n.strictness)
                                        }
                                    }
                                }
                            }
                        }
                        // @note(viktor): reduce strictness
                        for it in current.changes {
                            for &n in it.neighbours {
                                if n.strictness < 8 {
                                    n.strictness += 1
                                }
                                n.mask = get_direction_mask(it.p - n.cell.p, n.strictness)
                            }
                        }
                            
                        the_cause: Collapse_Step
                        for &n in cell.neighbours {
                            for state in n.cell.states {
                                if state.removed && state.at < current.step {
                                    the_cause = max(the_cause, state.at)
                                }
                            }
                        }
                        
                        result.kind = .Rewind
                        result.rewind_to = the_cause
                        
                        break propagate_remove
                    } else {
                        cell.flags += { .dirty }
                        if states_count == 1 {
                            cell.flags += { .collapsed }
                        }
                    }
                }
            }
            
            if current.changes_cursor == len(current.changes) {
                result.kind = .Next
            }
        } else {
            result.kind = .Rewind
        }
    }
    
    return result
}

append_change_if_not_already_scheduled :: proc (current: ^Step, cell: ^Cell) {
    spall_proc()
    
    scheduled := false
    for &change, index in current.changes {
        if change == cell {
            if index < current.changes_cursor {
            } else {
                scheduled = true
                break
            }
        }
    }
    
    if !scheduled {
        append(&current.changes, cell)
    }
}

delete_step :: proc (step: Step) {
    delete(step.found)
    delete(step.pickable_indices)
    delete(step.changes)
}

////////////////////////////////////////////////

calculate_average_color :: proc (c: ^Collapse, cell: ^Cell) -> (result: v4) {
    count: f32
    for state, id in cell.states do if !state.removed || state.at > viewing_step {
        state := c.states[id]
        result += state.middle * state.frequency
        count += state.frequency
    }
    
    result = safe_ratio_0(result, count)
    return result
}

delete_cell :: proc (cell: Cell) {
    delete(cell.points)
    delete(cell.neighbours)
    delete(cell.states)
}

////////////////////////////////////////////////

extract_states :: proc (c: ^Collapse, pixels: [] rl.Color, width, height: i32, wrap: [2] bool) {
    spall_proc()
    
    temp_values: [dynamic] rl.Color
    defer delete(temp_values)
    
    // @note(viktor): used for checking overlaps
    subregion_hashes: [dynamic] [Direction] u64
    defer delete(subregion_hashes)
    
    // @incomplete: Allow for rotations and mirroring here
    spall_begin("State Extraction")
    max_x := wrap.x ? width  : width  - N
    max_y := wrap.y ? height : height - N
    for by in 0..<max_y {
        for bx in 0..<max_x {
            clear(&temp_values)
            
            for dy in 0..<N {
                for dx in 0..<N {
                    x := (bx + dx) % width
                    y := (by + dy) % height
                    append(&temp_values, pixels[x + (height-1-y) * width])
                }
            }
            
            {
                hashes: [Direction] u64
                {
                    subsections := [Direction] Rectangle2i {
                        .E  = { { 1, 0 }, {   N,   N } },
                        .NE = { { 1, 1 }, {   N,   N } },
                        .N  = { { 0, 1 }, {   N,   N } },
                        .NW = { { 0, 1 }, { N-1,   N } },
                        .W  = { { 0, 0 }, { N-1,   N } },
                        .SW = { { 0, 0 }, { N-1, N-1 } },
                        .S  = { { 0, 0 }, {   N, N-1 } },
                        .SE = { { 1, 0 }, {   N, N-1 } },
                    }
                    
                    for r, direction in subsections {
                        // @note(viktor): iterative fnv64a hash
                        seed :: u64(0xcbf29ce484222325)
                        hash := seed
                        for dy in r.min.y ..< r.max.y {
                            for dx in r.min.x ..< r.max.x {
                                value := temp_values[dx + dy * N]
                                integer := cast(u64) transmute(u32) value
                                hash = (hash ~ integer) * 0x100000001b3
                            }
                        }
                        
                        hashes[direction] = hash
                    }
                }
                
                found := false
                search: for &other, other_id in c.states {
                    other_hashes := subregion_hashes[other_id]
                    if other_hashes != hashes do continue search
                    
                    other.frequency += 1
                    found = true
                    break search
                }
                
                if !found {
                    state := State {
                        middle    = rl_color_to_v4(temp_values[N/4+N/4*N]),
                        frequency = 1,
                    }
                    
                    append(&c.states, state)
                    append(&subregion_hashes, hashes)
                    assert(len(c.states) == len(subregion_hashes))
                }
            }
        }
    }
    spall_end()
    
    spall_begin("Overlaps generation")
    make(&c.overlaps, square(len(c.states)))
    
    for a_hashes, ai in subregion_hashes {
        for b_hashes, bi in subregion_hashes {
            for d in Direction {
                a_hash := a_hashes[d]
                b_hash := b_hashes[opposite_direction(d)]
                
                if a_hash == b_hash {
                    c.overlaps[ai * len(c.states) + bi] += { d }
                }
            }
        }
    }
    spall_end()
}