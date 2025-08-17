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

grid: [dynamic] Cell

to_be_collapsed: [dynamic] ^Cell

Cell :: struct {
    p: v2, 
    triangles: [dynamic] Triangle, 
    
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

doing_changes: b32
// @todo(viktor): its nice that its constant time lookup but the arbitrary order when iterating is worse
changes: map[v2] Change

Change :: struct {
    cell: ^Cell,
    removed_supports: [/* State_Id */] Support,
}

Support :: struct {
    id:     State_Id,
    amount: [Direction] f32,
}

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
    if !doing_changes {
        if len(to_be_collapsed) == 0 {
            // Find next cell to be collapsed 
            spall_scope("Find next cell to be collapsed")
            
            cells: [] ^Cell
            reached_end := true
            found_invalid := false
            switch search_mode {
              case .Scanline:
                scan: for &cell in grid do if !cell.collapsed {
                    cells = { &cell }
                    reached_end = false
                    break scan
                }
                
              case .Metric:
                minimal: Search
                init_search(&minimal, c, search_metric, context.temp_allocator)
                
                loop: for &cell, index in grid {
                    if !cell.collapsed {
                        switch test_search_cell(&minimal, &cell) {
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
                    unreachable()
                } else {
                    cells = minimal.cells[:]
                }
            }
            
            if len(cells) > 0 {
                if len(cells[0].states) == 1 {
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
            changed: Change
            for k, v in changes {
                changed = v
                delete_key(&changes, k)
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
    change, ok := &changes[p]
    if !ok {
        changes[p] = { cell = cell }
        change = &changes[p]
    }
    
    if change.removed_supports == nil {
        spall_scope("remove_state: make removed support")
        make(&change.removed_supports, len(c.states))
    }

    if false do for neighbour in cell.neighbours {
        if neighbour.cell.collapsed do continue
        
        direction_from_neighbour := -neighbour.to_neighbour
        closeness := get_closeness(direction_from_neighbour)
        
        for support in supports(c, removed_state) {
            removed_support := &change.removed_supports[support.id]
            removed_support.id = support.id
            
            amount := get_support_amount_(support, closeness)
            // removed_support.amount[neighbour.to_neighbour_in_grid] += amount
            unimplemented()
        }
    }
}

restart :: proc (c: ^Collapse) {
    spall_proc()
    clear(&changes)
    to_be_collapsed = nil
    
    {
        spall_scope("Restart: initialize states")
        for &cell, cell_index in grid {
            if !cell.collapsed {
                delete(cell.states)
            } else {
                cell.collapsed = false
            }
            
            make(&cell.states, len(c.states))
            for &id, index in cell.states do id = cast(State_Id) index
            
            print("Restart: initialize states % %% \r", view_percentage(cell_index, len(grid)))
        }
        println("Restart: initialize states done           ")
    }
    
    {
        spall_scope("Restart: initialize support")
        for &cell, cell_index in grid {
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
            print("Restart: initialize support % %% \r", view_percentage(cell_index, len(grid)))
        }
        println("Restart: initialize support done           ")
    }
    
    {
        spall_scope("Restart: enforce drawing")
        // @todo(viktor): why dont we just use this as the initial value above?
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
    spall_proc()
    
    reset_collapse(c)
    
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
                        append_state_value(c, pixels[x + (height-1-y) * width])
                    }
                }
                end_state(c)
            }
            
            print("Extraction: State extraction % %%\r", view_percentage(by, height))
        }
        println("Extraction: State extraction done: %        ", view_time_duration(time.since(start), precision = 3))
        println("Test 1 nano with precision%        ", view_time_duration(1, precision = 3))
    }
    // 1.3s  | 6.7s
    // 1.2s  | 6.1s
    // 1.2s  | 3.9s
    // 1.2s  | 3.0s
    // 450ms | 3.0s
    
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
        
        println("Extraction: Supports generation done: %       ", view_time_duration(time.since(start), precision = 3))
    }
    
    {
        spall_scope("Extraction: Draw Groups grouping")
        for state in c.states {
            color_id := state.values[N/2 + N/2 * N] // middle
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
