package main

import "core:time"
import "core:simd"
import rl "vendor:raylib"


// @todo(viktor): make these members of collapse
N: i32 = 3

Collapse :: struct {
    states:   [dynamic] State,
    supports: [/* State_Id * len(states) + State_Id */] Direction_Vector,
    
    steps: [dynamic] Step,
    search_metric: Search_Metric,
    
    // Extraction
    is_defining_state: bool,
    temp_state_values: [dynamic] rl.Color,
}

State_Id :: distinct u32
Collapse_Step :: distinct i32

Invalid_State         :: max(State_Id)
Invalid_Collapse_Step :: max(Collapse_Step)

Search_Metric :: enum { States, Entropy }

State :: struct {
    id: State_Id,
    
    middle: v4,
    
    frequency: f32,
    
    // @note(viktor): used in extraction when checking overlaps.
    subregion_hashes: [Direction] u64,
}

////////////////////////////////////////////////

Step :: struct {
    step: Collapse_Step,
    state: Step_State,
    
    // Search
    found: [dynamic] ^Cell,
    // Pick
    to_be_collapsed: ^Cell,
    // Collapse
    pickable_states: [dynamic] ^State_Entry,
    // Propagate
    changes:         [dynamic] ^Cell,
    changes_cursor:  int,
}

Step_State :: enum {
    Search,
    Pick,
    Collapse,
    Propagate,
}

////////////////////////////////////////////////

cells: [dynamic] Cell
Neighbour :: struct {
    cell:      ^Cell,
    closeness: Direction_Vector,
}
Cell :: struct {
    p:          v2, 
    states:     [] State_Entry,
    neighbours: [] Neighbour,
    
    flags: bit_set[enum { collapsed, dirty }; u8],
    entropy: f32,
    
    // Visual only
    points:     [] v2, // for rendering the voronoi cell
    average_color: v4,
}

State_Entry :: struct {
    id: State_Id,
    removed_at: Collapse_Step,
}

Direction_Vector :: lane_f32

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

get_closeness :: proc (sampling_direction: v2) -> (result: Direction_Vector) {
    spall_proc()
    @(static) other_dir: lane_v2
    @(static) initialized: bool
    if !initialized {
        initialized = true
        for other in Direction {
            normal := normalized_direction(other)
            (cast(^[Direction]f32) &other_dir.x)[other] = normal.x
            (cast(^[Direction]f32) &other_dir.y)[other] = normal.y
        }
    }
    
    normalized_sampling_direction := normalize(sampling_direction)
    sampling_direction := lane_v2 { normalized_sampling_direction.x, normalized_sampling_direction.y }
    
    cosine_closeness := dot(sampling_direction, other_dir)
    linear_closeness := 1 - acos(cosine_closeness)
    
    closeness := linear_blend(cosine_closeness, linear_closeness, t_directional_strictness)
    closeness = vec_max(closeness, 0)
    
    result = normalize(closeness)
    
    return result
}

get_support_amount :: proc (c: ^Collapse, from: State_Id, to: State_Id, closeness: Direction_Vector) -> (result: f32) {
    support := c.supports[from * auto_cast len(c.states) + to]
    
    result = simd.reduce_add_pairs(support * closeness)
        
    return result
}

////////////////////////////////////////////////

Update_Result :: enum { Ok, Rewind, Done }
step_update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (result: Update_Result, rewind_to: Collapse_Step) {
    spall_proc()
    assert(c.states != nil)
    
    // @todo(viktor): this return setup is a bit stupid
    result = .Ok
    rewind_to = Invalid_Collapse_Step
    
    current := peek(c.steps)
    
    switch current.state {
      case .Search:
        spall_scope("Find next cell to be collapsed")
        
        lowest := +Infinity
        spall_begin("Dirtyness")
        for &cell in cells do if .dirty in cell.flags {
            cell.flags -= { .dirty }
            
            calculate_average_color(c, &cell, current.step)
            if c.search_metric == .Entropy do calculate_entropy(c, &cell, current.step)
        }
        spall_end()
        
        spall_begin("Search metric")
        for &cell in cells do if .collapsed not_in cell.flags {
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
            result = .Done
        } else {
            current.state = .Pick
        }
        
      case .Pick:
        spall_scope("Pick a cell from the found")
        
        assert(current.to_be_collapsed == nil)
        
        if len(current.found) == 0 {
            result = .Rewind
        } else {
            index := random_index(entropy, current.found)
            current.to_be_collapsed = current.found[index]
            unordered_remove(&current.found, index)
            
            assert(.collapsed not_in current.to_be_collapsed.flags)
            
            clear(&current.pickable_states)
            for &state in current.to_be_collapsed.states do if state.removed_at > current.step {
                append(&current.pickable_states, &state)
            }
            
            current.state = .Collapse
        }
        
      case .Collapse:
        spall_scope("Collapse chosen cell")
        
        assert(current.to_be_collapsed != nil)
        
        if len(current.pickable_states) == 0 {
            result = .Rewind
        } else {
            cell := current.to_be_collapsed
            assert(.collapsed not_in cell.flags)
            
            total: f32
            for state in current.pickable_states {
                assert(state.removed_at > current.step)
                total += c.states[state.id].frequency
            }
            
            target := random_between(entropy, f32, 0, total)
            append_change_if_not_already_scheduled(current, cell)
            
            pick := Invalid_State
            pickable_index := -1
            for &state, index in current.pickable_states {
                target -= c.states[state.id].frequency
                
                if target <= 0 {
                    pick = state.id
                    pickable_index = index
                    break
                }
            }
            
            if pick != Invalid_State {
                for &state in cell.states do if state.removed_at > current.step {
                    if state.id != pick {
                        state.removed_at = current.step
                    }
                }
                
                unordered_remove(&current.pickable_states, pickable_index)
                cell.flags += { .collapsed, .dirty }
            } else {
                result = .Rewind
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
        
        if change == nil && current.changes_cursor == len(current.changes) {
            result = .Rewind
            clear(&current.changes)
            current.changes_cursor = 0
        } else {
            propagate_remove: for neighbour in change.neighbours do if .collapsed not_in neighbour.cell.flags {
                cell      := neighbour.cell
                closeness := neighbour.closeness
                
                states_count := 0
                did_change := false
                spall_begin("recalc states")
                recalc_states: for &from in cell.states do if from.removed_at > current.step {
                    for to in change.states do if to.removed_at > current.step {
                        support := c.supports[from.id * auto_cast len(c.states) + to.id]
                        amount := simd.reduce_add_pairs(support * closeness)
                        if amount != 0 {
                            states_count += 1
                            continue recalc_states
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
                        result = .Rewind
                        rewind_to = the_cause
                        
                        break propagate_remove
                    }
                    
                    cell.flags += { .dirty }
                    if states_count == 1 {
                        cell.flags += { .collapsed }
                    }
                }
            }
        }
        
        if current.changes_cursor == len(current.changes) {
            if result != .Rewind {
                // print("Next Step\n")
                append(&c.steps, Step { step = current.step + 1 })
            }
        }
    }
    
    return result, rewind_to
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
    delete(step.pickable_states)
    delete(step.changes)
}

////////////////////////////////////////////////

calculate_entropy :: proc (c: ^Collapse, cell: ^Cell, step: Collapse_Step) {
    spall_proc()
    
    total_frequency: f32
    for state in cell.states do if state.removed_at > step {
        frequency := c.states[state.id].frequency
        
        total_frequency += frequency
    }
    
    entropy: f32
    for state in cell.states do if state.removed_at > step {
        frequency := c.states[state.id].frequency
        
        probability := frequency / total_frequency
        
        entropy -= probability * log2(probability)
    }
    
    cell.entropy = entropy
}

calculate_average_color :: proc (c: ^Collapse, cell: ^Cell, step: Collapse_Step) {
    spall_proc()
    
    color: v4
    count: f32
    for state in cell.states do if state.removed_at > step {
        state := c.states[state.id]
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
    spall_proc()
    
    assert(c.is_defining_state)
    assert(len(c.temp_state_values) != 0)
    c.is_defining_state = false
    
    state := State { id = Invalid_State }
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
            
            state.subregion_hashes[direction] = hash
        }
    }
    
    // @speed this linear search is the dominant part of this function
    spall_begin("search")
    search: for other in c.states {
        for value, direction in other.subregion_hashes {
            if value != state.subregion_hashes[direction] {
                continue search
            }
        }
        
        state.id = other.id
        break search
    }
    spall_end()
    
    if state.id == Invalid_State {
        state.id = auto_cast len(c.states)
        state.frequency = 1
        
        state.middle = rl_color_to_v4(c.temp_state_values[N/4+N/4*N])
        
        append(&c.states, state)
    } else {
        c.states[state.id].frequency += 1
    }
    assert(state.id != Invalid_State)
    
    clear(&c.temp_state_values)
}

////////////////////////////////////////////////

extract_states :: proc (c: ^Collapse, pixels: [] rl.Color, width, height: i32) {
    spall_proc()
    
    for &group in color_groups do delete(group.ids)
    clear(&color_groups)
    
    viewing_group = nil
    
    // @incomplete: Allow for rotations and mirroring here
    {
        start := time.now()
        spall_scope("State Extraction")
        for by in 0..<height {
            for bx in 0..<width {
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
            
            print("Extraction: State extraction % %%\r", view_percentage(by, height))
        }
        print("Extraction: State extraction done: %        \n", view_time_duration(time.since(start), precision = 3))
    }
    
    make(&c.supports, square(len(c.states)))
    
    {
        start := time.now()
        spall_scope("Extraction: Supports generation")
        
        for a, a_index in c.states {
            assert(a.id == auto_cast a_index)
            for d in Direction {
                a_hash := a.subregion_hashes[d]
                for b in c.states {
                    b_hash := b.subregion_hashes[opposite_direction(d)]
                    
                    if a_hash == b_hash {
                        support := cast(^[Direction]f32) &c.supports[a.id * auto_cast len(c.states) + b.id]
                        support[d] = 1
                    }
                }
            }
            print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
            
        }
        
        print("Extraction: Supports generation done: %       \n", view_time_duration(time.since(start), precision = 3))
    }
    
    print("Extraction: Done\n")
}