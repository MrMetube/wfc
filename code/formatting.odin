#+vet !unused-procedures
package main

import "base:intrinsics"
import "core:time"

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

view_order_of_magnitude :: proc(value: $T, width: Maybe(u16) = 5, precision: Maybe(u8) = 2) -> (result: View, magnitude: string) {
    v: f64
    v, magnitude = order_of_magnitude(value)
    
    when intrinsics.type_is_integer(T) {
        precision := precision
        if v == cast(f64) value do precision = 0
        v = round(f64, v * 100) * 0.01
    }

    result = view_float(v, width = width, precision = precision)
    
    return result, magnitude
}

view_percentage :: proc { view_percentage_parts, view_percentage_ratio }
view_percentage_parts :: proc(a, b: $N)  -> (result: View) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc(value: $F) -> (result: View) {
    result = view_float(value * 100, precision = 0, width = 2)
    return result
}

TimeScale :: enum {
    Picos,
    Nanos,
    Micros,
    Millis,
    Seconds,
    Minutes,
    Hours,
}

view_time_duration :: proc (value: time.Duration, scale := TimeScale.Seconds, auto_detect := true, width: Maybe(u16) = nil, precision: Maybe(u8) = 0) -> (result: View, magnitude: string) {
    return view_duration(time.duration_seconds(value), scale = scale, auto_detect = auto_detect, width = width, precision = precision)
}
view_duration :: proc (value: f64, scale := TimeScale.Seconds, auto_detect := false, width: Maybe(u16) = nil, precision: Maybe(u8) = 0) -> (result: View, magnitude: string) {
    value, scale := value, scale
    
    if auto_detect {
        if value == 0 {
            // @note(viktor): nothing
        } else if value < 1 {
            for scale != .Picos && value < 1 {
                factor: f64 = 1000
                if scale == .Minutes || scale == .Hours do factor = 60
                
                value *= factor
                scale -= auto_cast 1
            }
        } else {
            for scale != .Hours {
                factor: f64 = 1000
                if scale == .Seconds || scale == .Minutes do factor = 60
                
                if value < factor do break
                
                value /= factor
                scale += auto_cast 1
            }
        }
    }
    
    switch scale {
      case .Hours:   magnitude = "h"
      case .Minutes: magnitude = "m"
      case .Seconds: magnitude = "s"
      case .Millis:  magnitude = "ms"
      case .Micros:  magnitude = "µs"
      case .Nanos:   magnitude = "ns"
      case .Picos:   magnitude = "ps"
    }
    
    switch scale {
      case .Hours:
        // @incomplete do hh:mm:ss
        result = view_float(value, width = width, precision = precision)
        if p, ok := precision.?; ok {
            if p != 0 {
                // also show minutes
                if p > 2 {
                    // also show seconds
                }
            }
        }
      case .Minutes:
        result = view_float(value, width = width, precision = precision)
        if p, ok := precision.?; ok {
            if p != 0 {
                // also show seconds
            }
        }
        
      case .Seconds, .Millis, .Micros, .Nanos, .Picos:
        result = view_float(value, width = width, precision = precision)
    }
    
    return result, magnitude
}