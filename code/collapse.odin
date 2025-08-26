package main

import "base:builtin"

import "core:time"

import rl "vendor:raylib"

// @todo(viktor): dont rely on the user type, just use ids
Value :: rl.Color

Collapse :: struct {
    states:   [dynamic] State,
    values:   [dynamic] Value,
    supports: [/* center - State_Id */] [/* neighbour - State_Id */] Support,
    
    to_be_collapsed: [dynamic] ^Cell,
    // @todo(viktor): its nice that its constant time lookup but the arbitrary order when iterating is worse
    changes: map[v2] Change,
    
    // Extraction
    is_defining_state:  b32,
    temp_state_values:  [dynamic] Value_Id,
}

Change :: struct {
    cell: ^Cell,
    removed_supports: [/* State_Id */] Support,
}

Support :: struct {
    id:     State_Id,
    amount: [Direction] f32,
}

Search :: struct {
    c: ^Collapse,
    
    lowest: f32,
    metric: Search_Metric,
    cells:  [dynamic] ^Cell,
}

Value_Id :: distinct u8
State_Id :: distinct u32
State    :: struct {
    id: State_Id,
    // @todo(viktor): values could be extracted into a parallel array and later on move it out to make the collapse more agnostic to the data
    values: [] Value_Id,
    frequency: i32,
    // @note(viktor): used in extraction, direction means of which subregion the hash is
    hashes: [Direction] u64,
}

Search_Metric :: enum { States, Entropy }
Search_Result :: enum { Continue, Done, Found_Invalid, }

Entropy :: struct {
    states_count_when_computed: u32,
    entropy: f32,
}

////////////////////////////////////////////////

supports :: proc { supports_from, supports_from_to }
supports_from :: proc (c: ^Collapse, from: State_Id) -> ([] Support) {
    return c.supports[from][:]
}
// @todo(viktor): this cant fail for now so maybe cleanup calling code sites
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
        other_dir := normalize(vec_cast(f32, Deltas[other]))
        switch view_mode {
          case .Nearest:     closeness = dot(sampling_direction, other_dir)
          case .Cos:         closeness = dot(sampling_direction, other_dir)
          case .AcosCos:     closeness = 1 - acos(dot(sampling_direction, other_dir))
          case .AcosAcosCos: closeness = acos(acos(dot(sampling_direction, other_dir)))
        }
        closeness = clamp(closeness, 0, 1)
    }
    
    if view_mode == .Nearest {
        nearest: Direction
        nearest_value := NegativeInfinity
        for value, direction in result {
            if nearest_value < value {
                nearest_value = value
                nearest = direction
            }
        }
        
        for &value, direction in result {
            value = direction != nearest ? 0 : 1
        }
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

mark_to_be_collapsed :: proc (c: ^Collapse, cells: ..^Cell) {
    append(&c.to_be_collapsed, ..cells)
}

////////////////////////////////////////////////

reset_collapse :: proc (c: ^Collapse) {
    // @todo(viktor): there should be an easier way
    // println("%", view_variable(size_of(Collapse))); assert(false)
    #assert(size_of(Collapse) <= 216, "members have changed")
    
    restart_collapse(c)
    
    delete(c.states)
    delete(c.temp_state_values)
    for a in c.supports do delete(a)
    delete(c.supports)
    
    c ^= {}
}

restart_collapse :: proc (c: ^Collapse) {
    clear(&c.to_be_collapsed)
 
    for _, change in c.changes {
        delete(change.removed_supports)
    }
    
    clear(&c.changes)
}

////////////////////////////////////////////////

Invalid_State :: max(State_Id)
Invalid_Value :: max(Value_Id)

begin_state :: proc (c: ^Collapse) {
    assert(!c.is_defining_state)
    assert(len(c.temp_state_values) == 0)
    
    c.is_defining_state = true
}

append_state_value :: proc (c: ^Collapse, value: Value) {
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
        // @todo(viktor): do the hashing iteratively instead of copy the values and then doing it. N is known at this point do we know.
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
        make(&state.values, len(c.temp_state_values))
        copy(state.values, c.temp_state_values[:])
        
        append(&c.states, state)
    } else {
        c.states[state.id].frequency += 1
    }
    assert(state.id != Invalid_State)
    
    clear(&c.temp_state_values)
}


////////////////////////////////////////////////

init_search :: proc (search: ^Search, c: ^Collapse, metric: Search_Metric, allocator := context.allocator) {
    search.lowest = PositiveInfinity
    
    search.c      = c
    search.metric = metric
    make(&search.cells, allocator)
}

// @todo(viktor): what information do we acutally need, is cell/wave function the minimal set?
test_search_cell :: proc (search: ^Search, cell: ^Cell) -> (result: Search_Result) {
    result = .Continue
    
    if len(cell.states) == 0 {
        result = .Found_Invalid
    } else {
        value: f32
        switch search.metric {
          case .States:
            value = cast(f32) len(cell.states)
            
          case .Entropy: 
            entry := &cell.entry
            if entry.states_count_when_computed != auto_cast len(cell.states) {
                entry.states_count_when_computed = auto_cast len(cell.states)
                
                // @speed this could be done iteratively if needed, but its fast enough for now
                total_frequency: f32
                entry.entropy = 0
                for id in cell.states {
                    total_frequency += cast(f32) search.c.states[id].frequency
                }
                
                for id in cell.states {
                    frequency := cast(f32) search.c.states[id].frequency
                    probability := frequency / total_frequency
                    // Shannon entropy is the negative sum of P * log2(P)
                    entry.entropy -= probability * log2(probability)
                }
            }
            
            value = entry.entropy
        }
        
        if search.lowest > value {
            search.lowest = value
            clear(&search.cells)
        }
        
        if search.lowest == value {
            append(&search.cells, cell)
        }
    }
    
    return result
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

N: i32 = 3

cells: [dynamic] Cell

Cell :: struct {
    p: v2, 
    points: [dynamic] v2,
    
    collapsed:       bool,
    collapsed_state: State_Id,
    states:          [dynamic] State_Id,
    neighbours:      [dynamic] Neighbour,
    
    // @todo(viktor): find a better place for this
    entry: Entropy,
}

Neighbour :: struct {
    cell:         ^Cell,
    to_neighbour: v2,
    support:      [/* State_Id */] f32,
}

Update_State :: enum {
    Initialize_States,
    Initialize_Supports,
    
    Search_Cells,
    Collapse_Cells,
    Propagate_Changes,
}
update_state: Update_State

init_cell_index: int

Wave_Support :: struct {
    id:     State_Id,
    amount: i32,
}

Update_Result :: enum {
    CollapseUninialized,
    Continue,
    FoundContradiction,
    AllCollapsed,
}

update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (result: Update_Result) {
    spall_proc()
    if c.states == nil do return .CollapseUninialized
    
    result = .Continue
    
    switch update_state {
      case .Initialize_States:
        assert(len(c.changes) == 0)
        assert(len(c.to_be_collapsed) == 0)
        
        spall_scope("Restart: initialize states")
        for &cell, cell_index in cells {
            if !cell.collapsed {
                delete(cell.states)
            } else {
                cell.collapsed = false
            }
            
            make(&cell.states, len(c.states))
            for &id, index in cell.states do id = cast(State_Id) index
            
            print("Restart: initialize states % %% \r", view_percentage(cell_index, len(cells)))
        }
        print("Restart: initialize states done           \n")
        update_state = .Initialize_Supports
        
      case .Initialize_Supports:
        spall_scope("Restart: initialize support")
        if init_cell_index < len(cells) {
            cell := &cells[init_cell_index]
            for &neighbour in cell.neighbours {
                delete(neighbour.support)
                make(&neighbour.support, len(c.states))
            }
            
            for &neighbour in cell.neighbours {
                closeness := get_closeness(neighbour.to_neighbour)
                for from in cell.states {
                    for to in neighbour.cell.states {
                        neighbour.support[from] += get_support_amount(c, from, to, closeness)
                    }
                }
            }
            init_cell_index += 1
        } else {
            init_cell_index = 0
            update_state = .Search_Cells
            print("Restart: Done\n")
        }
                
      case .Search_Cells:
        // Find next cell to be collapsed 
        assert(len(c.to_be_collapsed) == 0)
        spall_scope("Find next cell to be collapsed")
        
        found: [] ^Cell
        reached_end := true
        found_invalid := false
        minimal: Search
        init_search(&minimal, c, search_metric, context.temp_allocator)
        
        loop: for &cell, index in cells {
            if !cell.collapsed {
                switch test_search_cell(&minimal, &cell) {
                  case .Continue: // nothing
                  case .Done:     break loop
                    
                  case .Found_Invalid: 
                    found_invalid = true
                    break loop
                }
            }
            
            reached_end = index == len(found)-1
        }
        
        
        if found_invalid {
            result = .FoundContradiction
            unreachable()
        } else {
            found = minimal.cells[:]
        }
        
        if len(found) > 0 {
            if len(found[0].states) == 1 {
                spall_scope("Set All chosen cells to be collapse")
                mark_to_be_collapsed(c, ..found)
            } else {
                mark_to_be_collapsed(c, random_value(entropy, found))
            }
            
            update_state = .Collapse_Cells
        } else {
            if reached_end {
                result = .AllCollapsed
            }
        }
        
      case .Collapse_Cells:
        // Collapse chosen cell
        spall_scope("Collapse chosen cell")
        
        for cell in c.to_be_collapsed {
            pick := Invalid_State
            if len(cell.states) == 1 {
                pick = cell.states[0]
            } else {
                // Random
                total_frequency: i32
                for id in cell.states {
                    total_frequency += c.states[id].frequency
                }
                
                target := random_between(entropy, i32, 0, total_frequency)
                picking: for id in cell.states {
                    target -= c.states[id].frequency
                    if target <= 0 {
                        pick = id
                        break picking
                    }
                }
                assert(pick != Invalid_State)
            }
            
            assert(pick != Invalid_State)
            {
                for id in cell.states {
                    if pick != id {
                        remove_state(c, cell, id)
                    }
                }
                
                delete(cell.states)
                cell.collapsed = true
                cell.collapsed_state = pick
            }
        }
        
        clear(&c.to_be_collapsed)
        update_state = .Propagate_Changes
        
      case .Propagate_Changes:
        spall_scope("Propagate changes")
        
        if len(c.changes) == 0 {
            update_state = .Search_Cells
        } else {
            changed: Change
            for k, v in c.changes {
                changed = v
                delete_key(&c.changes, k)
                break
            }
            defer delete(changed.removed_supports)
            assert(len(changed.removed_supports) > 0)
            
            propagate_remove: for neighbour in changed.cell.neighbours {
                assert(neighbour.cell != nil)
                if neighbour.cell.collapsed do continue propagate_remove
                
                direction := neighbour.to_neighbour
                closeness := get_closeness(direction)
                #reverse for to, state_index in neighbour.cell.states {
                    should_remove: bool
                    when false {
                        spall_scope("removed support loop")
                        
                        removed := &changed.removed_supports[to]
                        amount  := &neighbour.support[to]
                        
                        if amount^ > 0 {
                            amount^ -= removed.amount[neighbour.to_neighbour_in_grid]
                            if amount^ <= 0 {
                                should_remove = true
                            }
                        }
                    } else {
                        spall_scope("recalc states loop")
                        
                        states: [] State_Id
                        if changed.cell.collapsed {
                            states = { changed.cell.collapsed_state }
                        } else {
                            states = changed.cell.states[:]
                        }
                        
                        should_remove = true
                        f: for from in states {
                            amount := get_support_amount(c, from, to, closeness)
                            should_remove = amount <= 0
                            if !should_remove do break f
                        }
                    }
                    
                    if should_remove {
                        remove_state(c, neighbour.cell, to)
                        
                        unordered_remove(&neighbour.cell.states, state_index)
                        if len(neighbour.cell.states) == 0 {
                            result = .FoundContradiction
                            break propagate_remove
                        }
                    }
                }
            }
        }
    
    }
    
    return result
}

remove_state :: proc (c: ^Collapse, cell: ^Cell, removed_state: State_Id) {
    spall_proc()
    
    p := cell.p
    change, ok := &c.changes[p]
    if !ok {
        c.changes[p] = { cell = cell }
        change = &c.changes[p]
    }
    
    if change.removed_supports == nil {
        spall_scope("remove_state: make removed support")
        make(&change.removed_supports, len(c.states))
    }

    when false do for neighbour in cell.neighbours {
        if neighbour.cell.collapsed do continue
        
        direction_from_neighbour := -neighbour.to_neighbour
        closeness := get_closeness(direction_from_neighbour)
        
        for support in supports(c, removed_state) {
            removed_support := &change.removed_supports[support.id]
            removed_support.id = support.id
            
            amount := get_support_amount_(support, closeness)
            removed_support.amount[neighbour.to_neighbour_in_grid] += amount
            unimplemented()
        }
    }
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
                        append_state_value(c, pixels[x + (height-1-y) * width])
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
    
    {
        spall_scope("Extraction: Color Groups")
        for state in c.states {
            color_id := state.values[N/2 + N/2 * N] // middle
            color := c.values[color_id]
            
            group: ^Color_Group
            for &it in color_groups {
                if it.color == color {
                    group = &it
                    break
                }
            }
            
            if group == nil {
                append(&color_groups, Color_Group { color = color })
                group = &color_groups[len(color_groups)-1]
                make(&group.ids, len(c.states))
            }
            
            group.ids[state.id] = true
        }
    }
    
    print("Extraction: Done\n")
}