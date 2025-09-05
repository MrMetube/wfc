package main

import "core:time"
import rl "vendor:raylib"


// @todo(viktor): make these members of collapse
N: i32 = 3
Search_Metric :: enum { States, Entropy }

Collapse :: struct {
    states:   [dynamic] State,
    values:   [dynamic] rl.Color,
    supports: [/* center - State_Id */] [/* neighbour - State_Id */] [Direction] f32,
    
    steps: [dynamic] Step,
    
    // Extraction
    is_defining_state: bool,
    temp_state_values: [dynamic] Value_Id,
}

Value_Id :: distinct u8
State_Id :: distinct u32
Collapse_Step :: distinct i32

Invalid_State         :: max(State_Id)
Invalid_Value         :: max(Value_Id)
Invalid_Collapse_Step :: max(Collapse_Step)

State :: struct {
    id: State_Id,
    
    middle: Value_Id,
    
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
Cell :: struct {
    p:          v2, 
    points:     [] v2, // for rendering the voronoi cell
    neighbours: [] ^Cell,
    
    collapsed: bool,
    
    states: [] State_Entry,
    
    states_removed_this_step: [dynamic] State_Id,
    
    entropy: f32,
    average_color: rl.Color,
}

State_Entry :: struct {
    id: State_Id,
    removed_at: Collapse_Step,
    
    support_from_neighbours: [] f32,
}

////////////////////////////////////////////////

collapse_reset :: proc (c: ^Collapse) {
    // println("%", view_variable(size_of(Collapse))); assert(false)
    // #assert(size_of(Collapse) <= 380, "members have changed")
        
    clear(&c.states)
    for step in c.steps do delete_step(step)
    clear(&c.steps)
    
    clear(&c.values)
    clear(&c.temp_state_values)
    
    for a in c.supports do delete(a)
    delete(c.supports)
    c.supports = nil
    
    c.is_defining_state = false
}

////////////////////////////////////////////////

get_closeness :: proc (sampling_direction: v2) -> (result: [Direction] f32) {
    sampling_direction := sampling_direction
    sampling_direction = normalize(sampling_direction)
    
    for &closeness, other in result {
        other_dir := normalize(vec_cast(f32, Deltas[other]))
        // @todo(viktor): now that we have 8 directions the cosine is too generous
        cosine_closeness := dot(sampling_direction, other_dir)
        linear_closeness := 1 - acos(cosine_closeness)
        closeness = linear_blend(cosine_closeness, linear_closeness, view_mode_t)
        closeness = max(closeness, 0)
    }
    
    return result
}

get_support_amount :: proc (c: ^Collapse, from: State_Id, to: State_Id, closeness: [Direction] f32) -> (result: f32) {
    support := c.supports[from][to]
    for other in Direction {
        result += support[other] * closeness[other]
    }
    return result
}

get_support_for_state :: proc (c: ^Collapse, from: State_Id, to: ^Cell, closeness: [Direction] f32, max: Collapse_Step) -> (result: f32) {
    for to in to.states {
        if to.removed_at <= max do continue
        amount := get_support_amount(c, from, to.id, closeness)
        result += amount
    }
    return result
}

calc_cell_states_support :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    // @todo(viktor): @speed can we do this update only for the difference between this time and last time?
    
    current := peek(c.steps)
    for neighbour, neighbour_index in cell.neighbours {
        closeness := get_closeness(neighbour.p - cell.p)
        
        for &state in cell.states {
            if state.removed_at <= current.step do continue
            
            support := get_support_for_state(c, state.id, neighbour, closeness, current.step)
            state.support_from_neighbours[neighbour_index] = support
        }
    }
}

////////////////////////////////////////////////

Update_Result :: enum { Ok, Rewind, Done }
step_update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (result: Update_Result) {
    spall_proc()
    assert(c.states != nil)
    
    result = .Ok
    
    current := peek(c.steps)
    switch current.state {
      case .Search:
        spall_scope("Find next cell to be collapsed")
        
        lowest := +Infinity
        for &cell in cells {
            calculate_average_color(c, &cell)
            if cell.collapsed do continue
            if search_metric == .Entropy do calculate_entropy(c, &cell)
            
            value: f32
            
            switch search_metric {
                case .States:  value = cast(f32) slow__get_states_count(c, &cell)
                case .Entropy: value = cell.entropy
            }
            
            if lowest > value {
                lowest = value
                clear(&current.found)
            }
            
            if lowest == value {
                append(&current.found, &cell)
            }
        }
        
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
            
            assert(!current.to_be_collapsed.collapsed)
            
            clear(&current.pickable_states)
            for &state in current.to_be_collapsed.states {
                if state.removed_at <= current.step do continue
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
            assert(!cell.collapsed)
            
            pick := Invalid_State
            total: f32
            for state in current.pickable_states {
                assert(state.removed_at > current.step)
                total += c.states[state.id].frequency
            }
            
            DoWeights :: true
            when DoWeights {
                // @todo(viktor): Figure out if this is even needed or has any effect on the result
                // @todo(viktor): precompute this weighting per neighbour based on direction
                weights := make([] f32, len(cell.states), context.temp_allocator)
                
                for neighbour in cell.neighbours {
                    closeness := get_closeness(neighbour.p - cell.p)
                    // @important @speed cache this
                    for from, from_index in current.pickable_states {
                        for to in neighbour.states {
                            if to.removed_at <= current.step do continue
                            
                            amount := get_support_amount(c, from.id, to.id, closeness)
                            weights[from_index] += amount
                        }
                    }
                }
                
                for weight in weights do total += weight
            }
            
            target := random_unilateral(entropy, f32) * total
            copy := target
            append_change_if_not_already_scheduled(current, cell)
            
            pick_index := -1
            for &state, index in current.pickable_states {
                target -= c.states[state.id].frequency
                
                when DoWeights do target -= weights[index]
                
                if target <= 0 {
                    pick = state.id
                    pick_index = index
                    break
                }
            }
            
            for &state in cell.states {
                if state.removed_at <= current.step do continue
                if state.id == pick do continue
                
                state.removed_at = current.step
                append(&cell.states_removed_this_step, state.id)
            }
            
            if pick != Invalid_State {
                unordered_remove(&current.pickable_states, pick_index)
                cell.collapsed = true
            } else {
                result = .Rewind
            }
        }
        
        current.state = .Propagate
        
      case .Propagate:
        spall_scope("Propagate changes")
        
        assert(len(current.changes) != 0)
        
        change: ^Cell
        for change == nil  && current.changes_cursor < len(current.changes) {
            change = current.changes[current.changes_cursor]
            current.changes_cursor += 1
        }
        
        if change == nil && current.changes_cursor == len(current.changes) {
            result = .Rewind
        } else {
            cell := change
            
            propagate_remove: for neighbour in cell.neighbours {
                assert(neighbour != nil)
                if neighbour.collapsed do continue propagate_remove
                appended := append_change_if_not_already_scheduled(current, neighbour)
                
                cell_index: int = -1
                for n, n_index in neighbour.neighbours do if n == cell { cell_index = n_index; break }
                assert(cell_index != -1)
                
                closeness := get_closeness(cell.p - neighbour.p)
                
                states_count := 0
                spall_begin("recalc states loop")
                // @todo(viktor): @speed dont recalculate the total amount everytime, do it at init and then update it according to the removed states in changed, i.e. the support of those states
                for &to in neighbour.states {
                    if to.removed_at <= current.step do continue
                    
                    current_support := get_support_for_state(c, to.id, cell, closeness, current.step)
                    // @todo(viktor): Why is this still so unreliable!
                    removed_support: f32
                    for from in cell.states_removed_this_step {
                        amount := get_support_amount(c, to.id, from, closeness)
                        removed_support += amount
                    }
                    
                    previous_support := to.support_from_neighbours[cell_index]
                    now_support := max(0, previous_support - removed_support)
                    // assert(absolute_difference(now_support, current_support) < 0.001)
                    to.support_from_neighbours[cell_index] = current_support
                    
                    if to.support_from_neighbours[cell_index] <= 0 {
                        to.removed_at = current.step
                        append(&neighbour.states_removed_this_step, to.id)
                    } else {
                        states_count += 1
                    }
                }
                spall_end()
                
                if len(neighbour.states_removed_this_step) != 0 {
                    if states_count == 0 {
                        result = .Rewind
                        break propagate_remove
                    }
                    
                    if states_count == 1 {
                        neighbour.collapsed = true
                    }
                } else {
                    if appended {
                        // @note(viktor): we optimistically appended it and it didn't actually change
                        pop(&current.changes)
                    }
                }
            }
            
            clear(&cell.states_removed_this_step)
        }
        
        if current.changes_cursor == len(current.changes) {
            // @todo(viktor): Huh?
            for &cell in cells {
                if len(cell.states_removed_this_step) != 0 {
                    append_change_if_not_already_scheduled(current, &cell)
                }
            }
        }
        
        if current.changes_cursor == len(current.changes) {
            if result != .Rewind {
                append(&c.steps, Step { step = current.step + 1 })
            }
        }
    }
    
    return result
}

append_change_if_not_already_scheduled :: proc (current: ^Step, cell: ^Cell) -> (result: bool) {
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
        result = true
    }
    
    return result
}

delete_step :: proc (step: Step) {
    delete(step.found)
    delete(step.pickable_states)
    delete(step.changes)
}

////////////////////////////////////////////////

calculate_entropy :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    assert(!cell.collapsed)
    
    // @todo(viktor): @speed this could be done iteratively if needed, but its fast enough for now
    total_frequency: f32
    cell.entropy = 0
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        total_frequency += c.states[state.id].frequency
    }
    
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        frequency := c.states[state.id].frequency
        probability := frequency / total_frequency
        
        cell.entropy -= probability * log2(probability)
    }
}

calculate_average_color :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    
    color: v4
    count: f32
    for state in cell.states {
        if state.removed_at <= viewing_step do continue
        
        state    := c.states[state.id]
        color_id := state.middle
        color += rl_color_to_v4(c.values[color_id]) * state.frequency
        count += state.frequency
    }
    
    color = safe_ratio_0(color, count)
    cell.average_color = cast(rl.Color) v4_to_rgba(color)
}

slow__get_collapsed_state :: proc (c: ^Collapse, cell: Cell) -> (result: State_Entry) {
    assert(cell.collapsed)
    
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        
        return state
    }
    unreachable()
}

slow__get_states_count :: proc (c: ^Collapse, cell: ^Cell) -> (result: i32) {
    spall_proc()
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        
        result += 1
    }
    
    return result
}

delete_cell :: proc (cell: Cell) {
    delete(cell.points)
    delete(cell.neighbours)
    delete(cell.states_removed_this_step)
    for state in cell.states {
        delete(state.support_from_neighbours)
    }
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
    
    id := Invalid_Value
    for it, index in c.values {
        if it == value {
            id = cast(Value_Id) index
            break
        }
    }
    
    if id == Invalid_Value {
        id = cast(Value_Id) len(c.values)
        append(&c.values, value)
    }
    assert(id != Invalid_Value)
    
    append(&c.temp_state_values, id)
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
                    hash = (hash ~ u64(value)) * 0x100000001b3
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
        
        state.middle = c.temp_state_values[N/4+N/4*N]
        
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
    
    make(&c.supports, len(c.states))
    for &it in c.supports do make(&it, len(c.states))
    
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
                        support := &c.supports[a.id][b.id]
                        support[d] += 1
                    }
                }
            }
            print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
            
        }
        
        print("Extraction: Supports generation done: %       \n", view_time_duration(time.since(start), precision = 3))
    }
    
    print("Extraction: Done\n")
}