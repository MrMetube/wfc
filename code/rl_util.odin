package main

import rl "vendor:raylib"

to_rl_rectangle :: proc (rect: Rectangle2) -> (result: rl.Rectangle) {
    dim := get_dimension(rect)
    result.x = rect.min.x
    result.y = rect.min.y
    result.width  = dim.x
    result.height = dim.y
    return result
}