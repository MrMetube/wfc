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
// @todo(viktor): view_time_duration, view_number_with_divider, view_magnitude and view_memory_size are very similar. how can we simplify this process of estimating a magnitude/scale/size and slicing the value into magnitudes/scales/sizes?
// @todo(viktor): view_number_with_divider, thousands dividers
// @todo(viktor): should there be a view_debug which shows all the types instead of that being a flag on the format_context?

Magnitude :: enum {
    None,
    
    Femto,
    Pico,
    Nano,
    Micro,
    Milli,
    
    Unit,
    
    Kilo,
    Mega,
    Giga,
    Tera,
    Peta,
    Exa,
}

magnitude_to_symbol := [Magnitude] string {
    .None    = "",
    
    .Femto  = "f",
    .Pico   = "p",
    .Nano   = "n",
    .Micro  = "µ",
    .Milli  = "m",
    
    .Unit   = "",
    
    .Kilo   = "k",
    .Mega   = "M",
    .Giga   = "G",
    .Tera   = "T",
    .Peta   = "P",
    .Exa    = "E",
}

magnitude_to_factor_float :: proc ($T: typeid, magnitude: Magnitude) -> (result: T) {
    switch magnitude {
      case .None:  unreachable()
      case .Femto: when intrinsics.type_is_integer(T) do unreachable(); else do return 1e-15
      case .Pico:  when intrinsics.type_is_integer(T) do unreachable(); else do return 1e-12
      case .Nano:  when intrinsics.type_is_integer(T) do unreachable(); else do return 1e-9
      case .Micro: when intrinsics.type_is_integer(T) do unreachable(); else do return 1e-6
      case .Milli: when intrinsics.type_is_integer(T) do unreachable(); else do return 1e-3
      case .Unit:  return 1e0
      case .Kilo:  return 1e3
      case .Mega:  return 1e6
      case .Giga:  return 1e9
      case .Tera:  return 1e12
      case .Peta:  return 1e15
      case .Exa:   return 1e18
    }
    unreachable()
}



/* 
@todo(viktor): think about it

time_in_nanoseconds  := with_basis(time_in_nanoseconds, Time_Scale.Nanoseconds)
time_in_microseconds := with_basis(time_in_nanoseconds, Time_Scale.Microseconds)
time_in_milliseconds := with_basis(time_in_nanoseconds, Time_Scale.Milliseconds)
time_in_seconds      := with_basis(time_in_nanoseconds, Time_Scale.Seconds)
time_in_minutes      := with_basis(time_in_nanoseconds, Time_Scale.Minutes)
time_in_hours        := with_basis(time_in_nanoseconds, Time_Scale.Hours)

memory_in_bytes     := with_basis_as(memory_size_in_bytes, Memory_Size.Bytes,     f64)
memory_in_kilobytes := with_basis_as(memory_size_in_bytes, Memory_Size.Kilobytes, f64)
memory_in_megabytes := with_basis_as(memory_size_in_bytes, Memory_Size.Megabytes, f64)
memory_in_gigabytes := with_basis_as(memory_size_in_bytes, Memory_Size.Gigabytes, f64)
memory_in_petabytes := with_basis_as(memory_size_in_bytes, Memory_Size.Petabytes, f64)
memory_in_exabytes  := with_basis_as(memory_size_in_bytes, Memory_Size.Exabytes,  f64)



Time_Scale :: enum {
    Nanoseconds  = 0,
    Microseconds = 1,
    Milliseconds = 2,
    Seconds      = 3,
    Minutes      = 4,
    Hours        = 5,
}

time_in_nanoseconds := [Time_Scale] f32 {
    .Nanoseconds  = 1,
    .Microseconds = 1000,
    .Milliseconds = 1000,
    .Seconds      = 1000,
    .Minutes      = 60,
    .Hours        = 60,
}

Memory_Size :: enum {
    Bytes     = 0,
    Kilobytes = 1,
    Megabytes = 2,
    Gigabytes = 3,
    Petabytes = 4,
    Exabytes  = 5,
}

memory_size_in_bytes := [Memory_Size] umm {
    .Bytes     = 1,
    .Kilobytes = 1024,
    .Megabytes = 1024,
    .Gigabytes = 1024,
    .Petabytes = 1024,
    .Exabytes  = 1024,
}

with_basis :: proc (scale: $Scale/[$Enum] $T, basis_index: Enum) -> (result: Scale) {
    result = with_basis_as(scale, basis_index, type_of(scale[Enum(0)]))
    return result
}

with_basis_as :: proc (scale: $Scale/[$Enum] $T, basis_index: Enum, $as: typeid) -> (result: [Enum] as) {
    e0 := cast(Enum) 0
    e1 := cast(Enum) 1
    en := cast(Enum) N
    ei := basis_index
    
    for below in e0..<ei {
        result[below] = cast(as) 1.0 / cast(as) scale[below+e1]
    }
    
    result[ei] = cast(as) 1
    
    for above in ei+e1..<en {
        result[above] = cast(as) scale[above]
    }
    
    return result
}
 */
// @copypasta based on view_time_duration, 
// @todo(viktor): respect magnitude
view_magnitude :: proc (value: $T, magnitude := Magnitude.None, limit := Magnitude.None, show_limit_as_decimal := false, width: Maybe(u16) = nil, precision: Maybe(u8) = nil) -> (result: TempViews) {
    magnitude, limit := magnitude, limit
    rest := value
    
    begin_temp_views(width)
    
    if rest < 0 {
        append_temp_view(view_character('-'))
        rest = -rest
    }
    
    if magnitude == .None {
        magnitude = Magnitude.Unit when intrinsics.type_is_integer(T) else Magnitude.Nano
        for magnitude + auto_cast 1 <= .Exa && rest >= magnitude_to_factor(T, magnitude + auto_cast 1) {
            magnitude += auto_cast 1
        }
    }
    
    if rest == 0 {
        append_temp_view(view_integer(rest))
        append_temp_view(view_string(magnitude_to_symbol[magnitude]))
    } else {
        if limit == .None {
            limit = magnitude
        }
        
        for ; rest > 0 && (show_limit_as_decimal ? magnitude > limit : magnitude >= limit); magnitude -= auto_cast 1 {
            // @todo(viktor): simplify factors
            factor := magnitude_to_factor(T, magnitude)
            current := rest / factor
            rest     = rest % factor
            
            append_temp_view(view_integer(current))
            append_temp_view(view_string(magnitude_to_symbol[magnitude]))
        }
        
        if rest != 0 && show_limit_as_decimal {
            precision := precision
            if precision == nil {
                max_precision := cast(u8) (magnitude - .Nano) * 3
                precision = max_precision
            }
            factor := magnitude_to_factor(T, magnitude)
            s := cast(f64) rest / cast(f64) factor
            
            append_temp_view(view_float(s, precision = precision))
            append_temp_view(view_string(magnitude_to_symbol[magnitude]))
        }
    }
    
    result = end_temp_views()
    return result
}

// @todo(viktor): take some inspiration from magnitude/time_scale
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

// @todo(viktor): make precision and width parameters
view_percentage :: proc { view_percentage_parts, view_percentage_ratio }
view_percentage_parts :: proc(a, b: $N)  -> (result: View) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc(value: $F) -> (result: View) {
    result = view_float(value * 100, precision = 2, width = 2)
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
