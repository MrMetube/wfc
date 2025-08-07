package main

import "base:builtin"
import rl "vendor:raylib"

// @todo(viktor): dont rely on the user type, just use ids
Value :: rl.Color

Collapse :: struct {
    states: [dynamic] State,

    // Extraction
    is_defining_state:  b32,
    temp_state_values:  [dynamic] Value,
    _last_used_state_id: State_Id,
}

Search :: struct {
    c: ^Collapse,
    
    lowest: f32,
    mode:   Search_Mode,
    cells:  [dynamic] ^Cell,
    cell_entropies: map[^Cell] Entropy,
}

State_Id :: distinct u32
State    :: struct {
    id: State_Id,
    // @todo(viktor): values could be extracted into a parallel array and later on move it out to make the collapse more agnostic to the data
    values: [] Value,
    frequency: i32,
}

Search_Mode   :: enum { Scanline, States, Entropy, }
Search_Result :: enum { Continue, Done, Found_Invalid, }

Entropy :: struct {
    states_count_when_computed: u32,
    entropy: f32,
}

////////////////////////////////////////////////

reset_collapse :: proc (c: ^Collapse) {
    // @todo(viktor): there should be an easier way
    // println("%", view_variable(size_of(Collapse)))
    #assert(size_of(Collapse) == 96, "members have changed")
    delete(c.states)
    delete(c.temp_state_values)
    c ^= {}
}

////////////////////////////////////////////////

begin_state :: proc (c: ^Collapse) {
    assert(!c.is_defining_state)
    assert(len(c.temp_state_values) == 0)
    
    c.is_defining_state = true
}

append_state_value :: proc (c: ^Collapse, value: Value) {
    assert(c.is_defining_state)
    append(&c.temp_state_values, value)
}

end_state   :: proc (c: ^Collapse) {
    assert(c.is_defining_state)
    assert(len(c.temp_state_values) != 0)
    c.is_defining_state = false
    
    id := Invalid_Id
    search: for state in c.states {
        if len(c.temp_state_values) != len(state.values) do continue search
        
        for value, index in state.values {
            if value != c.temp_state_values[index] {
                continue search
            }
        }
        
        id = state.id
        break search
    }
    
    if id == Invalid_Id {
        assert(c._last_used_state_id == auto_cast len(c.states))
        id = c._last_used_state_id
        c._last_used_state_id += 1
        
        values := make([] Value, len(c.temp_state_values))
        copy(values, c.temp_state_values[:])
        append(&c.states, State { id = id, values = values, frequency = 1 })
        
        assert(c._last_used_state_id == auto_cast len(c.states))
    } else {
        c.states[id].frequency += 1
    }
    assert(id != Invalid_Id)
    
    clear(&c.temp_state_values)
}

Invalid_Id :: max(State_Id)

////////////////////////////////////////////////

init_search :: proc (search: ^Search, c: ^Collapse, mode: Search_Mode, allocator := context.allocator) {
    search.lowest = PositiveInfinity
    
    search.c    = c
    search.mode = mode
    make(&search.cells, allocator)
}

// @todo(viktor): what information do we acutally need, is cell/wave function the minimal set?
// @todo(viktor): gumin add some noise to the entropy: 1e-6 * random.NextDouble();
test_search_cell :: proc (search: ^Search, cell: ^Cell, wave: ^WaveFunction) -> (result: Search_Result) {
    result = .Continue
    
    if len(wave.supports) == 0 {
        should_restart = true
        result = .Found_Invalid
    } else {
        if search_mode == .Scanline {
            append(&search.cells, cell)
            result = .Done
        } else {
            value: f32
            if search.mode == .Entropy {
                entry, ok := &search.cell_entropies[cell]
                if !ok {
                    search.cell_entropies[cell] = {}
                    entry = &search.cell_entropies[cell]
                }
                
                if entry.states_count_when_computed != auto_cast len(wave.supports) {
                    entry.states_count_when_computed = auto_cast len(wave.supports)
                    
                    // @speed this could be done iteratively if needed
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
            } else {
                value = cast(f32) len(wave.supports)
            }
            
            if search.lowest > value {
                search.lowest = value
                clear(&search.cells)
            }
            
            if search.lowest == value {
                append(&search.cells, cell)
            }
        }
    }
    
    return result
}