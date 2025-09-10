package main

import "core:mem"
import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

Screen_Size :: v2i{1920, 1080}
Viewing_Size :: v2i{1024, 1024}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

paused: b32
wait_until_this_state: Maybe(Step_State)

cell_size_on_screen: v2

render_wavefunction_as_average := true
show_neighbours                := false
show_voronoi_cells             := true
highlight_step                 := false
preview_angles                 := false

viewing_closeness_mask: Direction_Vector = 1
viewing_render_target: rl.RenderTexture
viewing_group: ^Color_Group
color_groups:  [dynamic] Color_Group
Color_Group :: struct {
    color: v4,
    ids:   [/* State_Id */] b32,
}


cells_background_color := DarkGreen
cells_background_hue_t: f32

dimension: v2i = {66, 66}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture,
}

viewing_step_detached: bool
viewing_step: Collapse_Step

////////////////////////////////////////////////

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

generates: [dynamic] Generate_Kind
Generate_Kind :: union {
    Generate_Grid,
    Generate_Circle,
    Generate_Noise,
}

Generate_Grid   :: struct { center, radius: v2, angle: f32, is_hex: bool }
Generate_Circle :: struct { spiral_strength: f32 }
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

desired_N: i32 = N
desired_dimension     := dimension
active_generate_index: int

////////////////////////////////////////////////

//    t - description - overlap of the 8 cardinal directions
//   ~0 - Cosine      - large
// ~1.5 - Linear      - none
t_directional_strictness: f32 = .75

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
        
        cells.allocator = context.allocator
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
    
    append(&generates, Generate_Grid {
        center    = {.5, .5},
        radius = .5,
    })
    append(&generates, Generate_Grid {
        center    = {.5, .5},
        radius = .2,
    })
    
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
    }
    active_generate_index = 0
    
    pre := Frame { tasks = { .setup_grid } }
    do_tasks_in_order(&pre, &collapse, &entropy)
    
    defer {
        collapse_reset(&collapse)
        delete(collapse.steps)
        delete(collapse.states)
        delete(collapse.temp_state_values)
        
        delete(step_depth)
        
        for group in color_groups do delete(group.ids)
        delete(color_groups)
        
        for cell in cells do delete_cell(cell)
        delete(cells)
    }
    
    viewing_render_target = rl.LoadRenderTexture(Viewing_Size.x, Viewing_Size.y)
        
    this_frame: Frame
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rl_imgui_new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        this_frame.pixels           = nil
        this_frame.pixels_dimension = {}
        
        ui(&collapse, images, &this_frame)
        
        ////////////////////////////////////////////////
        // Update 
        
        do_tasks_in_order(&this_frame, &collapse, &entropy)
        
        ////////////////////////////////////////////////
        // Render
        
        render_neighbourhood(&collapse)
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        current := len(collapse.steps) != 0 ? peek(collapse.steps)^ : {}
        
        { // Background
            cells_background_hue_t += rl.GetFrameTime() * DegreesPerRadian
            if cells_background_hue_t >= 360 do cells_background_hue_t -= 360
            
            hsv := rl.ColorToHSV(v4_to_rl_color(cells_background_color))
            hue := hsv.x + cells_background_hue_t
            color := rl.ColorFromHSV(hue, hsv.y, hsv.z)
            
            background := rectangle_min_dimension(v2{}, vec_cast(f32, dimension))
            rl.DrawRectangleRec(world_to_screen(background), color)
        }
        
        for cell in cells {
            if .edge in cell.flags do continue
            color: v4
            
            if render_wavefunction_as_average || .collapsed in cell.flags {
                color = cell.average_color
            }
            draw_cell(cell, color)
        }
        
        if show_voronoi_cells {
            for cell, index in cells {
                color_wheel := color_wheel
                color := v4_to_rl_color(color_wheel[(index) % len(color_wheel)])
                rl.DrawCircleV(world_to_screen(cell.p), 1, color)
                draw_cell_outline(cell, color)
            }
        }
        
        if show_neighbours {
            color := v4_to_rl_color(Emerald) 
            
            for cell in cells {
                center := world_to_screen(cell.p)
                rl.DrawCircleV(center, 3, color)
                for neighbour in cell.neighbours {
                    color := Emerald
                    if .edge in neighbour.cell.flags do color = Salmon
                    
                    color.a *= 0.5
                    end := world_to_screen(neighbour.cell.p)
                    rl.DrawLineEx(center, end, 2, v4_to_rl_color(color))
                }
            }
        }
        
        if highlight_step && len(collapse.steps) > 0 {
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

do_tasks_in_order :: proc (this_frame: ^Frame, c: ^Collapse, entropy: ^RandomSeries) {
    spall_proc()
    
    next_frame: Frame
    
    update_start := time.now()
    update_limit := round(time.Duration, TargetFrameTime * cast(f64) time.Second)
    task_loop: for this_frame.tasks != {} && time.since(update_start) < update_limit {
        if .setup_grid in this_frame.tasks {
            this_frame.tasks -= { .setup_grid }
            
            if len(generates) != 0 {
                setup_grid(c, entropy)
                
                restart(this_frame)
            }
        }
        
        if .extract_states in this_frame.tasks {
            this_frame.tasks -= { .extract_states }
            
            assert(this_frame.pixels != nil)
            
            N = desired_N
            collapse_reset(c)
            extract_states(c, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
            
            // Extract color groups
            for state in c.states {
                color := state.middle
                
                group: ^Color_Group
                for &it in color_groups {
                    if it.color == color {
                        group = &it
                        break
                    }
                }
                
                if group == nil {
                    append(&color_groups, Color_Group { color = color })
                    group = &color_groups[len(color_groups)-1]
                    make(&group.ids, len(c.states))
                }
                
                group.ids[state.id] = true
            }
            
            setup_cells(c)
            
            restart(this_frame)
        }
        
        if len(c.states) == 0 do break task_loop

        if .rewind in this_frame.tasks {
            spall_scope("Rewind")
            this_frame.tasks -= { .rewind }
            
            assert(this_frame.rewind_to != Invalid_Collapse_Step)
            
            when false {
                current := len(c.steps) > 0 ? peek(c.steps)^ : {}
                print("Rewinding to % from %\n", this_frame.rewind_to, current.step)
                assert(this_frame.rewind_to != Invalid_Collapse_Step)
            }
            
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
            
            // print("Is Restart %\n", is_restart)
            
            if is_restart {
                spall_scope("Restart")
                
                total_duration = 0
                setup_cells(c)
                
                clear(&step_depth)
            } else {
                for &cell in cells {
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
            
            // print("Update with %\n", peek(c.steps).state)
            
            if c.states != nil {
                current := peek(c.steps)
                
                this_update_start := time.now()
                result, rewind_to := step_update(c, entropy)
                
                switch result {
                  case .Done: break task_loop
                  case .Ok:   next_frame.tasks += { .update }
                  
                  case .Rewind: 
                    next_frame.tasks += { .rewind }
                    next_frame.rewind_to = rewind_to != Invalid_Collapse_Step ? rewind_to : max(0, current.step - 1)
                }
                
                total_duration += time.since(this_update_start)
            }
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
    for &cell in cells {
        if len(cell.states) != len(c.states) {
            delete(cell.states)
            make(&cell.states, len(c.states))
        }
        
        cell.flags += { .dirty }
        cell.flags -= { .collapsed }
        
        for &state, index in cell.states {
            state.id = cast(State_Id) index
            state.removed_at = Invalid_Collapse_Step
        }
        
        for &neighbour in cell.neighbours {
            neighbour.closeness = get_closeness(cell.p - neighbour.cell.p)
        }
    }
}

setup_grid :: proc (c: ^Collapse, entropy: ^RandomSeries) {
    ratio := vec_cast(f32, Screen_Size-100) / vec_cast(f32, dimension)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    for cell in cells do delete_cell(cell)
    clear(&cells)
    
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
        append(&cells, cell)
    }
    
    for &cell, cell_index in cells {
        voronoi := voronoi_cells[cell_index]
        make(&cell.neighbours, len(voronoi.neighbour_indices))
        
        for neighbour_index, index in voronoi.neighbour_indices {
            neighbour := &cell.neighbours[index]
            neighbour.cell = &cells[neighbour_index]
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
        max_radius := 0.5
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

render_neighbourhood :: proc (c: ^Collapse) {
    rl.BeginTextureMode(viewing_render_target)
    rl.ClearBackground({0x1F, 0x31, 0x4B, 0xFF})
    
    // @todo(viktor): Confirm that the directions are correctly mapped to vectors and displayed correctly on the circle
    if viewing_group != nil {
        center := Viewing_Size / 2
        p := vec_cast(f32, center)
        
        size := cast(f32) Viewing_Size.x / cast(f32) ((len(color_groups)+1) * 2 + 1) * 0.75
        
        samples := 180
        turns := cast(f32) samples
        rads_per_sample := Tau / turns
        
        for comparing_group, group_index in color_groups {
            total_supports := make([] f32, samples, context.temp_allocator)
            
            max_support: f32
            for sample in 0..<samples {
                turn := cast(f32) sample
                
                sampling_direction := arm(turn * rads_per_sample)
                closeness := get_closeness(sampling_direction)
                closeness *= viewing_closeness_mask
                for vok, vid in viewing_group.ids do if vok {
                    for cok, cid in comparing_group.ids do if cok {
                        total_supports[sample] += get_support_amount(c, cast(State_Id) vid, cast(State_Id) cid, closeness)
                    }
                }
                max_support = max(max_support, total_supports[sample])
            }
            
            for sample in 0..<samples {
                ring_size    := 0.9 * size
                ring_padding := 0.1 * size
                
                center_size  := ring_size
                
                turn := cast(f32) sample
                
                sampling_direction := arm(turn * rads_per_sample)
                
                total_support := total_supports[sample]
                alpha := safe_ratio_0(total_support, max_support)
                color := comparing_group.color
                color *= alpha
                
                center := atan2(-sampling_direction.y, sampling_direction.x) * DegreesPerRadian
                width: f32 = 360. / turns
                start := center - width * .5
                stop  := center + width * .5
                
                inner := (center_size +  ring_size) + cast(f32) group_index * ring_size + ring_padding
                outer := inner + ring_size
                
                rl.DrawRing(p, inner, outer, start, stop, 0, v4_to_rl_color(color))
            }
        }
        
        rl.DrawCircleV(p, size, v4_to_rl_color(viewing_group.color))
    }
    rl.EndTextureMode()
    
    { // Invert y
        image := rl.LoadImageFromTexture(viewing_render_target.texture)
        pixels := slice_from_parts_cast(rl.Color, image.data, image.width * image.height)
        for row in 0..<image.height/2 {
            rev := image.height-1-row
            for col in 0..<image.width {
                a := &pixels[row * image.width + col]
                b := &pixels[rev * image.width + col]
                swap(a, b)
            }
        }
        
        rl.UpdateTexture(viewing_render_target.texture, image.data)
    }
}