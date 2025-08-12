package main

import "base:builtin"
import rl "vendor:raylib"

// @todo(viktor): dont rely on the user type, just use ids
Value :: rl.Color

Collapse :: struct {
    states: [dynamic] State,
    supports: [/* from State_Id */] [dynamic] Support,
    values: [dynamic] Value,
    // Extraction
    is_defining_state:  b32,
    temp_state_values:  [dynamic] Value_Id,
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

Search_Mode   :: enum { Scanline, Metric, }
Search_Metric :: enum { States, Entropy }
Search_Result :: enum { Continue, Done, Found_Invalid, }

Entropy :: struct {
    states_count_when_computed: u32,
    entropy: f32,
}

////////////////////////////////////////////////

reset_collapse :: proc (c: ^Collapse) {
    // @todo(viktor): there should be an easier way
    // println("%", view_variable(size_of(Collapse))); assert(false)
    #assert(size_of(Collapse) <= 144, "members have changed")
    delete(c.states)
    delete(c.temp_state_values)
    c ^= { supports = c.supports }
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
        subsections := [Direction] Rectangle2i {
            .East  = { { 1, 0 }, {   N,   N } },
            .West  = { { 0, 0 }, { N-1,   N } },
            .South = { { 0, 1 }, {   N,   N } },
            .North = { { 0, 0 }, {   N, N-1 } },
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
@(no_instrumentation)
test_search_cell :: proc (search: ^Search, cell: ^Cell, wave: ^WaveFunction) -> (result: Search_Result) {
    result = .Continue
    
    if len(wave.supports) == 0 {
        result = .Found_Invalid
    } else {
        value: f32
        switch search.metric {
          case .States:
            value = cast(f32) len(wave.supports)
            
          case .Entropy: 
            entry := &cell.entry
            if entry.states_count_when_computed != auto_cast len(wave.supports) {
                entry.states_count_when_computed = auto_cast len(wave.supports)
                
                // @speed this could be done iteratively if needed, but its fast enough for now
                total_frequency: f32
                entry.entropy = 0
                for support in wave.supports {
                    total_frequency += cast(f32) search.c.states[support.id].frequency
                }
                
                for support in wave.supports {
                    frequency := cast(f32) search.c.states[support.id].frequency
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