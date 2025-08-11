package main

 /*
 * if we ignore even N values then the difference between overlapping and tiled mode is:
 * overlapping: tiles match on a side if N-1 rows/columns match
 * tiled:       tiles match on a side if   1 row/column matches
 * 
 * overlapping: extract NxN at every pixel
 * tiled:       extract NxN at every N-th pixel
*/

N: i32 = 3

grid: [] Cell
 
to_be_collapsed: ^Cell

// Cached values for restart
maximum_support: [] [Direction] i32

Cell :: struct {
    p: v2i,
    
    value: union {
        State_Id,
        WaveFunction,
    },
    
    // @todo(viktor): find a better place for this
    entry: Entropy,
}

WaveFunction :: struct {
    supports: [dynamic] Support,
}

doing_changes: b32
// @todo(viktor): its nice that its constant time lookup but the arbitrary order when iterating is worse
changes: map[v2i] Change

Change :: struct {
    removed_support: [/* State_Id */] Support,
}

Support :: struct {
    id:     State_Id,
    amount: [Direction] i32,
}

Update_Result :: enum {
    CollapseUninialized,
    Continue,
    FoundContradiction,
    AllCollapsed,
}

update :: proc (c: ^Collapse, entropy: ^RandomSeries) -> (result: Update_Result) {
    if c.states == nil do return .CollapseUninialized
    
    result = .Continue
    if !doing_changes {
        if to_be_collapsed == nil {
            // Find next cell to be collapsed 
            spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Find next cell to be collapsed")
            
            cells: [] ^Cell
            all_reached_end := true
            any_found_invalid := false
            switch search_mode {
              case .Scanline:
                scan: for &cell in grid do if _, ok := cell.value.(WaveFunction); ok {
                    cells = { &cell }
                    all_reached_end = false
                    break scan
                }
                
              case .Metric:
                Data :: struct {
                    search:  Search,
                    
                    grid_section:  [] Cell,
                    found_invalid: b32,
                    reached_end:   b32,
                }
                
                rows := dimension.y / 4
                work_units := make([] Data, rows, context.temp_allocator)
                for &work, row in work_units {
                    size := dimension.x * 4
                    work.grid_section = grid[cast(i32) row * size:][:size]
                    
                    init_search(&work.search, c, search_metric, context.temp_allocator)
                    
                    enqueue_work(&work_queue, &work, proc (work: ^Data) {
                        using work
                        loop: for &cell in grid_section {
                            if wave, ok := &cell.value.(WaveFunction); ok {
                                switch test_search_cell(&search, &cell, wave) {
                                  case .Continue: // nothing
                                  case .Done:     break loop
                                
                                  case .Found_Invalid: 
                                    found_invalid = true
                                    break loop
                                }
                            }
                        }
                        
                        reached_end = true
                    })
                }
                complete_all_work(&work_queue)
                
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Join searches")
                
                minimal: Search
                init_search(&minimal, c, search_metric, context.temp_allocator)
                
                least: for work in work_units {
                    all_reached_end &&= work.reached_end
                    if work.found_invalid {
                        any_found_invalid ||= true
                        break least
                    } else {
                        if len(work.search.cells) > 0 {
                            if search_mode == .Scanline {
                                minimal = work.search
                                break least
                            }
                            
                            assert(search_mode != .Scanline)
                            if minimal.lowest > work.search.lowest {
                                minimal = work.search
                            } else if minimal.lowest == work.search.lowest {
                                append(&minimal.cells, ..work.search.cells[:])
                            }
                        }
                    }
                }
                
                if any_found_invalid {
                    result = .FoundContradiction
                    break_here := 123; break_here = break_here
                } else {
                    cells = minimal.cells[:]
                }
            }
            
            if len(cells) > 0 {
                to_be_collapsed = random_value(entropy, cells)
            } else {
                if all_reached_end {
                    result = .AllCollapsed
                }
            }
        } else {
            // Collapse chosen cell
            spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Collapse chosen cell")
            
            wave := to_be_collapsed.value.(WaveFunction)
            pick := Invalid_Id
            if len(wave.supports) == 1 {
                pick = wave.supports[0].id
            } else {
                // Random
                total_frequency: i32
                for support in wave.supports {
                    total_frequency += c.states[support.id].frequency
                }
                
                target := random_between(entropy, i32, 0, total_frequency)
                picking: for support in wave.supports {
                    target -= c.states[support.id].frequency
                    if target <= 0 {
                        pick = support.id
                        break picking
                    }
                }
                assert(pick != Invalid_Id)
            }
            
            if pick != Invalid_Id {
                for support in wave.supports {
                    id := support.id
                    if pick != id {
                        remove_state(c, to_be_collapsed.p, id)
                    }
                }
                
                delete(wave.supports)
                to_be_collapsed.value = pick
                to_be_collapsed = nil
                doing_changes = true
            }
        }
    } else {
        // Propagate changes
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Propagate changes")
        
        if len(changes) == 0 {
            drawing_initializing = false
            doing_changes = false
        } else {
            change_p: v2i
            change: Change
            for k, v in changes {
                change_p = k
                change = v
                break
            }
            delete_key(&changes, change_p)
            assert(len(change.removed_support) > 0)
            
            propagate: for delta, direction in Deltas {
                to_p := change_p + delta
                if !dimension_contains(dimension, to_p) {
                    if wrapping {
                        to_p = rectangle_modulus(rectangle_min_dimension(v2i{}, dimension), to_p)
                    } else {
                        continue 
                    }
                }
                
                to_cell := &grid[to_p.x + to_p.y * dimension.x]
                to_wave, ok := &to_cell.value.(WaveFunction)
                if !ok do continue 
                
                {
                    spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "removed support loop")
                    #reverse for &to_support, sup_index in to_wave.supports {
                        removed := &change.removed_support[to_support.id]
                        assert((removed.id == to_support.id) || (removed.amount[direction] == 0))
                        
                        amount := &to_support.amount[direction]
                        assert(amount^ != 0)
                        
                        amount^ -= removed.amount[direction]
                        if amount^ <= 0 {
                            remove_state(c, to_p, to_support.id)
                            
                            unordered_remove(&to_wave.supports, sup_index)
                            if len(to_wave.supports) == 0 {
                                result = .FoundContradiction
                                break propagate
                            }
                        }
                    }
                }
            }
        }
    }
    
    return result
}

remove_state :: proc (c: ^Collapse, p: v2i, removed_state: State_Id) {
    change, ok := &changes[p]
    if !ok {
        changes[p] = {}
        change = &changes[p]
    }
    
    // @todo(viktor): We could just have a flat buffer of all these removals and only accumulate them in the update loop itself once the change is being processed
    for removed in c.supports[removed_state] {
        if change.removed_support == nil {
            spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "remove_state: make removed support")
            make(&change.removed_support, len(c.states))
        }
        
        for direction in Direction {
            change.removed_support[removed.id].id = removed.id
            change.removed_support[removed.id].amount[direction] += removed.amount[direction]
        }
    }
}

restart :: proc (c: ^Collapse) {
    clear(&changes)
    to_be_collapsed = nil
    
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Restart: initialize support")
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                cell := &grid[x + y * dimension.x]
                wave, ok := &cell.value.(WaveFunction)
                if ok {
                    delete(wave.supports)
                } else {
                    cell.value = WaveFunction  {}
                    wave = &cell.value.(WaveFunction)
                }
                
                make(&wave.supports, len(c.states))
                for &it, index in wave.supports {
                    it.id = cast(State_Id) index
                    for &amount, direction in it.amount {
                        amount = maximum_support[it.id][direction]
                    }
                }
            }
            print("Restart: initialize support % %% \r", view_percentage(y, dimension.y))
        }
        println("Restart: initialize support done           ")
    }
    
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Restart: enforce drawing")
        
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                group := draw_board[x + y * dimension.x]
                if group != nil {
                    restrict_cell_to_drawn(c, {x, y}, group)
                    drawing_initializing = true
                }
            }
        }
    }
}

extract_states :: proc (c: ^Collapse, pixels: [] Value, width, height: i32) {
    for a in c.supports do delete(a)
    delete(c.supports)
    
    for &group in draw_groups {
        delete(group.ids)
    }
    clear(&draw_groups)
    selected_group = nil
    clear_draw_board()
    
    // @incomplete: Allow for rotations and mirroring here
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "State Extraction")
        for by in 0..<height {
            for bx in 0..<width {
                begin_state(c)
                for dy in 0..<N {
                    for dx in 0..<N {
                        x := (bx + dx) % width
                        y := (by + dy) % height
                        append_state_value(c, pixels[x + y * width])
                    }
                }
                end_state(c)
            }
            
            print("Extraction: State extraction % %%\r", view_percentage(by, height))
        }
        println("Extraction: State extraction done         ")
    }
    
    make(&c.supports, len(c.states))
    
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Extraction: Supports generation")
        for a, a_index in c.states {
            assert(a.id == auto_cast a_index)
            for delta, d in Deltas {
                region := rectangle_min_dimension(cast(i32) 0, 0, N, N)
                dim := get_dimension(region)
                for b in c.states {
                    does_match: b8 = true
                    // @speed we could hash these regions and only compare hashes in the n²-loop
                    loop: for y: i32; y < dim.y; y += 1 {
                        for x: i32; x < dim.x; x += 1 {
                            ap := v2i{x, y}
                            bp := v2i{x, y} - delta
                            
                            if contains(region, bp) {
                                a_value := a.values[ap.x + ap.y * dim.x]
                                b_value := b.values[bp.x + bp.y * dim.x]
                                if a_value != b_value {
                                    does_match = false
                                    break loop
                                }
                            }
                        }
                    }
                
                    if does_match {
                        found_support: b32
                        for &support in c.supports[a.id] {
                            if support.id == b.id {
                                found_support = true
                                support.amount[d] += 1
                            }
                        }
                        // @todo(viktor): Think if this is even reasonably
                        if !found_support {
                            value: Support
                            value.id        = b.id
                            value.amount[d] = 1
                            append(&c.supports[a.id], value)
                        }
                    }
                }
            }
            
            print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
        }
        println("Extraction: Supports generation done        ")
    }
    
    delete(maximum_support)
    make(&maximum_support, len(c.states))
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Extraction: calculate maximum support")
            
        for from, index in c.states {
            for direction in Direction {
                for support in c.supports[from.id] {
                    amount := &maximum_support[support.id][direction]
                    amount^ += support.amount[direction]
                }
            }
            print("Extraction: calculate maximum support % %% \r", view_percentage(index, len(c.states)))
        }
        println("Extraction: calculate maximum support done          ")
    }
    
    {
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Extraction: Draw Groups grouping")
        for state in c.states {
            color := state.values[1 + 1 * N] // middle
            group: ^Draw_Group
            for &it in draw_groups {
                if it.color == color {
                    group = &it
                    break
                }
            }
            if group == nil {
                append(&draw_groups, Draw_Group { color = color })
                group = &draw_groups[len(draw_groups)-1]
                make(&group.ids, len(c.states))
            }
            
            group.ids[state.id] = true
        }
    }
}
