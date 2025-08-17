#+vet !unused-procedures
#+no-instrumentation
package main

import "base:intrinsics"
import "base:runtime"
import "core:time"

////////////////////////////////////////////////

@(init)
default_views :: proc() {
    Default_Views[time.Duration] = proc (raw: pmm) -> (result: View_Proc_Result) {
        value := (cast(^time.Duration) raw)^
        result = view_time_duration(value)
        return result
    }
    
    Default_Views[time.Time] = proc (value: pmm) -> (result: View_Proc_Result) {
        value := (cast(^time.Time) value)^
        result = view_time(value)
        return result
    }
    
    Default_Views[runtime.Source_Code_Location] = proc (value: pmm) -> (result: View_Proc_Result) {
        value := (cast(^runtime.Source_Code_Location) value)^
        result = view_source_code_location(value)
        return result
    }
}

////////////////////////////////////////////////

// @todo(viktor): make precision and width parameters
view_percentage :: proc { view_percentage_parts, view_percentage_ratio }
view_percentage_parts :: proc(a, b: $N)  -> (result: View) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc(value: $F) -> (result: View) {
    result = view_float(value * 100, precision = 2, width = 2)
    return result
}

////////////////////////////////////////////////
// @todo(viktor): multi magnitude support, 10 Billion 583 Million 699 Thousand 496 and whatever
// @todo(viktor): view_number_with_divider, thousands dividers
// @todo(viktor): should there be a view_debug which shows all the types instead of that being a flag on the format_context?

Magnitude :: struct ($T: typeid) { upper_bound: T, symbol: string }

Memory :: enum {
    bytes     = 0,
    kilobytes = 1,
    megabytes = 2,
    gigabytes = 3,
    petabytes = 4,
    exabytes  = 5,
}
bytes_table := [?] Magnitude (umm) {
    {1024,  "b"},
    {1024, "kb"},
    {1024, "Mb"},
    {1024, "Gb"},
    {1024, "Tb"},
    {1024, "Pb"},
    {   0, "Eb"},
}


seconds_table := [?] Magnitude (time.Duration) {
    {1000, "ns"},
    {1000, "µs"},
    {1000, "ms"},
    {  60,  "s"},
    {  60,  "m"},
    {   0,  "h"},
}
Time_Unit :: enum {
    nanoseconds  = 0,
    microseconds = 1,
    milliseconds = 2,
    seconds      = 3,
    minutes      = 4,
    hours        = 5,
}

view_magnitude :: proc (value: $T, table: [] Magnitude (T), scale, limit: int, precision: u8 = 0) -> (result: TempViews) {
    begin_temp_views()
    section := table[scale:limit]
    
    before: T
    value := value
    for magnitude, index in section {
        if index == len(section)-1 || abs(value) < magnitude.upper_bound {
            if precision != 0 && scale + index != 0 {
                below := table[(scale + index) - 1]
                rest := cast(f64) before / cast(f64) below.upper_bound
                append_temp_view(view_float(rest, precision = precision))
                append_temp_view(view_string(magnitude.symbol))
            } else {
                append_temp_view(view_integer(value))
                append_temp_view(view_string(magnitude.symbol))
            }
            break
        }
        before = value
        value /= magnitude.upper_bound
    }
    
    result = end_temp_views()
    return result
}

////////////////////////////////////////////////

amount_table_long := [?] Magnitude (u64) {
    {1000, ""},
    {1000, "Tsd."},
    {1000, "Mio."},
    {1000, "Mrd."},
    {1000, "Bio."},
    {1000, "Brd."},
    {1000, "Tr."},
    {0,    "Trd."},
}

amount_table_short := [?] Magnitude (u64) {
    {1000, ""},
    {1000, "K"},
    {1000, "M"},
    {1000, "B"},
    {1000, "T"},
    {   0, "Q"},
}

// @todo(viktor): actually use it and see if this is correct
divider_table := [?] Magnitude (f64) {
    {1000, "."}, // quecto
    {1000, "."}, // ronto
    {1000, "."}, // yocto
    {1000, "."}, // zepto
    {1000, "."}, // atto
    {1000, "."}, // femto
    {1000, "."}, // pico
    {1000, "."}, // nano
    {1000, "."}, // micro
    {1000, "."}, // milli
    {1000, "."}, 
    {1000, "."}, // kilo
    {1000, "."}, // mega
    {1000, "."}, // giga
    {1000, "."}, // tera
    {1000, "."}, // peta
    {1000, "."}, // exa
    {1000, "."}, // zetta
    {1000, "."}, // yotta
    {1000, "."}, // ronna
    {   0, "."}, // quetta
}

units_table := [?] Magnitude (f64) {
    {1000, "q"}, // quecto
    {1000, "r"}, // ronto
    {1000, "y"}, // yocto
    {1000, "z"}, // zepto
    {1000, "a"}, // atto
    {1000, "f"}, // femto
    {1000, "p"}, // pico
    {1000, "n"}, // nano
    {1000, "µ"}, // micro
    {1000, "m"}, // milli
    /* 
    {10, "m"}, // milli
    {10, "c"}, // centi
    {10, "d"}, // deci
     */
    {1000, " "}, 
    /* 
    {10, " "},  // unit
    {10, "da"}, // deca
    {10, "h"},  // hecta
     */
    {1000, "k"}, // kilo
    {1000, "M"}, // mega
    {1000, "G"}, // giga
    {1000, "T"}, // tera
    {1000, "P"}, // peta
    {1000, "E"}, // exa
    {1000, "Z"}, // zetta
    {1000, "Y"}, // yotta
    {1000, "R"}, // ronna
    {   0, "Q"}, // quetta
}

////////////////////////////////////////////////
// Time

view_memory_size :: proc (value: umm, scale := Memory.bytes, limit := Memory.exabytes, precision: u8 = 0) -> (result: TempViews) {
    return view_magnitude(value, bytes_table[:], cast(int) scale, cast(int) limit, precision)
}
view_time_duration :: proc (value: time.Duration, scale := Time_Unit.nanoseconds, limit := Time_Unit.hours, precision: u8 = 0) -> (result: TempViews) {
    return view_magnitude(value, seconds_table[:], cast(int) scale, cast(int) limit, precision)
}

view_time :: proc (value: time.Time) -> (result: TempViews) {
    t := value
    y, mon, d := time.date(t)
    h, min, s := time.clock(t)
    ns := (t._nsec - (t._nsec/1e9 + time.UNIX_TO_ABSOLUTE)*1e9) % 1e9
    
    begin_temp_views()

    append_temp_view(view_integer(cast(i64) y,   width = 4))
    append_temp_view(view_character('-'))
    if mon < .October {
        // @note(viktor): Workaround as we do not handle width combined with .LeadingZero flag correctly
        append_temp_view(view_character('0'))
        append_temp_view(view_integer(cast(i64) mon, width = 1))
    } else {
        append_temp_view(view_integer(cast(i64) mon, width = 2))
    }
    append_temp_view(view_character('-'))
    append_temp_view(view_integer(cast(i64) d,   width = 2))
    append_temp_view(view_character(' '))
    
    append_temp_view(view_integer(cast(i64) h,   width = 2))
    append_temp_view(view_character(':'))
    append_temp_view(view_integer(cast(i64) min, width = 2))
    append_temp_view(view_character(':'))
    append_temp_view(view_integer(cast(i64) s,   width = 2))
    append_temp_view(view_character('.'))
    append_temp_view(view_integer((ns),          width = 9))
    append_temp_view(view_string(" +0000 UTC"))
    
    result = end_temp_views()
    return result
}

////////////////////////////////////////////////

view_source_code_location :: proc(value: runtime.Source_Code_Location) -> (result: TempViews) {
    begin_temp_views()
    
    append_temp_view(view_string(value.file_path))
            
    when ODIN_ERROR_POS_STYLE == .Default {
        open  :: '(' 
        close :: ')'
    } else when ODIN_ERROR_POS_STYLE == .Unix {
        open  :: ':' 
        close :: ':'
    } else {
        #panic("Unhandled ODIN_ERROR_POS_STYLE")
    }
    
    append_temp_view(view_character(open))
    
    append_temp_view(view_integer(u64(value.line)))
    if value.column != 0 {
        append_temp_view(view_character(':'))
        append_temp_view(view_integer(u64(value.column)))
    }

    append_temp_view(view_character(close))
    
    result = end_temp_views()
    return result
}
