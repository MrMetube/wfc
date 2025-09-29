package main

import rl "vendor:raylib"

// @note(viktor): All images only work with this N anyways and its out of scope to have it differ
N: i32 : 3

Collapse :: struct {
    states:   [dynamic] State,
    supports: [/* State_Id * len(states) + State_Id */] Direction_Mask,
    
    steps: [dynamic] Step,
    search_metric: Search_Metric,
    
    cells: [dynamic] Cell,
    
    // Extraction
    is_defining_state: bool,
    temp_state_values: [dynamic] rl.Color,
    // @note(viktor): used for checking overlaps
    temp_subregion_hashes: [dynamic] [Direction] u64,
}

State_Id      :: distinct u32
Collapse_Step :: distinct i32

Invalid_State         :: max(State_Id)
Invalid_Collapse_Step :: max(Collapse_Step)

Search_Metric :: enum { States, Entropy }

State :: struct {
    id:        State_Id,
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

Step_State :: enum {
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
    
    flags:   Cell_Flags,
    entropy: f32,
    
    // Visual only
    average_color: v4,
    points: [] v2, // for rendering the voronoi cell
}

Cell_Flags :: bit_set[enum { collapsed, dirty, edge }; u8]

Direction_Mask :: bit_set[Direction; u8]

Neighbour :: struct {
    cell: ^Cell,
    mask: Direction_Mask,
}

State_Entry :: struct #align(64) {
    removed_at: Collapse_Step,
}

////////////////////////////////////////////////

collapse_reset :: proc (c: ^Collapse) {
    clear(&c.states)
    for step in c.steps do delete_step(step)
    clear(&c.steps)
    
    clear(&c.temp_state_values)
    
    delete(c.supports)
    c.supports = nil
    
    c.is_defining_state = false
}

////////////////////////////////////////////////

get_direction_mask :: proc (sampling_direction: v2) -> (result: Direction_Mask) {
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
    // @note(viktor): this will only be used if result.kind == .Rewind
    result.rewind_to = current.step - 1
    
    switch current.state {
      case .Search:
        spall_scope("Find next cell to be collapsed")
        
        lowest := +Infinity
        spall_begin("Dirtyness")
        for &cell in c.cells do if .dirty in cell.flags {
            cell.flags -= { .dirty }
            
            calculate_average_color(c, &cell, current.step)
            if c.search_metric == .Entropy do calculate_entropy(c, &cell, current.step)
        }
        spall_end()
        
        spall_begin("Search metric")
        for &cell in c.cells do if .collapsed not_in cell.flags {
            value: f32
            switch c.search_metric {
              case .Entropy: value = cell.entropy
              case .States:  
                for state in cell.states do if state.removed_at > current.step {
                    value += 1
                }
            }
            
            if lowest > value {
                lowest = value
                clear(&current.found)
            }
            
            if lowest == value {
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
        } else {
            index := random_index(entropy, current.found)
            current.to_be_collapsed = current.found[index]
            unordered_remove(&current.found, index)
            
            assert(.collapsed not_in current.to_be_collapsed.flags)
            
            clear(&current.pickable_indices)
            for &state, index in current.to_be_collapsed.states do if state.removed_at > current.step {
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
                assert(cell.states[index].removed_at > current.step)
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
                for &state, id in cell.states do if state.removed_at > current.step {
                    if cast(State_Id) id != pick {
                        state.removed_at = current.step
                    }
                }
                
                unordered_remove(&current.pickable_indices, pickable_index)
                cell.flags += { .collapsed, .dirty }
            } else {
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
        
        if change != nil {
            propagate_remove: for neighbour in change.neighbours {
                cell := neighbour.cell
                if .collapsed in cell.flags do continue
                if .edge in cell.flags do continue
                
                states_count := 0
                did_change := false
                
                spall_begin("recalc states")
                recalc_states: for &from, from_id in cell.states do if from.removed_at > current.step {
                    for to, to_id in change.states {
                        if to.removed_at > current.step {
                            support := c.supports[from_id * len(c.states) + to_id]
                            masked := support & neighbour.mask
                            if masked != {} {
                                states_count += 1
                                continue recalc_states
                            }
                        }
                    }
                    
                    from.removed_at = current.step
                    did_change = true
                }
                spall_end()
                
                if did_change {
                    append_change_if_not_already_scheduled(current, cell)
                    
                    if states_count == 0 {
                        the_cause: Collapse_Step
                        for n in cell.neighbours {
                            for state in n.cell.states {
                                if state.removed_at != Invalid_Collapse_Step && state.removed_at < current.step {
                                    the_cause = max(the_cause, state.removed_at)
                                }
                            }
                        }
                        
                        result.kind = .Rewind
                        result.rewind_to = the_cause
                        
                        break propagate_remove
                    }
                    
                    cell.flags += { .dirty }
                    if states_count == 1 {
                        cell.flags += { .collapsed }
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

calculate_entropy :: proc (c: ^Collapse, cell: ^Cell, step: Collapse_Step) {
    spall_proc()
    
    total_frequency: f32
    for state, id in cell.states do if state.removed_at > step {
        frequency := c.states[id].frequency
        
        total_frequency += frequency
    }
    
    entropy: f32
    for state, id in cell.states do if state.removed_at > step {
        frequency := c.states[id].frequency
        
        probability := frequency / total_frequency
        
        entropy -= probability * log2(probability)
    }
    
    cell.entropy = entropy
}

calculate_average_color :: proc (c: ^Collapse, cell: ^Cell, step: Collapse_Step) {
    spall_proc()
    
    color: v4
    count: f32
        for state, id in cell.states do if state.removed_at > step {
        state := c.states[id]
        color += state.middle * state.frequency
        count += state.frequency
    }
    
    color = safe_ratio_0(color, count)
    cell.average_color = color
}

delete_cell :: proc (cell: Cell) {
    delete(cell.points)
    delete(cell.neighbours)
    delete(cell.states)
}

////////////////////////////////////////////////

extract_states :: proc (c: ^Collapse, pixels: [] rl.Color, width, height: i32, wrap: [2] bool) {
    spall_proc()
    
    // @incomplete: Allow for rotations and mirroring here
    spall_begin("State Extraction")
    max_x := wrap.x ? width  : width  - N
    max_y := wrap.y ? height : height - N
    for by in 0..<max_y {
        for bx in 0..<max_x {
            begin_state(c)
            for dy in 0..<N {
                for dx in 0..<N {
                    x := (bx + dx) % width
                    y := (by + dy) % height
                    state_append_value(c, pixels[x + (height-1-y) * width])
                }
            }
            end_state(c)
        }
    }
    spall_end()
    
    spall_begin("Supports generation")
    make(&c.supports, square(len(c.states)))
    for a, a_index in c.states {
        assert(a.id == auto_cast a_index)
        for d in Direction {
            a_hashes := c.temp_subregion_hashes[a.id]
            a_hash := a_hashes[d]
            for b in c.states {
                b_hashes := c.temp_subregion_hashes[b.id]
                b_hash := b_hashes[opposite_direction(d)]
                
                if a_hash == b_hash {
                    support := &c.supports[a.id * auto_cast len(c.states) + b.id]
                    support^ += { d }
                }
            }
        }
    }
    
    clear(&c.temp_subregion_hashes)
    spall_end()
}

begin_state :: proc (c: ^Collapse) {
    assert(!c.is_defining_state)
    assert(len(c.temp_state_values) == 0)
    
    c.is_defining_state = true
}

state_append_value :: proc (c: ^Collapse, value: rl.Color) {
    assert(c.is_defining_state)
    append(&c.temp_state_values, value)
}

end_state   :: proc (c: ^Collapse) {
    assert(c.is_defining_state)
    assert(len(c.temp_state_values) != 0)
    c.is_defining_state = false
    
    state := State { id = Invalid_State }
    subregion_hashes: [Direction] u64
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
                    value := c.temp_state_values[dx + dy * N]
                    integer := transmute(u32) value
                    hash = (hash ~ cast(u64) integer) * 0x100000001b3
                }
            }
            
            subregion_hashes[direction] = hash
        }
    }
    
    search: for other in c.states {
        other_subregion_hashes := c.temp_subregion_hashes[other.id]
        for value, direction in other_subregion_hashes {
            if value != subregion_hashes[direction] {
                continue search
            }
        }
        
        state.id = other.id
        break search
    }
    
    if state.id == Invalid_State {
        state.id = auto_cast len(c.states)
        state.frequency = 1
        
        state.middle = rl_color_to_v4(c.temp_state_values[N/4+N/4*N])
        
        append(&c.states, state)
        append(&c.temp_subregion_hashes, subregion_hashes)
        assert(len(c.states) == len(c.temp_subregion_hashes))
    } else {
        c.states[state.id].frequency += 1
    }
    assert(state.id != Invalid_State)
    
    clear(&c.temp_state_values)
}