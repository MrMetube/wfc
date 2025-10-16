package main

import "core:fmt"
import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

/* @todo(viktor):
 - Remove all outdated and unused ideas
 - Get some nice screenshots of process and results
 - simplify code and make an overview of the important parts
 */

print :: fmt.printf
tprint :: fmt.tprintf
ctprint :: fmt.ctprintf

Screen_Size  :: v2i{1920, 1080}
Viewing_Size :: v2i{1024, 1024}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

voronoi_shape_t: f32 = 1
cooling_chance: f32 = 0.7
heating_chance: f32 = 0.1

total_duration: time.Duration

paused: b32
wait_until_this_state: Maybe(Step_State)

cell_size_on_screen: v2

show_cells          := true
show_average_colors := true
show_voronoi_cells  := false

show_step_details   := false
show_heat           := true

// @todo(viktor): visual dimension vs. point count for generates
dimension: v2i = {100, 100}

cells_background_color := V4(cast(v3) 0.4, 1)

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture,
}

viewing_step_detached: bool
viewing_step: Collapse_Step

////////////////////////////////////////////////


// @todo(viktor): min max desired and gradual cooldown over time/steps?
base_heat: i32 = 1

Direction :: enum {
    E, NE, N, NW, W, SW, S, SE,
}

Deltas := [Direction] v2i { 
    .E  = { 1, 0},
    .NE = { 1, 1},
    .N  = { 0, 1},
    .NW = {-1, 1},
    .W  = {-1, 0},
    .SW = {-1,-1},
    .S  = { 0,-1},
    .SE = { 1,-1},
}

normalized_direction :: proc (direction: Direction) -> (result: v2) {
    delta := vec_cast(f32, Deltas[direction])
    result = normalize(delta)
    return result
}

opposite_direction :: proc (direction: Direction) -> (result: Direction) {
    count := len(Direction)
    result = cast(Direction) ((cast(int) direction + count/2) % count)
    return result
}

////////////////////////////////////////////////

Generate_Kind :: union {
    Generate_Grid,
    Generate_Circle,
    Generate_Noise,
}

Generate_Grid   :: struct { center, radius: v2, angle: f32, is_hex: bool }
Generate_Circle :: struct { radius: f32, spiral_size: f32, }
Generate_Noise  :: struct { center, radius: v2, is_blue: bool  }

////////////////////////////////////////////////

Task :: enum {
    setup_grid, 
    extract_states, 
    rewind, 
    update,
}

Frame :: struct {
    tasks: bit_set[Task],
    
    // extract states
    pixels:           [] rl.Color,
    pixels_dimension: v2i,
    
    // rewind
    rewind_to: Collapse_Step,
    reset_heat: bool,
}

wrap_when_extracting: [2] bool = true

desired_dimension := dimension
active_generate_index: int

////////////////////////////////////////////////

main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    init_spall()
    
    rl_imgui_init()
    
    images: map[string] File
    defer {
        for _, file in images do delete(file.data)
        delete(images)
    }
    
    image_dir := "./images"
    file_type := ".png"
    infos, err := os2.read_directory_by_path(image_dir, 0, context.temp_allocator)
    if err != nil do print("Error reading dir %v: %v", image_dir, err)
    for info in infos {
        if info.type == .Regular {
            if strings.ends_with(info.name, file_type) {
                data, ferr := os2.read_entire_file(info.fullpath, context.allocator)
                if ferr != nil do print("Error reading file %v:%v\n", info.name, ferr)
                
                cstr := ctprint("%v", file_type)
                
                image := File { data = data }
                image.image   = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                images[info.name] = image
            }
        }
    }
    
    entropy := seed_random_series()
    collapse: Collapse
    
    generates: [dynamic] Generate_Kind
    
    defer {
        delete(generates)
        
        collapse_reset(&collapse)
        delete(collapse.steps)
        delete(collapse.states)
        
        delete(step_depth)
        
        for cell in collapse.cells do delete_cell(cell)
        delete(collapse.cells)
    }
    
    preset_0(&generates)
    active_generate_index = 0
    
    // @todo(viktor): Can we not rely on this pregen?
    pre := Frame { tasks = { .setup_grid } }
    do_tasks_in_order(&pre, &collapse, &entropy, &generates)
    
    this_frame: Frame
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rl_imgui_new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        this_frame.pixels           = nil
        this_frame.pixels_dimension = {}
        
        ui(&collapse, images, &this_frame, &generates)
        
        ////////////////////////////////////////////////
        // Update 
        
        do_tasks_in_order(&this_frame, &collapse, &entropy, &generates)
        
        ////////////////////////////////////////////////
        // Render
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        current := len(collapse.steps) != 0 ? peek(collapse.steps)^ : {}
        
        { // Background
            color := v4_to_rl_color(cells_background_color)
            background := rectangle_min_dimension(v2{}, vec_cast(f32, dimension))
            rl.DrawRectangleRec(world_to_screen(background), color)
        }
        
        if show_cells {
            spall_begin("draw cells")
            for &cell in collapse.cells {
                if .edge in cell.flags do continue
                
                if show_average_colors || .collapsed in cell.flags {
                    color := calculate_average_color(&collapse, &cell)
                    draw_cell(cell, color)
                }
            }
            spall_end()
        }
        
        if show_voronoi_cells {
            for cell, index in collapse.cells {
                color_wheel := color_wheel
                color := v4_to_rl_color(color_wheel[(index) % len(color_wheel)])
                rl.DrawCircleV(world_to_screen(cell.p), 1, color)
                draw_cell_outline(cell, color)
            }
        }
        
        // @todo(viktor): Find a way to determine if a lattice is "solveable" or if it has cells that will need "areal" rules, rules that allow same states in all or most directions
        if show_heat {
            for cell in collapse.cells {
                center := world_to_screen(cell.p)
                
                for neighbour in cell.neighbours {
                    color := Blue
                    
                    if neighbour.heat < 5 {
                        color = linear_blend(Blue, Jasmine, cast(f32) (neighbour.heat) / 5)
                    } else {
                        color = linear_blend(Jasmine, Red, cast(f32) (neighbour.heat - 5) / (8-5))
                    }
                    
                    end := world_to_screen(neighbour.cell.p)
                    rl.DrawLineEx(center, end, 2, v4_to_rl_color(color))
                }
            }
        }
        
        if show_step_details && len(collapse.steps) > 0 {
            viewed := collapse.steps[min(viewing_step, current.step)]
            for cell in viewed.found {
                draw_cell_outline(cell^, rl.GREEN)
            }
            
            start := viewed.step == current.step ? viewed.changes_cursor : 0
            for change in viewed.changes[start:] do if change != nil {
                draw_cell_outline(change^, rl.YELLOW)
            }
            
            if viewed.to_be_collapsed != nil {
                draw_cell_outline(viewed.to_be_collapsed^, rl.ORANGE)
            }
        }
    
        rl_imgui_render()
        rl.EndDrawing()
        spall_flush()
    }
}

restart :: proc (this_frame: ^Frame, reset_heat := false) {
    this_frame.tasks += { .rewind }
    this_frame.rewind_to = 0
    this_frame.reset_heat = reset_heat
}

do_tasks_in_order :: proc (this_frame: ^Frame, c: ^Collapse, entropy: ^RandomSeries, generates: ^[dynamic] Generate_Kind) {
    spall_proc()
    
    next_frame: Frame
    
    update_start := time.now()
    update_limit := round(time.Duration, TargetFrameTime * cast(f64) time.Second)
    task_loop: for this_frame.tasks != {} && time.since(update_start) < update_limit {
        if .setup_grid in this_frame.tasks {
            this_frame.tasks -= { .setup_grid }
            
            if len(generates) != 0 {
                setup_grid(c, entropy, generates)
                
                restart(this_frame)
            }
            clear(&step_depth)
        }
        
        if .extract_states in this_frame.tasks {
            this_frame.tasks -= { .extract_states }
            
            assert(this_frame.pixels != nil)
            
            collapse_reset(c)
            extract_states(c, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y, wrap_when_extracting)
            
            setup_cells(c, true)
            
            restart(this_frame)
            clear(&step_depth)
        }
        
        if len(c.states) == 0 do break task_loop

        if .rewind in this_frame.tasks {
            spall_scope("Rewind")
            this_frame.tasks -= { .rewind }
            
            current := len(c.steps) > 0 ? peek(c.steps) : {}
            
            is_restart := false
            if this_frame.rewind_to == 0 {
                is_restart = true
                for step in c.steps do delete_step(step)
                clear(&c.steps)
                append(&c.steps, Step {})
            } else if this_frame.rewind_to == current.step {
                switch current.state {
                  case .Search: unreachable()
                  case .Pick:
                    current.state = .Search
                    
                  case .Collapse:
                    current.state = .Pick
                    
                  case .Propagate:
                    clear(&current.changes)
                    current.changes_cursor = 0
                    current.state = .Collapse
                }
            } else {
                limit := cast(int) this_frame.rewind_to + 1
                if limit < len(c.steps) {
                    for step in c.steps[limit:] do delete_step(step)
                    resize(&c.steps, limit)
                }
            }
            
            current = peek(c.steps)
            assert(current.step == this_frame.rewind_to)
            
            if is_restart {
                spall_scope("Restart")
                
                total_duration = 0
                setup_cells(c, this_frame.reset_heat)
            } else {
                for &cell in c.cells {
                    for &state in cell.states {
                        if state.removed && state.at >= current.step {
                            state = {}
                            cell.flags += { .dirty }
                            cell.flags -= { .collapsed }
                        }
                    }
                }
                
                // @note(viktor): There are no choices in Propagation so be back one state
                if current.state == .Propagate do current.state = .Collapse
                else do unreachable()
            }
            
            next_frame.tasks += { .update }
        }
        
        if .update in this_frame.tasks {
            this_frame.tasks -= { .update }
            
            assert(c.states != nil)
            
            current := peek(c.steps)
            
            this_update_start := time.now()
            result := step_update(c, entropy, current)
            
            switch result.kind {
              case .Complete: break task_loop
              case .Next:     
                append(&c.steps, Step { step = current.step + 1 })
                append(&step_depth, cast(f32) current.step)
                fallthrough
              case .Continue: 
                next_frame.tasks += { .update }
                
              case .Rewind:
                next_frame.tasks += { .rewind }
                next_frame.rewind_to = max(0, result.rewind_to)
                append(&step_depth, cast(f32) current.step)
            }
            
            total_duration += time.since(this_update_start)
        }
        
        if !paused {
            this_frame ^= next_frame
            next_frame = {}
        } else {
            if wait_until_this_state != nil {
                if wait_until_this_state != peek(c.steps).state {
                    this_frame ^= next_frame
                } else {
                    wait_until_this_state = nil
                }
            }
        }        
    }
}

setup_cells :: proc (c: ^Collapse, is_total_reset: bool) {
    for &cell in c.cells {
        cell.flags += { .dirty }
        cell.flags -= { .collapsed }
        
        for &neighbour in cell.neighbours {
            if is_total_reset {
                neighbour.heat = cast(u8) base_heat
            }
            neighbour.mask = get_direction_mask(cell.p - neighbour.cell.p, neighbour.heat)
        }
        if len(cell.states) != len(c.states) {
            delete(cell.states)
            make(&cell.states, len(c.states))
        }
        
        for &state in cell.states {
            state = {}
        }
    }
}

setup_grid :: proc (c: ^Collapse, entropy: ^RandomSeries, generates: ^[dynamic] Generate_Kind) {
    ratio := vec_cast(f32, Screen_Size-100) / vec_cast(f32, dimension)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    for cell in c.cells do delete_cell(cell)
    clear(&c.cells)
    
    area := dimension.x * dimension.y
    points := make([dynamic] v2d, 0, area, context.temp_allocator)
    for generate in generates {
        generate_points(&points, area, generate)
    }
    
    dt: Delauney_Triangulation
    begin_triangulation(&dt, points[:], allocator = context.temp_allocator)
    complete_triangulation(&dt)
    voronoi_cells := end_triangulation_voronoi_cells(&dt)
    
    for voronoi in voronoi_cells {
        dim := vec_cast(f64, dimension)
        cell: Cell
        cell.p = vec_cast(f32, voronoi.center * dim)
        
        make(&cell.points, len(voronoi.points))
        for point, index in voronoi.points {
            p := vec_cast(f32, point * dim)
            cell.points[index] = p
        
            inside: b32
            
            for generate in generates {
                switch kind in generate {
                  case Generate_Grid:
                    region := rec_cast(f64, rectangle_center_half_dimension(kind.center, kind.radius))
                    region = scale_radius(region, dim)
                    inside ||= contains(region, point)
                  
                  case Generate_Noise:
                    dimension := 1.0
                    region := rectangle_center_dimension(v2d{0.5, 0.5}, dimension)
                    inside = contains(region, point)
                        
                  case Generate_Circle:
                    center: v2d = 0.5
                    radius := 0.5 - 0.001
                    inside = length_squared(point - center) < square(radius)
                }
            }
            
            if !inside {
                cell.flags +=  { .edge }
            }
        }
        
        if voronoi.is_edge {
            cell.flags +=  { .edge }
        }
        
        append(&c.cells, cell)
    }
    
    for &cell, cell_index in c.cells {
        voronoi := voronoi_cells[cell_index]
        make(&cell.neighbours, len(voronoi.neighbour_indices))
        
        for neighbour_index, index in voronoi.neighbour_indices {
            neighbour := &cell.neighbours[index]
            neighbour.cell = &c.cells[neighbour_index]
            neighbour.heat = cast(u8) base_heat
        }
    }
    
    setup_cells(c, true)
}

generate_points :: proc(points: ^[dynamic] v2d, count: i32, kind: Generate_Kind) {
    // @note(viktor): We get numerical instability if points are perfectly vertically or horizontally aligned
    entropy := seed_random_series()
    
    count := count
    
    total_region := rectangle_min_dimension(cast(v2d) 0, 1)
    
    switch kind in kind {
      case Generate_Grid:
        radius := vec_cast(f64, kind.radius)
        angle := cast(f64) kind.angle
        center := vec_cast(f64, kind.center)
        rotated_radius := rotate(radius, angle)
        min := center - rotated_radius
        
        count = round(i32, cast(f64) count * (radius.x * radius.y))
        side := round(i32, square_root(cast(f32) count))
        
        #reverse for p, index in points {
            delta := p - center
            delta = rotate(delta, angle)
            if abs(delta.x) < radius.x && abs(delta.y) < radius.y {
                unordered_remove(points, index)
            }
        }
        
        inv_side := 1. / cast(f64) side
        delta_x := rotate(v2d {radius.x*2, 0}, angle) * inv_side
        delta_y := rotate(v2d {0, radius.y*2}, angle) * inv_side
        
        y_count := side
        if kind.is_hex {
            factor := sin(cast(f64) Tau / 6)
            y_count = round(i32, cast(f64) y_count * (1 / factor))
            delta_y *= factor
        }
        
        offset := 0.00001
        for dx in 0..<side {
            for dy in 0..<y_count {
                x := cast(f64) dx
                y := cast(f64) dy
                if kind.is_hex {
                    if dy % 2 == 0 do x += cos(cast(f64) Tau / 6)
                }
                sp := v2d{x, y}
                
                p := min + sp.x * delta_x + sp.y * delta_y
                
                p += random_bilateral(&entropy, v2d) * offset
                
                if contains_inclusive(total_region, p) {
                    append(points, p)
                }
            }
        }
        
      case Generate_Circle:
        min_radius := 0.01
        max_radius := cast(f64) kind.radius
        count = round(i32, cast(f64) count * (square(max_radius)*Pi))
        side := round(i32, square_root(cast(f32) count))
        
        center := 0.5
        ring_count := cast(f64) side * .5
        min_count := 3.0
        max_count := cast(f64) count / ring_count
        append(points, cast(v2d) center)
        
        #reverse for p, index in points {
            delta := p - center
            if length_squared(delta) < square(max_radius) {
                unordered_remove(points, index)
            }
        }
        
        for ring in 0..<ring_count {
            t := (ring) / ring_count
            next_t := (ring + 1) / ring_count
            radius := linear_blend(min_radius, max_radius, t)
            next_radius := linear_blend(min_radius, max_radius, next_t * cast(f64) kind.spiral_size)
            
            point_count := linear_blend(min_count, max_count, t)
            point_count = max(3, point_count)
            for p in 0..<point_count {
                angle := Tau * p / point_count
                dir := arm(angle)
                point := center + dir * linear_blend_e(radius, next_radius, p / point_count)
                if contains_inclusive(total_region, point) {
                    append(points, point)
                }
            }
        }
        
      case Generate_Noise:
        radius := vec_cast(f64, kind.radius)
        center := vec_cast(f64, kind.center)
        count = round(i32, cast(f64) count * (radius.x * radius.y))
        
        min_dist_squared := 1.0 / (Pi * f64(count))
        for _ in 0..<count {
            new_point: v2d
            
            valid := false
            attemps := 100
            for !valid && attemps > 0 {
                new_point = center + random_bilateral(&entropy, v2d) * radius
                valid = true
                
                if kind.is_blue {
                    check: for point in points {
                        if length_squared(point - new_point) < min_dist_squared {
                            valid = false
                            break check
                        }
                    }
                }
                
                attemps -= 1
            }
            
            append(points, new_point)
        }
    }
}

preset_0 :: proc (generates: ^[dynamic] Generate_Kind) {
    clear(generates)
    append(generates, Generate_Grid {
        center    = {.5, .5},
        radius = .51,
    })
}

preset_2 :: proc (generates: ^[dynamic] Generate_Kind) {
    clear(generates)
    append(generates, Generate_Grid {
        center    = {.5, .5},
        radius = .51,
    })
    
    append(generates, Generate_Noise {
        center = .5,
        radius = {0.15, 0.51},
    })
}
preset_3 :: proc (generates: ^[dynamic] Generate_Kind) {
    clear(generates)
    append(generates, Generate_Grid {
        center    = {.5, .5},
        radius = .51,
    })
    
    append(generates, Generate_Noise {
        center = .5,
        radius = {0.51, 0.15},
    })
}

preset_1 :: proc (generates: ^[dynamic] Generate_Kind) {
    clear(generates)
    append(generates, Generate_Grid {
        center    = {.25, .25},
        radius = .24,
    })
    append(generates, Generate_Grid {
        center    = {.25, .75},
        radius = .24,
        is_hex = true,
    })
    append(generates, Generate_Grid {
        center    = {.75, .25},
        radius = .24,
        is_hex    = true,
    })
    append(generates, Generate_Grid {
        center    = {.75, .75},
        radius = .24,
    })
}

////////////////////////////////////////////////

draw_cell :: proc (cell: Cell, color: v4) {
    if len(cell.points) == 0 do return
    
    @(static) buffer: [dynamic] v2 // @leak
    clear(&buffer)
    
    min_radius := +Infinity
    for point in cell.points {
        radius := length(point - cell.p)
        if radius < min_radius {
            min_radius = radius
        }
    }
    min_radius *= 0.5
    
    append(&buffer, world_to_screen(cell.p))
    
    for point in cell.points {
        p := point
        
        p_min := cell.p + normalize(p - cell.p) * min_radius
        p = linear_blend(p_min, p, voronoi_shape_t)
        append(&buffer, world_to_screen(p))
    }
    append(&buffer, buffer[1])
    
    rl.DrawTriangleFan(raw_data(buffer), auto_cast len(buffer), v4_to_rl_color(color))
}
draw_cell_outline :: proc (cell: Cell, color: rl.Color) {
    if len(cell.points) == 0 do return
    
    @(static) buffer: [dynamic] v2 // @leak
    clear(&buffer)
    
    for point in cell.points {
        append(&buffer, world_to_screen(point))
    }
    append(&buffer, buffer[0])
    
    rl.DrawLineStrip(raw_data(buffer), auto_cast len(buffer), color)
}

world_to_screen :: proc { world_to_screen_rec, world_to_screen_vec, world_to_screen_v2i }
world_to_screen_rec :: proc (world: Rectangle($T)) -> (screen: rl.Rectangle) {
    wmin := world_to_screen(world.min)
    wmax := world_to_screen(world.max)
    screen.x = wmin.x
    screen.y = wmax.y
    dim := abs_vec(wmax - wmin)
    screen.width  = dim.x
    screen.height = dim.y
    return screen
}

world_to_screen_v2i :: proc (world: v2i) -> (screen: v2) {
    screen = world_to_screen(vec_cast(f32, world))
    return screen
}
world_to_screen_vec :: proc (world: v2) -> (screen: v2) {
    screen_size := vec_cast(f32, Screen_Size)
    screen_min := v2{0, screen_size.y}
    
    grid_size := cell_size_on_screen * vec_cast(f32, dimension)
    grid_min := screen_min + {1,-1} * 0.5 * (screen_size - grid_size)
    
    screen = grid_min + {1,-1} * (world * cell_size_on_screen)
    
    return screen
}