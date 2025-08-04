package main

import "base:builtin"
import rl "vendor:raylib"

// @todo(viktor): dont rely on the user type, just use ids
Value :: rl.Color

Collapse :: struct {
    _states: [dynamic] State,

    Extraction: struct {
        is_defining_state:  b32,
        temp_state_values:  [dynamic] Value,
        _last_used_state_id: State_Id,
    },
}

State_Id :: distinct u32
State    :: struct {
    id: State_Id,
    // @todo(viktor): values could be extracted into a parallel array and later on move it out to make the collapse more agnostic to the data
    values: [] Value,
    frequency: i32,
}

////////////////////////////////////////////////

begin_state :: proc (c: ^Collapse) {
    assert(!c.Extraction.is_defining_state)
    assert(len(c.Extraction.temp_state_values) == 0)
    
    c.Extraction.is_defining_state = true
}

append_state_value :: proc (c: ^Collapse, value: Value) {
    assert(c.Extraction.is_defining_state)
    append(&c.Extraction.temp_state_values, value)
}

end_state   :: proc (c: ^Collapse) {
    assert(c.Extraction.is_defining_state)
    assert(len(c.Extraction.temp_state_values) != 0)
    c.Extraction.is_defining_state = false
    
    id := Invalid_Id
    search: for state in c._states {
        if len(c.Extraction.temp_state_values) != len(state.values) do continue search
        
        for value, index in state.values {
            if value != c.Extraction.temp_state_values[index] {
                continue search
            }
        }
        
        id = state.id
        break search
    }
    
    if id == Invalid_Id {
        assert(c.Extraction._last_used_state_id == auto_cast len(c._states))
        id = c.Extraction._last_used_state_id
        c.Extraction._last_used_state_id += 1
        
        values := make([] Value, len(c.Extraction.temp_state_values))
        copy(values, c.Extraction.temp_state_values[:])
        append(&c._states, State { id = id, values = values, frequency = 1 })
        
        assert(c.Extraction._last_used_state_id == auto_cast len(c._states))
    } else {
        c._states[id].frequency += 1
    }
    assert(id != Invalid_Id)
    
    clear(&c.Extraction.temp_state_values)
}

Invalid_Id :: max(State_Id)
