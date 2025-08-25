package main

import "core:time"

N: i32 = 3

cells: [dynamic] Cell

Cell :: struct {
    p: v2, 
    triangle_points: [dynamic] v2,
    
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