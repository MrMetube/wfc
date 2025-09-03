package main

import "core:time"

import rl "vendor:raylib"

Collapse :: struct {
    states:   [dynamic] State,
    values:   [dynamic] rl.Color,
    supports: [/* center - State_Id */] [/* neighbour - State_Id */] Support,
    
    steps: [dynamic] Step,
    
    // Extraction
    is_defining_state: bool,
    temp_state_values: [dynamic] Value_Id,
}

Step :: struct {
    step: Collapse_Step,
    update_state: Update_State,
    
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

Collapse_Step :: distinct i64

Cell :: struct {
    p:              v2, 
    points:         [] v2, // for rendering the voronoi cell
    all_neighbours: [] ^Cell,
    neighbours:     [dynamic] ^Cell,
    
    state: Cell_State,
    
    states: [] State_Entry,
    
    entropy: f32,
    average_color: rl.Color,
}

State_Entry :: struct {
    id: State_Id,
    removed_at: Collapse_Step,
    
    support_from_neighbours: [] f32,
}

Cell_State :: enum {
    Uninitialized,
    Collapsing,
    Collapsed,
}

Support :: struct {
    id:     State_Id,
    amount: [Direction] f32,
}

Value_Id :: distinct u8
State_Id :: distinct u32
State    :: struct {
    id: State_Id,
    
    middle_value: Value_Id,
    _values:      [] Value_Id,
    
    frequency: f32,
    
    // @note(viktor): used in extraction, direction means of which subregion the hash is
    hashes: [Direction] u64,
}

Search_Metric :: enum { States, Entropy }

////////////////////////////////////////////////

N: i32 = 3

cells: [dynamic] Cell

Update_State :: enum {
    Search,
    Pick,
    Collapse,
    Propagate,
}

Wave_Support :: struct {
    id:     State_Id,
    amount: i32,
}

////////////////////////////////////////////////

Invalid_State         :: max(State_Id)
Invalid_Value         :: max(Value_Id)
Invalid_Collapse_Step :: max(Collapse_Step)

////////////////////////////////////////////////

supports :: proc { supports_from, supports_from_to }
supports_from :: proc (c: ^Collapse, from: State_Id) -> ([] Support) {
    return c.supports[from][:]
}
supports_from_to :: proc (c: ^Collapse, from: State_Id, to: State_Id) -> (result: Support) {
    /*  these are the same as the supports relation is symmetric, for each from we could truncate to to only hold states above from and swap the arguments and the _direction array in Support_, to reduce memory usage at the cost of branch misses/ more cycles
        support := supports(c, from, id)
        support2 := supports(c, id, from)
    */
    result = c.supports[from][to]
    return result
}

get_closeness :: proc (sampling_direction: v2) -> (result: [Direction] f32) {
    sampling_direction := sampling_direction
    sampling_direction = normalize(sampling_direction)
    
    for &closeness, other in result {
        other_dir := vec_cast(f32, Deltas[other])
        cosine_closeness := dot(sampling_direction, other_dir)
        if view_mode_t < 0 {
            constant_closeness: f32 = 1
            closeness = linear_blend(constant_closeness, cosine_closeness, view_mode_t - (-1))
        } else {
            linear_closeness := 1 - acos(cosine_closeness)
            closeness = linear_blend(cosine_closeness, linear_closeness, view_mode_t)
        }
        closeness = max(closeness, 0)
    }
    
    return result
}

get_support_amount_ :: proc (support: Support, closeness: [Direction] f32) -> (result: f32) {
    for other in Direction {
        amount := support.amount[other]
        result += amount * closeness[other]
    }
    
    return result
}

get_support_amount :: proc (c: ^Collapse, from: State_Id, to: State_Id, closeness: [Direction] f32) -> (result: f32) {
    support := supports(c, from, to)
    result = get_support_amount_(support, closeness)
    return result
}

////////////////////////////////////////////////

collapse_reset :: proc (c: ^Collapse) {
    // println("%", view_variable(size_of(Collapse))); assert(false)
    // #assert(size_of(Collapse) <= 380, "members have changed")
        
    for state in c.states do delete(state._values)
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
    assert(c.is_defining_state)
    assert(len(c.temp_state_values) != 0)
    c.is_defining_state = false
    
    state := State { id = Invalid_State }
    {
        subsections := [Direction] Rectangle2i {
            .East  = { { 1, 0 }, {   N,   N } },
            .West  = { { 0, 0 }, { N-1,   N } },
            .North = { { 0, 1 }, {   N,   N } },
            .South = { { 0, 0 }, {   N, N-1 } },
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
            
            state.hashes[direction] = hash
        }
    }
    
    // @speed this linear search is the dominant part of this function. How can we speed it up?
    spall_begin("search")
    search: for other in c.states {
        for value, direction in other.hashes {
            if value != state.hashes[direction] {
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
        
        make(&state._values, len(c.temp_state_values))
        copy(state._values, c.temp_state_values[:])
        state.middle_value = state._values[N/4+N/4*N]
        
        append(&c.states, state)
    } else {
        c.states[state.id].frequency += 1
    }
    assert(state.id != Invalid_State)
    
    clear(&c.temp_state_values)
}

////////////////////////////////////////////////

calculate_entropy :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    // @speed this could be done iteratively if needed, but its fast enough for now
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
    
    switch cell.state {
      case .Uninitialized:
        cell.average_color = 0
        
      case .Collapsing:
        color: v4
        count: f32
        for state in cell.states {
            if state.removed_at <= peek(c.steps).step do continue
            
            state    := c.states[state.id]
            color_id := state.middle_value
            color += rl_color_to_v4(c.values[color_id]) * state.frequency
            count += state.frequency
        }
        
        color = safe_ratio_0(color, count)
        cell.average_color = cast(rl.Color) v4_to_rgba(color * {1,1,1,0.3})
        
      case .Collapsed:
        state_entry  := slow__get_collapsed_state(c, cell^)
        state        := c.states[state_entry.id]
        color_id     := state.middle_value
        cell.average_color = c.values[color_id]
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

calc_cell_states_support :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    for neighbour, neighbour_index in cell.neighbours {
        closeness := get_closeness(cell.p - neighbour.p)
        
        for &state in cell.states {
            if state.removed_at <= peek(c.steps).step do continue
            
            if neighbour.state == .Uninitialized {
                for from in c.states {
                    amount := get_support_amount(c, from.id, state.id, closeness)
                    state.support_from_neighbours[neighbour_index] += amount
                    // state.highest_support_from_neighbours += amount
                }
            } else {
                state.support_from_neighbours[neighbour_index] += get_support_for_state(c, neighbour, state.id, closeness)
                // state.highest_support_from_neighbours += get_support_for_state(c, neighbour, state.id, closeness)
            }
        }
    }
}

cell_next_state :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    
    switch cell.state {
      case .Uninitialized:
        cell.state = .Collapsing
        
        make(&cell.states, len(c.states))
        
        for &state, index in cell.states {
            state.id = cast(State_Id) index
            state.removed_at = Invalid_Collapse_Step
            make(&state.support_from_neighbours, len(cell.neighbours))
        }
        
        calc_cell_states_support(c, cell)
        calculate_average_color(c, cell)
        
      case .Collapsing:
        cell.state = .Collapsed
        
      case .Collapsed:
        cell.state = .Uninitialized
        for state in cell.states {
            delete(state.support_from_neighbours)
        }
        delete(cell.states)
        cell.states = nil
    }
}

Update_Result :: enum { Ok, Rewind, Done }
collapse_update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (result: Update_Result) {
    spall_proc()
    assert(c.states != nil)
    
    result = .Ok
    
    current := peek(c.steps)
    switch current.update_state {
      case .Search:
        spall_scope("Find next cell to be collapsed")
        
        lowest := +Infinity
        for &cell in cells {
            if render_wavefunction_as_average do calculate_average_color(c, &cell)
            if cell.state == .Collapsed do continue
            if search_metric == .Entropy do calculate_entropy(c, &cell)
            
            value: f32
            switch cell.state {
              case .Collapsed: unreachable()
                
              case .Uninitialized:
                switch search_metric {
                  case .States:  value = cast(f32) len(c.states)
                  case .Entropy: value = log2(cast(f32) len(c.states))
                }
                    
              case .Collapsing:
                switch search_metric {
                  case .States:  value = cast(f32) slow__get_states_count(c, &cell)
                  case .Entropy: value = cell.entropy
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
        
        if len(current.found) == 0 {
            result = .Done
        } else {
            current.update_state = .Pick
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
            
            if current.to_be_collapsed.state == .Uninitialized {
                // @todo(viktor): special case this to reduce unnecesary work
                cell_next_state(c, current.to_be_collapsed)
            }
            
            clear(&current.pickable_states)
            for &state in current.to_be_collapsed.states {
                if state.removed_at <= current.step do continue
                append(&current.pickable_states, &state)
            }
            
            current.update_state = .Collapse
        }
        
      case .Collapse:
        spall_scope("Collapse chosen cell")
        
        assert(current.to_be_collapsed != nil)
        
        if len(current.pickable_states) == 0 {
            result = .Rewind
        } else {
            cell := current.to_be_collapsed
            assert(cell.state == .Collapsing)
            
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
            for &state, index in current.pickable_states {
                target -= c.states[state.id].frequency
                
                when DoWeights do target -= weights[index]
                
                if pick == Invalid_State && target <= 0 {
                    pick = state.id
                } else {
                    state.removed_at = current.step
                }
            }
            
            if pick != Invalid_State {
                mark_as_changed(current, cell)
                cell_next_state(c, cell)
            } else {
                result = .Rewind
            }
        }
        
        current.update_state = .Propagate
        
      case .Propagate:
        spall_scope("Propagate changes")
        
        assert(len(current.changes) != 0)
        
        changed: ^Cell
        for changed == nil && current.changes_cursor < len(current.changes) {
            changed = current.changes[current.changes_cursor]
            current.changes_cursor += 1
        }
        
        if changed == nil && current.changes_cursor == len(current.changes) {
            result = .Rewind
        } else {
            assert(changed.state != .Uninitialized)
            
            propagate_remove: for neighbour in changed.neighbours {
                assert(neighbour != nil)
                if neighbour.state == .Collapsed do continue propagate_remove
                was_just_inited := false
                if neighbour.state == .Uninitialized {
                    was_just_inited = true
                    cell_next_state(c, neighbour)
                }
                assert(neighbour.state != .Uninitialized)
                
                changed_index: int = -1
                for n, n_index in neighbour.neighbours do if n == changed { changed_index = n_index; break }
                assert(changed_index != -1)
                
                closeness := get_closeness(neighbour.p - changed.p)
                did_change := false
                // @todo(viktor): dont recalculate the total amount everytime, do it at init and then update it according to the removed states in changed, i.e. the support of those states
                states_count := 0
                spall_begin("recalc states loop")
                for &to in neighbour.states {
                    if to.removed_at <= current.step do continue
                    
                    should_remove: bool
                    
                    should_remove = true
                    current_support: f32
                    for from in changed.states {
                        if from.removed_at <= current.step do continue
                        amount := get_support_amount(c, from.id, to.id, closeness)
                        current_support += amount
                    }
                    
                    to.support_from_neighbours[changed_index] = current_support
                    should_remove = current_support <= 0
                    
                    if should_remove {
                        did_change = true
                        to.removed_at = current.step
                    } else {
                        states_count += 1
                    }
                }
                spall_end()
                
                if did_change {
                    if states_count == 0 {
                        result = .Rewind
                        break propagate_remove
                    }
                    
                    if states_count == 1 {
                        cell_next_state(c, neighbour)
                    }
                    
                    mark_as_changed(current, neighbour)
                }
            }
        }
        
        if len(current.changes) == current.changes_cursor {
            append(&c.steps, Step { step = current.step + 1 })
        }
    }
    
    return result
}

slow__get_collapsed_state :: proc (c: ^Collapse, cell: Cell) -> (result: State_Entry) {
    assert(cell.state == .Collapsed)
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        
        return state
    }
    unreachable()
}

slow__get_states_count :: proc (c: ^Collapse, cell: ^Cell) -> (result: i32) {
    for state in cell.states {
        if state.removed_at <= peek(c.steps).step do continue
        
        result += 1
    }
    
    return result
}

get_support_for_state :: proc (c: ^Collapse, from: ^Cell, to: State_Id, closeness: [Direction] f32) -> (result: f32) {
    for from in from.states {
        if from.removed_at <= peek(c.steps).step do continue
        amount := get_support_amount(c, from.id, to, closeness)
        result += amount
    }
    return result
}

mark_as_changed :: proc (current: ^Step, cell: ^Cell) {
    spall_proc()
    
    // @note(viktor): deduplicate changed cells
    for &it in current.changes {
        if it == cell do it = nil
    }
    
    assert(cell.state != .Uninitialized)
    append(&current.changes, cell)
}

delete_step :: proc (step: Step) {
    delete(step.found)
    delete(step.pickable_states)
    delete(step.changes)
}

extract_states :: proc (c: ^Collapse, pixels: [] rl.Color, width, height: i32) {
    spall_proc()
    
    for &group in color_groups {
        delete(group.ids)
    }
    clear(&color_groups)
    viewing_group   = nil
    
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
                a_hash := a.hashes[d]
                for b in c.states {
                    b_hash := b.hashes[Opposite[d]]
                    
                    if a_hash == b_hash {
                        support := &c.supports[a.id][b.id]
                        support.id = b.id
                        support.amount[d] += 1
                    }
                }
            }
            print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
            
        }
        
        print("Extraction: Supports generation done: %       \n", view_time_duration(time.since(start), precision = 3))
    }
    
    print("Extraction: Done\n")
}