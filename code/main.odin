package main

import "core:mem"
import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

/* 
 - Remove all outdated and unused ideas
   - Support and Closeness are just boolean after all
 - Get some nice screenshots or process and results
 - simplify code and make an overview of the important parts
 - debug visualization to show graph as nodes and not voronoi but also with colors
   - and maybe interpolate between both?
 */
 
Screen_Size  :: v2i{1920, 1080}
Viewing_Size :: v2i{1024, 1024}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

paused: b32
wait_until_this_state: Maybe(Step_State)

cell_size_on_screen: v2

show_average_colors := true
show_neighbours     := false
show_voronoi_cells  := false
show_step_details   := false

cells_background_color := Orange

// @todo(viktor): visual dimension vs. point count for generates
dimension: v2i = {66, 66}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture,
}

viewing_step_detached: bool
viewing_step: Collapse_Step

////////////////////////////////////////////////

strictness: i32 = 3

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
    @(static) normals: [Direction] v2
    @(static) initialized: bool
    if !initialized {
        initialized = true
        for d in Direction {
            normals[d] = normalize(vec_cast(f32, Deltas[d]))
        }
    }
    
    return normals[direction]
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
Generate_Circle :: struct { spiral_strength: f32, radius: f32 }
Generate_Noise  :: struct { is_blue: bool }

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
}

wrap_in_extraction: [2] bool = true

desired_dimension := dimension
active_generate_index: int

////////////////////////////////////////////////

main :: proc () {
    when true {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        context.allocator = mem.tracking_allocator(&track)
        
        defer for _, leak in track.allocation_map {
            print("% leaked %\n", leak.location, view_memory_size(leak.size))
        }
    }
    
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
    if err != nil do print("Error reading dir %: %", image_dir, err)
    for info in infos {
        if info.type == .Regular {
            if strings.ends_with(info.name, file_type) {
                data, ferr := os2.read_entire_file(info.fullpath, context.allocator)
                if ferr != nil do print("Error reading file %:%\n", info.name, ferr)
                
                cstr := cast(cstring) raw_data(tprint("%", file_type, flags = { .AppendZero }))
                
                image := File { data = data }
                image.image   = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                images[info.name] = image
            }
        }
    }
    
    entropy := seed_random_series()
    collapse: Collapse
    collapse.search_metric = .Entropy
    
    generates: [dynamic] Generate_Kind
    
    defer {
        delete(generates)
        
        collapse_reset(&collapse)
        delete(collapse.steps)
        delete(collapse.states)
        delete(collapse.temp_state_values)
        
        delete(step_depth)
        
        for cell in collapse.cells do delete_cell(cell)
        delete(collapse.cells)
    }
    
    when false {
        append(&generates, Generate_Grid {
            center    = {.25, .25},
            radius = .24,
        })
        append(&generates, Generate_Grid {
            center    = {.25, .75},
            radius = .24,
            is_hex = true,
        })
        append(&generates, Generate_Grid {
            center    = {.75, .25},
            radius = .24,
            is_hex    = true,
        })
        append(&generates, Generate_Grid {
            center    = {.75, .75},
            radius = .24,
        })
    } else {
        append(&generates, Generate_Grid {
            center    = {.5, .5},
            radius = .51,
        })
    }
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
        
        for cell in collapse.cells {
            if .edge in cell.flags do continue
            color: v4
            
            if show_average_colors || .collapsed in cell.flags {
                color = cell.average_color
            }
            draw_cell(cell, color)
        }
        
        if show_voronoi_cells {
            for cell, index in collapse.cells {
                color_wheel := color_wheel
                color := v4_to_rl_color(color_wheel[(index) % len(color_wheel)])
                rl.DrawCircleV(world_to_screen(cell.p), 1, color)
                draw_cell_outline(cell, color)
            }
        }
        
        if show_neighbours {
            color := v4_to_rl_color(Emerald) 
            
            for cell in collapse.cells {
                center := world_to_screen(cell.p)
                rl.DrawCircleV(center, 3, color)
                for neighbour in cell.neighbours {
                    color := Emerald
                    color.a *= 0.5
                    end := world_to_screen(neighbour.cell.p)
                    rl.DrawLineEx(center, end, 1, v4_to_rl_color(color))
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
    }
}

restart :: proc (this_frame: ^Frame) {
    this_frame.tasks += { .rewind }
    this_frame.rewind_to = 0
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
        }
        
        if .extract_states in this_frame.tasks {
            this_frame.tasks -= { .extract_states }
            
            assert(this_frame.pixels != nil)
            
            collapse_reset(c)
            extract_states(c, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y, wrap_in_extraction)
            
            setup_cells(c)
            
            restart(this_frame)
        }
        
        if len(c.states) == 0 do break task_loop

        if .rewind in this_frame.tasks {
            spall_scope("Rewind")
            this_frame.tasks -= { .rewind }
            
            assert(this_frame.rewind_to != Invalid_Collapse_Step)
            
            is_restart := false
            if this_frame.rewind_to == 0 {
                is_restart = true
                for step in c.steps do delete_step(step)
                clear(&c.steps)
                append(&c.steps, Step {})
            } else {
                limit := cast(int) this_frame.rewind_to + 1
                if limit < len(c.steps) {
                    for step in c.steps[limit:] do delete_step(step)
                    resize(&c.steps, limit)
                }
            }
            
            current := peek(c.steps)
            assert(current.step == this_frame.rewind_to)
            
            if is_restart {
                spall_scope("Restart")
                
                total_duration = 0
                setup_cells(c)
                
                clear(&step_depth)
            } else {
                for &cell in c.cells {
                    for &state in cell.states {
                        if state.removed_at != Invalid_Collapse_Step && state.removed_at >= current.step {
                            state.removed_at = Invalid_Collapse_Step
                            cell.flags += { .dirty }
                            cell.flags -= { .collapsed }
                        }
                    }
                }
                
                switch current.state {
                  case .Search, .Pick: unreachable() // Can't rewind in this state.
                  case .Collapse:      current.state = .Pick
                  case .Propagate:     current.state = .Collapse
                }
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
                assert(current.step + 1 != Invalid_Collapse_Step)
                append(&c.steps, Step { step = current.step + 1 })
                fallthrough
              case .Continue: 
                next_frame.tasks += { .update }
                
              case .Rewind:
                next_frame.tasks += { .rewind }
                next_frame.rewind_to = max(0, result.rewind_to)
                
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

setup_cells :: proc (c: ^Collapse) {
    for &cell in c.cells {
        cell.flags += { .dirty }
        cell.flags -= { .collapsed }
        
        for &neighbour in cell.neighbours {
            neighbour.closeness = get_closeness(cell.p - neighbour.cell.p)
        }
        if len(cell.states) != len(c.states) {
            delete(cell.states)
            make(&cell.states, len(c.states))
        }
        
        for &state in cell.states {
            state.removed_at = Invalid_Collapse_Step
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
        generate_points(&points, area / auto_cast len(generates), generate)
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
            neighbour.closeness = get_closeness(cell.p - neighbour.cell.p)
        }
    }
    
    setup_cells(c)
}

generate_points :: proc(points: ^[dynamic] v2d, count: i32, kind: Generate_Kind) {
    // @note(viktor): We get numerical instability if points are perfectly vertically or horizontally aligned
    side := round(i32, square_root(cast(f32) count))
    entropy := seed_random_series()
    
    switch kind in kind {
      case Generate_Grid:
        total_region := rectangle_min_dimension(cast(v2d) 0, 1)
        
        radius := vec_cast(f64, kind.radius)
        angle := cast(f64) kind.angle
        center := vec_cast(f64, kind.center)
        rotated_radius := rotate(radius, angle)
        min := center - rotated_radius

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
        center := 0.5
        ring_count := cast(f64) side * .5
        min_count := 3.0
        max_count := cast(f64) count / ring_count
        min_radius := 0.01
        max_radius := cast(f64) kind.radius
        append(points, cast(v2d) center)
        for ring in 0..<ring_count {
            t := (ring + 1) / ring_count
            radius := linear_blend(min_radius, max_radius, t)
            
            point_count := linear_blend(min_count, max_count, t)
            point_count = max(3, point_count)
            for p in 0..<point_count {
                angle := Tau * p / point_count
                dir := arm(angle)
                point := center + dir * radius
                append(points, point)
            }
        }
        
    //   case .Spiral:
    //     center :: 0.5
    //     for index in 0..<count {
    //         angle := 1.6180339887 * cast(f64) index
    //         t := cast(f64) index / cast(f64) count
    //         radius := 0.5 - linear_blend(f64(0.05), 0.5, square(t))
    //         append(points, center + arm(angle) * radius)
    //     }
        
      case Generate_Noise:
        min_dist_squared := 1.0 / (Pi * f64(count))
        for _ in 0..<count {
            new_point: v2d
            
            valid := false
            for !valid {
                new_point = random_unilateral(&entropy, v2d)
                valid = true
                if kind.is_blue {
                    check: for point in points {
                        if length_squared(point - new_point) < min_dist_squared {
                            valid = false
                            break check
                        }
                    }
                }
            }
            
            append(points, new_point)
        }
    }
}

draw_cell :: proc (cell: Cell, color: v4) {
    if len(cell.points) == 0 do return
    
    @(static) buffer: [dynamic] v2 // @leak
    clear(&buffer)
    
    append(&buffer, world_to_screen(cell.p))
    
    for point in cell.points {
        append(&buffer, world_to_screen(point))
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