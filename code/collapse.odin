package main

import "core:time"

import rl "vendor:raylib"

// @todo(viktor): dont rely on the user type, just use ids
Value :: rl.Color

Collapse :: struct {
    states:   [dynamic] State,
    values:   [dynamic] Value,
    supports: [/* center - State_Id */] [/* neighbour - State_Id */] Support,
    
    to_be_collapsed: [dynamic] ^Cell,
    changes:         [dynamic] ^Cell,
    changes_cursor:  int,
    
    // Restart
    init_cell_index: int,
    
    // Extraction
    is_defining_state: b32,
    temp_state_values: [dynamic] Value_Id,
}

Cell :: struct {
    p:              v2, 
    points:         [dynamic] v2, // for rendering the voronoi cell
    all_neighbours: [dynamic] ^Cell,
    neighbours:     [dynamic] ^Cell,
    
    state: Cell_State,
    
    states: [dynamic] Cell_Foo,
    entropy: f32,
}

Cell_Foo :: struct {
    id:     State_Id,
    amount: f32,
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

Search :: struct {
    c: ^Collapse,
    
    metric: Search_Metric,
    lowest: f32,
    cells:  [dynamic] ^Cell,
}

Value_Id :: distinct u8
State_Id :: distinct u32
State    :: struct {
    // @todo(viktor): we dont really need all of these fields together at the same time. maybe make a #soa out of it?
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
    Search_Cells,
    Collapse_Cells,
    Propagate_Changes,
    
    Done,
}
update_state: Update_State

Wave_Support :: struct {
    id:     State_Id,
    amount: i32,
}

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
    #assert(size_of(Collapse) == 240, "members have changed")
    
    collapse_restart(c)
    
    delete(c.states)
    delete(c.temp_state_values)
    for a in c.supports do delete(a)
    delete(c.supports)
    
    c ^= {}
}

collapse_restart :: proc (c: ^Collapse) {
    clear(&c.to_be_collapsed)
    clear(&c.changes)
    c.changes_cursor = 0
    c.init_cell_index = 0
}

////////////////////////////////////////////////

Invalid_State :: max(State_Id)
Invalid_Value :: max(Value_Id)

begin_state :: proc (c: ^Collapse) {
    assert(!c.is_defining_state)
    assert(len(c.temp_state_values) == 0)
    
    c.is_defining_state = true
}

state_append_value :: proc (c: ^Collapse, value: Value) {
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

init_search :: proc (search: ^Search, c: ^Collapse, metric: Search_Metric, allocator := context.allocator) {
    search.lowest = +Infinity
    
    search.c      = c
    search.metric = metric
    make(&search.cells, allocator)
}

calculate_entropy :: proc (c: ^Collapse, cell: ^Cell) {
    // @speed this could be done iteratively if needed, but its fast enough for now
    total_frequency: f32
    cell.entropy = 0
    for state in cell.states {
        total_frequency += c.states[state.id].frequency
    }
    
    for state in cell.states {
        frequency := c.states[state.id].frequency
        probability := frequency / total_frequency
        
        cell.entropy -= probability * log2(probability)
    }
}

test_search_cell :: proc (search: ^Search, cell: ^Cell) {
    assert(cell.state != .Collapsed)
    
    value: f32
    switch cell.state {
      case .Collapsed: unreachable()
        
      case .Uninitialized:
        switch search.metric {
          case .States:
            value = cast(f32) len(search.c.states)
          case .Entropy: 
            value = log2(cast(f32) len(search.c.states))
        }
            
      case .Collapsing:
        switch search.metric {
          case .States:
            value = cell.entropy
          case .Entropy: 
            value = cast(f32) len(cell.states)
        }
    }
    
    if search.lowest > value {
        search.lowest = value
        clear(&search.cells)
    }
    
    if search.lowest == value {
        append(&search.cells, cell)
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

cell_next_state :: proc (c: ^Collapse, cell: ^Cell) {
    spall_proc()
    
    switch cell.state {
      case .Uninitialized:
        make(&cell.states, len(c.states))
        for &state, index in cell.states do state.id = cast(State_Id) index
        cell.state = .Collapsing
        
      case .Collapsing:
        cell.state = .Collapsed
        
      case .Collapsed:
        delete(cell.states)
        cell.states = nil
        cell.state = .Uninitialized
    }
}

collapse_update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (ok: bool) {
    spall_proc()
    assert(c.states != nil)
    
    ok = true
    
    switch update_state {
      case .Search_Cells:
        assert(len(c.to_be_collapsed) == 0)
        spall_scope("Find next cell to be collapsed")
        
        search: Search
        init_search(&search, c, search_metric, context.temp_allocator)
        
        only_check_changes := len(c.changes) != 0
        if only_check_changes {
            for cell in c.changes {
                if cell == nil || cell.state == .Collapsed do continue
                assert(cell.state != .Collapsed)
                if search.metric == .Entropy do calculate_entropy(c, cell)
                test_search_cell(&search, cell)
            }
            
            clear(&c.changes)
        } else {
            for &cell in cells {
                if cell.state == .Collapsed do continue
                if search.metric == .Entropy do calculate_entropy(c, &cell)
                test_search_cell(&search, &cell)
            }
        }
        
        found := search.cells[:]
        if len(found) > 0 {
            if len(found[0].states) == 1 {
                spall_scope("Set All chosen cells to be collapse")
                append(&c.to_be_collapsed, ..found)
            } else {
                    append(&c.to_be_collapsed, random_value(entropy, found))
            }
            
            update_state = .Collapse_Cells
        } else {
            if !only_check_changes {
                update_state = .Done
            }
        }
        
      case .Collapse_Cells:
        spall_scope("Collapse chosen cell")
        
        for cell in c.to_be_collapsed {
            assert(cell.state != .Collapsed)
            
            if cell.state == .Uninitialized {
                // @todo(viktor): special case this to reduce unnecesary work
                cell_next_state(c, cell)
            }
            
            
            pick := Invalid_State
            if len(cell.states) == 1 {
                pick = cell.states[0].id
            } else {
                total: f32
                for state in cell.states {
                    total += c.states[state.id].frequency
                }
                
                weights := make([] f32, len(cell.states), context.temp_allocator)
                
                for neighbour in cell.neighbours {
                    closeness := get_closeness(neighbour.p - cell.p)
                    // @important @speed cache this
                    for from, from_index in cell.states {
                        for to in neighbour.states {
                            amount := get_support_amount(c, from.id, to.id, closeness)
                            weights[from_index] += amount
                        }
                    }
                }
                
                for weight in weights do total += weight
                
                target := random_unilateral(entropy, f32) * total
                picking: for state, index in cell.states {
                    target -= c.states[state.id].frequency
                    target -= weights[index]
                    if target <= 0 {
                        pick = state.id
                        break picking
                    }
                }
                assert(pick != Invalid_State)
            }
            
            assert(pick != Invalid_State)
            {
                // See @note below
                remove_state(c, cell, 0)
                
                cell_next_state(c, cell)
                clear(&cell.states)
                append(&cell.states, Cell_Foo { pick, 100 })
            }
        }
        
        clear(&c.to_be_collapsed)
        update_state = .Propagate_Changes
        
      case .Propagate_Changes:
        spall_scope("Propagate changes")
        
        if len(c.changes) == c.changes_cursor {
            update_state = .Search_Cells
            c.changes_cursor = 0
        } else {
            changed := c.changes[c.changes_cursor]
            c.changes_cursor += 1
            for changed == nil {
                changed = c.changes[c.changes_cursor]
                c.changes_cursor += 1
            }
            
            propagate_remove: for neighbour in changed.neighbours {
                assert(neighbour != nil)
                if neighbour.state == .Collapsed do continue propagate_remove
                if neighbour.state == .Uninitialized {
                    cell_next_state(c, neighbour)
                }
                assert(neighbour.state != .Uninitialized)
                
                direction := neighbour.p - changed.p
                closeness := get_closeness(direction)
                did_change := false
                spall_scope("recalc states loop")
                #reverse for to, state_index in neighbour.states {
                    should_remove: bool
                    
                    should_remove = true
                    total_amount: f32
                    f: for from in changed.states {
                        amount := get_support_amount(c, from.id, to.id, closeness)
                        total_amount += amount
                    }
                    should_remove = total_amount <= 0
                    
                    if should_remove {
                        did_change = true
                        
                        unordered_remove(&neighbour.states, state_index)
                        if len(neighbour.states) == 0 {
                            ok = false
                            break propagate_remove
                        }
                    }
                }
                
                if did_change {
                    // @note(viktor): as we dont currently track the removed states anymore this is simpler
                    remove_state(c, neighbour, 0)
                }
            }
        }
        
      case .Done: // nothing
    }
    
    return ok
}

remove_state :: proc (c: ^Collapse, cell: ^Cell, removed_state: State_Id) {
    spall_proc()
    
    for &it in c.changes {
        if it == cell {
            it = nil
        }
    }
    
    append(&c.changes, cell)
}

extract_states :: proc (c: ^Collapse, pixels: [] Value, width, height: i32) {
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