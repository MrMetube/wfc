#+vet !unused-procedures
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

order_of_magnitude :: proc(value: $T) -> (f64, string) {
    value := cast(f64) value
    
    if value == 0   do return value,        ""
    if value < 1e-9 do return value * 1e12, "p"
    if value < 1e-6 do return value * 1e9,  "n"
    if value < 1e-3 do return value * 1e6,  "µ"
    if value < 1e0  do return value * 1e3,  "m"
    if value < 1e3  do return value * 1e0,  ""
    if value < 1e6  do return value * 1e-3,  "k"
    if value < 1e9  do return value * 1e-6,  "M"
    if value < 1e12 do return value * 1e-9,  "G"
    if value < 1e15 do return value * 1e-12, "T"
    if value < 1e18 do return value * 1e-15, "P"
    if value < 1e21 do return value * 1e-18, "E"
    
    return value, "?"
}

view_memory_size :: proc(#any_int value: u64) -> (u64, string) {
    if value == 0       do return value,            ""
    if value < Kilobyte do return value,            " b"
    if value < Megabyte do return value / Kilobyte, "kb"
    if value < Gigabyte do return value / Megabyte, "Mb"
    if value < Terabyte do return value / Gigabyte, "Gb"
    if value < Petabyte do return value / Terabyte, "Tb"
    if value < Exabyte  do return value / Petabyte, "Pb"
    
    return value , "?"
}

// @todo(viktor): take some inspiration from view_duration scale/decimal stuff
view_order_of_magnitude :: proc(value: $T, width: Maybe(u16) = 5, precision: Maybe(u8) = 2) -> (result: TempViews) {
    v, magnitude := order_of_magnitude(value)
    
    when intrinsics.type_is_integer(T) {
        precision := precision
        if v == cast(f64) value do precision = 0
        v = round(f64, v * 100) * 0.01
    }

    begin_temp_views()
    append_temp_view(view_float(v, width = width, precision = precision))
    append_temp_view(view_string(magnitude))
    result = end_temp_views()
    
    return result
}

view_percentage :: proc { view_percentage_parts, view_percentage_ratio }
view_percentage_parts :: proc(a, b: $N)  -> (result: View) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc(value: $F) -> (result: View) {
    result = view_float(value * 100, precision = 0, width = 2)
    return result
}

////////////////////////////////////////////////
// Time

TimeScale :: enum {
    None,
    
    Nanos,
    Micros,
    Millis,
    Seconds,
    Minutes,
    Hours,
}

time_scale_to_factor := [TimeScale] time.Duration {
    .None    = 0,
    
    .Nanos   = time.Nanosecond,
    .Micros  = time.Microsecond,
    .Millis  = time.Millisecond,
    .Seconds = time.Second,
    .Minutes = time.Minute,
    .Hours   = time.Hour,
}

time_scale_to_symbol := [TimeScale] string {
    .None    = "",
    
    .Nanos   = "ns",
    .Micros  = "µs",
    .Millis  = "ms",
    .Seconds = "s",
    .Minutes = "m",
    .Hours   = "h",
}

view_time_duration :: proc (value: time.Duration, scale := TimeScale.None, limit := TimeScale.None, show_limit_as_decimal := false, width: Maybe(u16) = nil, precision: Maybe(u8) = nil) -> (result: TempViews) {
    scale, limit := scale, limit
    rest := value
    
    begin_temp_views(width)
    
    if rest < 0 {
        append_temp_view(view_character('-'))
        rest = -rest
    }
    
    if scale == .None {
        scale = TimeScale.Nanos
        for scale + auto_cast 1 <= .Hours && rest >= time_scale_to_factor[scale + auto_cast 1] {
            scale += auto_cast 1
        }
    }
    if limit == .None {
        limit = scale
    }
    
    if rest == 0 {
        append_temp_view(view_integer(rest))
        append_temp_view(view_string(time_scale_to_symbol[scale]))
    } else {
        for ; rest > 0 && (show_limit_as_decimal ? scale > limit : scale >= limit); scale -= auto_cast 1 {
            factor := time_scale_to_factor[scale]
            current := rest / factor
            rest     = rest % factor
            
            append_temp_view(view_integer(current))
            append_temp_view(view_string(time_scale_to_symbol[scale]))
        }
        
        if rest != 0 && show_limit_as_decimal {
            precision := precision
            if precision == nil {
                max_precision := cast(u8) (scale - .Nanos) * 3
                precision = max_precision
            }
            factor := time_scale_to_factor[scale]
            s := cast(f64) rest / cast(f64) factor
            
            append_temp_view(view_float(s, precision = precision))
            append_temp_view(view_string(time_scale_to_symbol[scale]))
        }
    }
    
    result = end_temp_views()
    return result
}

view_seconds :: proc (value: $F, width: Maybe(u16) = nil, precision: Maybe(u8) = 0) -> (result: TempViews) 
where intrinsics.type_is_float(F) {
    return view_duration(value, .Seconds, width = width, precision = precision)
}
view_duration :: proc (value: $F, scale: TimeScale,  width: Maybe(u16) = nil, precision: Maybe(u8) = 0) -> (result: TempViews) 
where intrinsics.type_is_float(F) {
    duration := cast(time.Duration) (cast(f64) value * cast(f64) time_scale_to_factor[scale])
    result = view_time_duration(duration, scale = scale, show_limit_as_decimal = true, width = width, precision = precision)
    return result
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
