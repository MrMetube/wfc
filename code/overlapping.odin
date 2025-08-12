package main

import "core:time"

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
 
to_be_collapsed: [dynamic] ^Cell

// Cached values for restart
maximum_support: [] [Direction] i32

Neighbour :: struct {
    direction: Direction,
    cell:      ^Cell,
}
Cell :: struct {
    p: v2i,
    neighbours: [] Neighbour,
    
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
        if len(to_be_collapsed) == 0 {
            // Find next cell to be collapsed 
            spall_scope("Find next cell to be collapsed")
            
            cells: [] ^Cell
            reached_end := true
            found_invalid := false
            switch search_mode {
              case .Scanline:
                scan: for &cell in grid do if _, ok := cell.value.(WaveFunction); ok {
                    cells = { &cell }
                    reached_end = false
                    break scan
                }
                
              case .Metric:
                minimal: Search
                init_search(&minimal, c, search_metric, context.temp_allocator)
                
                loop: for &cell, index in grid {
                    if wave, ok := &cell.value.(WaveFunction); ok {
                        switch test_search_cell(&minimal, &cell, wave) {
                          case .Continue: // nothing
                          case .Done:     break loop
                            
                          case .Found_Invalid: 
                            found_invalid = true
                            break loop
                        }
                    }
                    
                    reached_end = index == len(grid)-1
                }
                
                
                if found_invalid {
                    result = .FoundContradiction
                    break_here := 123; break_here = break_here
                } else {
                    cells = minimal.cells[:]
                }
            }
            
            if len(cells) > 0 {
                if len(cells[0].value.(WaveFunction).supports) == 1 {
                    spall_scope("Set All chosen cells to be collapse")
                    append(&to_be_collapsed, ..cells)
                } else {
                    append(&to_be_collapsed, random_value(entropy, cells))
                }
            } else {
                if reached_end {
                    result = .AllCollapsed
                }
            }
        } else {
            // Collapse chosen cell
            spall_scope("Collapse chosen cell")
            
            for cell in to_be_collapsed {
                wave := cell.value.(WaveFunction)
                pick := Invalid_State
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
                    assert(pick != Invalid_State)
                }
                
                assert(pick != Invalid_State)
                {
                    for support in wave.supports {
                        id := support.id
                        if pick != id {
                            remove_state(c, cell.p, id)
                        }
                    }
                    
                    delete(wave.supports)
                    cell.value = pick
                }
            }
            
            clear(&to_be_collapsed)
            doing_changes = true
        }
    } else {
        // Propagate changes
        spall_scope("Propagate changes")
        
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
            
            from_cell := grid[change_p.x + change_p.y * dimension.x]
            propagate: for neighbour, direction in from_cell.neighbours {
                assert(neighbour.cell != nil)
                
                to_wave, ok := &neighbour.cell.value.(WaveFunction)
                if !ok do continue
                
                spall_scope("removed support loop")
                #reverse for &to_support, sup_index in to_wave.supports {
                    removed := &change.removed_support[to_support.id]
                    assert((removed.id == to_support.id) || (removed.amount[neighbour.direction] == 0))
                    
                    amount := &to_support.amount[neighbour.direction]
                    assert(amount^ != 0)
                    
                    amount^ -= removed.amount[neighbour.direction]
                    if amount^ <= 0 {
                        remove_state(c, neighbour.cell.p, to_support.id)
                        
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
            spall_scope("remove_state: make removed support")
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
        spall_scope("Restart: initialize support")
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
        spall_scope("Restart: enforce drawing")
        
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
    
    println("Restart: Done")
}

extract_states :: proc (c: ^Collapse, pixels: [] Value, width, height: i32) {
    for a in c.supports do delete(a)
    delete(c.supports)
    
    for &group in draw_groups {
        delete(group.ids)
    }
    clear(&draw_groups)
    selected_group  = nil
    viewing_group   = nil
    clear_draw_board()
    
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
                        append_state_value(c, pixels[x + y * width])
                    }
                }
                end_state(c)
            }
            
            print("Extraction: State extraction % %%\r", view_percentage(by, height))
        }
        println("Extraction: State extraction done: %        ", view_time_duration(time.since(start), show_limit_as_decimal = true, precision = 3))
    }
    // 1.3s  | 6.7s
    // 1.2s  | 6.1s
    // 1.2s  | 3.9s
    // 1.2s  | 3.0s
    // 450ms | 3.0s
    
    make(&c.supports, len(c.states))
    
    {
        start := time.now()
        spall_scope("Extraction: Supports generation")
        
        for a, a_index in c.states {
            assert(a.id == auto_cast a_index)
            for d in Direction {
                a_hash := a.hashes[d]
                for b in c.states {
                    b_hash := b.hashes[cast(Direction) ((cast(u32) d+2)%4)]
                    
                    if a_hash == b_hash {
                        spall_scope("Extraction: binary search supports")
                        found_support := false
                        
                        // binary search
                        l, r := 0, len(c.supports[a.id])-1
                        for l <= r {
                            m := (l + r) / 2
                            support := &c.supports[a.id][m]
                            if support.id == b.id {
                                found_support = true
                                support.amount[d] += 1
                                break
                            } else if support.id > b.id {
                                r = m - 1
                            } else {
                                l = m + 1
                            }
                        }
                    
                        if !found_support {
                            value := Support { id = b.id }
                            value.amount[d] = 1
                            append(&c.supports[a.id], value)
                        }
                    }
                }
            }
            print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
            
        }
        
        println("Extraction: Supports generation done: %       ", view_time_duration(time.since(start), show_limit_as_decimal = true, precision = 3))
    }
    
    delete(maximum_support)
    make(&maximum_support, len(c.states))
    {
        spall_scope("Extraction: calculate maximum support")
            
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
        spall_scope("Extraction: Draw Groups grouping")
        for state in c.states {
            color_id := state.values[1 + 1 * N] // middle
            color := c.values[color_id]
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
    
    println("Extraction: Done")
}
