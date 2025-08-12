#+no-instrumentation
package main

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"

to_rl_rectangle :: proc (rect: Rectangle2) -> (result: rl.Rectangle) {
    dim := get_dimension(rect)
    result.x = rect.min.x
    result.y = rect.min.y
    result.width  = dim.x
    result.height = dim.y
    return result
}

rl_color_to_v4 :: proc (color: rl.Color) -> (result: v4) {
    result = rgba_to_v4(cast([4]u8) color)
    return result
}
v4_to_rl_color :: proc (color: v4) -> (result: rl.Color) {
    result = cast(rl.Color) v4_to_rgba(color)
    return result
}

color_edit_flags_just_display: imgui.Color_Edit_Flags = .NoPicker | .NoOptions | .NoSmallPreview | .NoInputs | .NoTooltip | .NoSidePreview | .NoDragDrop
