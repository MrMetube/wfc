package main

import "core:mem"
import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

Screen_Size :: v2i{1600, 900}
Viewing_Size :: v2i{1024, 1024}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

paused: b32
desired_update_state: Maybe(Step_State)

cell_size_on_screen: v2

show_neighbours                := false
show_voronoi_cells             := false
render_wavefunction_as_average := true
highlight_step                 := true

viewing_render_target: rl.RenderTexture
viewing_group: ^Color_Group
color_groups:  [dynamic] Color_Group
Color_Group :: struct {
    color: rl.Color,
    ids:   [/* State_Id */] b32,
}

cells_background_color := DarkGreen
cells_background_hue_t: f32

dimension: v2i = {66, 66}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture2D,
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

opposite_direction :: proc (direction: Direction) -> (result: Direction) {
    count := len(Direction)
    result = cast(Direction) ((cast(int) direction + count/2) % count)
    return result
}

// 0 Cosine 1 Linear
// @todo(viktor): even linear seems to overlap too much to get clean output, next after linear would be nearest or something with steeper falloff
view_mode_t: f32 = 0.5

////////////////////////////////////////////////

search_metric := Search_Metric.Entropy

Generate_Kind :: enum {
    Grid,
    Shifted_Grid,
    Diamond_Grid,
    Hex_Vertical,
    Hex_Horizontal,
    Spiral,
    Random,
    BlueNoise,
}
generate_kind: Generate_Kind = .Grid

////////////////////////////////////////////////

Task :: enum {
    setup_grid, 
    extract_states, 
    rewind, 
    update,
}

Frame :: struct {
    tasks: bit_set[Task],
    
    // setup grid
    desired_dimension:      v2i,
    
    // extract states
    pixels:           [] rl.Color,
    pixels_dimension: v2i,
    
    // rewind
    rewind_to: enum { Previous_Choice, Viewed, Start },
}

desired_N:  i32 = N

main :: proc () {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)

    defer for _, leak in track.allocation_map {
        print("% leaked %\n", leak.location, view_memory_size(leak.size))
    }
    
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    init_spall()
    
    rl_imgui_init()
    
    arena: Arena
    init_arena(&arena, make([]u8, 512*Megabyte))
    defer delete(arena.storage)
    
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
                
                cstr := cast(cstring) raw_data(tprint("%\u0000", file_type))
                
                image := File { data = data }
                image.image   = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                images[info.name] = image
            }
        }
    }
    
    
    entropy := seed_random_series(7458)
    collapse: Collapse
    pre := Frame { tasks = { .setup_grid } }
    do_tasks_in_order(&pre, &collapse, &entropy, &arena)
    
    defer {
        collapse_reset(&collapse)
        delete(collapse.values)
        delete(collapse.steps)
        delete(collapse.states)
        delete(collapse.temp_state_values)
        
        delete(step_depth)
        
        for group in color_groups do delete(group.ids)
        delete(color_groups)
        
        for cell in cells {
            delete_cell(cell)
        }
        delete(cells)
    }
    
    viewing_render_target = rl.LoadRenderTexture(Viewing_Size.x, Viewing_Size.y)
    
    this_frame: Frame
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rl_imgui_new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        this_frame.desired_dimension      = dimension
        this_frame.pixels                 = nil
        this_frame.pixels_dimension       = {}
        
        ui(&collapse, images, &this_frame)
        
        if dimension != this_frame.desired_dimension {
            dimension = this_frame.desired_dimension
            this_frame.tasks += { .setup_grid }
        }
        
        ////////////////////////////////////////////////
        // Update 
        
        do_tasks_in_order(&this_frame, &collapse, &entropy, &arena)
        
        ////////////////////////////////////////////////
        // Render
        
        spall_begin("Render")
        rl.BeginTextureMode(viewing_render_target)
        rl.ClearBackground({0x1F, 0x31, 0x4B, 0xFF})
        
        // @todo(viktor): Confirm that the directions are correctly mapped to vectors and displayed correctly on the circle
        if viewing_group != nil {
            center := Viewing_Size / 2
            p := vec_cast(f32, center)
            size := cast(f32) Viewing_Size.x / cast(f32) ((len(color_groups)+1) * 2 + 1)
            
            ring_size    := 0.9 * size
            ring_padding := 0.1 * size
            
            center_size  := ring_size
            
            view_slices :: 250
            for comparing_group, group_index in color_groups {
                total_supports := make([] f32, view_slices, context.temp_allocator)
                max_support: f32
                
                turns := cast(f32) view_slices
                for slice in 0..<view_slices {
                    turn := cast(f32) slice
                    
                    sampling_direction := arm(turn * Tau / turns)
                    
                    closeness := get_closeness(sampling_direction)
                    for vok, vid in viewing_group.ids do if vok {
                        for cok, cid in comparing_group.ids do if cok {
                            total_supports[slice] += get_support_amount(&collapse, cast(State_Id) vid, cast(State_Id) cid, closeness)
                        }
                    }
                    max_support = max(max_support, total_supports[slice])
                }
                
                for slice in 0..<view_slices {
                    turn := cast(f32) slice
                    
                    sampling_direction := -arm(turn * Tau / turns)
                    
                    total_support := total_supports[slice]
                    alpha := safe_ratio_0(total_support, max_support)
                    color := rl.ColorAlpha(comparing_group.color, alpha)
                    
                    center := direction_to_angles(sampling_direction)
                    width: f32 = 360. / turns
                    start := center - width * .5
                    stop  := center + width * .5
                    
                    inner := (center_size +  ring_size) + cast(f32) group_index * ring_size + ring_padding
                    outer := inner + ring_size
                    
                    rl.DrawRing(p, inner, outer, start, stop, 0, color)
                }
            }
            
            rl.DrawCircleV(p, center_size, viewing_group.color)
        }
        rl.EndTextureMode()
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        current := len(collapse.steps) != 0 ? peek(collapse.steps)^ : {}
        
        spall_begin("Prepare Render")
        {
            cells_background_hue_t += rl.GetFrameTime() * DegreesPerRadian
            if cells_background_hue_t >= 360 do cells_background_hue_t -= 360
            
            hsv := rl.ColorToHSV(v4_to_rl_color(cells_background_color))
            hue := hsv.x + cells_background_hue_t
            color := rl.ColorFromHSV(hue, hsv.y, hsv.z)
            
            background := rectangle_min_dimension(v2{}, vec_cast(f32, dimension))
            rl.DrawRectangleRec(world_to_screen(background), color)
        }
        
        spall_begin("render cells")
        for &cell in cells {
            color: rl.Color
            
            color = cell.average_color
            if !render_wavefunction_as_average && !cell.collapsed {
                color = 0
            }
            draw_cell(cell, color)
        }
        spall_end()
        
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
            color_alpha := v4_to_rl_color(Emerald * {1,1,1,0.5}) 
            
            for cell in cells {
                center := world_to_screen(cell.p)
                rl.DrawCircleV(center, 4, color)
                for neighbour in cell.neighbours {
                    end := world_to_screen(neighbour.p)
                    rl.DrawLineEx(center, end, 2, color_alpha)
                }
            }
        }
        
        if highlight_step && len(collapse.steps) > 0 {
            viewed := collapse.steps[min(viewing_step, current.step)]
            for cell in viewed.found {
                draw_cell_outline(cell^, rl.GREEN)
            }
            
            start := viewed.step == current.step ? viewed.changes_cursor : 0
            for change in viewed.changes[start:] {
                if change == nil do continue
                draw_cell_outline(change^, rl.YELLOW)
            }
            
            if viewed.to_be_collapsed != nil {
                draw_cell_outline(viewed.to_be_collapsed^, rl.ORANGE)
            }
        }
    
        rl.DrawTextureEx(viewing_render_target.texture, 0, 0, 0, 255)
        
        spall_end(/* Prepare Render */)
        
        spall_begin("Execute Render")
        rl_imgui_render()
        rl.EndDrawing()
        spall_end()
        
        spall_end(/* Render */)
    }
}

restart :: proc (this_frame: ^Frame) {
    this_frame.tasks += { .rewind }
    this_frame.rewind_to = .Start
}

do_tasks_in_order :: proc (this_frame: ^Frame, c: ^Collapse, entropy: ^RandomSeries, arena: ^Arena) {
    spall_scope("Update")
    
    next_frame: Frame
    
    update_start := time.now()
    update_limit := round(time.Duration, TargetFrameTime * cast(f64) time.Second)
    task_loop: for this_frame.tasks != {} && time.since(update_start) < update_limit {
        if .setup_grid in this_frame.tasks {
            this_frame.tasks -= { .setup_grid }
            
            setup_grid(c, entropy, arena)
            
            setup_cells(c)
            
            restart(this_frame)
        }
        
        if .extract_states in this_frame.tasks {
            this_frame.tasks -= { .extract_states }
            
            assert(this_frame.pixels != nil)
            
            N = desired_N
            collapse_reset(c)
            extract_states(c, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
            
            // Extract color groups
            for state in c.states {
                color_id := state.middle
                color := c.values[color_id]
                
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
            
            is_restart := false
            switch this_frame.rewind_to {
              case .Viewed:
                if viewing_step + 1 < auto_cast len(c.steps) {
                    spall_scope("Cleanup Steps")
                    for step in c.steps[viewing_step+1:] {
                        delete_step(step)
                    }
                }
                resize_dynamic_array(&c.steps, auto_cast viewing_step + 1)
                
              case .Previous_Choice: 
                if len(c.steps) > 0 {
                    spall_scope("Cleanup Steps")
                    bad_step := pop(&c.steps)
                    delete_step(bad_step)
                }
                if len(c.steps) == 0 {
                    is_restart = true
                    append(&c.steps, Step {})
                }
                
              case .Start: 
                is_restart = true
                spall_scope("Cleanup Steps")
                for step in c.steps {
                    delete_step(step)
                }
                clear(&c.steps)
                append(&c.steps, Step {})
            }
            
            current := peek(c.steps)
            print("Rewind to %\n", cast(int) current.step)
            print("Is Restart %\n", is_restart)
            
            if is_restart {
                spall_scope("Restart")
                
                total_duration = 0
                assert(len(cells[0].states) == len(c.states))
                
                for &cell in cells {
                    cell.collapsed = false
                    for &state, index in cell.states {
                        state.id = cast(State_Id) index
                        state.removed_at = Invalid_Collapse_Step
                    }
                }
            } else {
                for &cell in cells {
                    for &state in cell.states {
                        if state.removed_at != Invalid_Collapse_Step && state.removed_at >= current.step {
                            state.removed_at = Invalid_Collapse_Step
                            cell.collapsed = false
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
            
            print("Update with %\n", peek(c.steps).state)
            
            if c.states != nil {
                this_update_start := time.now()
                result := step_update(c, entropy)
                
                switch result {
                  case .Done:   break task_loop
                  case .Rewind: next_frame.tasks += { .rewind }
                  case .Ok:     next_frame.tasks += { .update }
                }
                
                total_duration += time.since(this_update_start)
            }
        }
        
        if !paused {
            this_frame ^= next_frame
            next_frame = {}
        } else {
            if desired_update_state != nil {
                if desired_update_state != peek(c.steps).state {
                    this_frame ^= next_frame
                } else {
                    desired_update_state = nil
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
        
        for &state, index in cell.states {
            state.id = cast(State_Id) index
            state.removed_at = Invalid_Collapse_Step
        }
    }
}

setup_grid :: proc (c: ^Collapse, entropy: ^RandomSeries, arena: ^Arena) {
    ratio := vec_cast(f32, Screen_Size-100) / vec_cast(f32, dimension)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    clear(&cells)
    
    area := dimension.x * dimension.y
    points := make([dynamic] v2d, 0, area, context.temp_allocator)
    generate_points(&points, cast(u32) area)
    
    // @todo(viktor): Just take an allocator here
    dt: Delauney_Triangulation
    begin_triangulation(&dt, arena, points[:])
    complete_triangulation(&dt)
    voronoi_cells := end_triangulation_voronoi_cells(&dt)
    defer {
        delete(voronoi_cells)
        delete(dt.all_bad_edges)
        delete(dt.bad_triangles)
        delete(dt.polygon)
    }
    
    for it in voronoi_cells {
        cell: Cell
        cell.p = vec_cast(f32, it.center * vec_cast(f64, dimension))
        
        make(&cell.points, len(it.points))
        for point, index in it.points {
            p := vec_cast(f32, point * vec_cast(f64, dimension))
            cell.points[index] = p
        }
        
        append(&cells, cell)
    }
    
    for &cell, cell_index in cells {
        voronoi := voronoi_cells[cell_index]
        make(&cell.neighbours, len(voronoi.neighbour_indices))
        
        for neighbour_index, index in voronoi.neighbour_indices {
            neighbour := &cells[neighbour_index]
            cell.neighbours[index] = neighbour
        }
    }
    
    for cell in voronoi_cells {
        delete(cell.points)
        delete(cell.neighbour_indices)
    }
}

generate_points :: proc(points: ^[dynamic] v2d, count: u32) {
    // @note(viktor): We get numerical instability if points are perfectly vertically or horizontally aligned
    side := round(u32, square_root(cast(f32) count))
    entropy := seed_random_series(123456789)
    switch generate_kind  {
      case .Shifted_Grid:
        for x in 0 ..< side {
            for y in 0 ..< side {
                p := (vec_cast(f64, x, y) + 0.5) / cast(f64) side
                offset := random_unilateral(&entropy, v2d) * (0.02 / cast(f64) side)
                p += next_random_u32(&entropy) % 2 == 0 ? offset : - offset
                p = clamp(p, 0, 1)
                append(points, p)
            }
        }
        
      case .Grid:
        for x in 0 ..< side {
            for y in 0 ..< side {
                p := (vec_cast(f64, x, y) + 0.5) / cast(f64) side
                p += random_bilateral(&entropy, v2d) * 0.00001
                append(points, p)
            }
        }
        
      case .Diamond_Grid:
        for x in 0 ..< side {
            for y in 0 ..< side {
                if (x + y) % 2 == 0 {
                    p := (vec_cast(f64, x, y) + 0.5) / cast(f64) side
                    p += random_bilateral(&entropy, v2d) * 0.00001
                    append(points, p)
                }
            }
        }
        
      case .Hex_Vertical:
        for x in 0 ..< side {
            for y in 0 ..< side {
                x := cast(f64) x
                if y % 2 == 0 do x += 0.5
                y := cast(f64) y
                p := (v2d{x, y} + 0.25) / cast(f64) side
                p += random_bilateral(&entropy, v2d) * 0.00001
                append(points, p)
            }
        }
        
      case .Hex_Horizontal:
        for x in 0 ..< side {
            for y in 0 ..< side {
                y := cast(f64) y
                if x % 2 == 0 do y += 0.5
                x := cast(f64) x
                p := (v2d{x, y} + 0.25) / cast(f64) side
                p += random_bilateral(&entropy, v2d) * 0.00001
                append(points, p)
            }
        }
        
      case .Spiral:
        center :: 0.5
        for index in 0..<count {
            angle := 1.6180339887 * cast(f64) index
            t := cast(f64) index / cast(f64) count
            radius := 0.5 - linear_blend(f64(0.05), 0.5, square(t))
            append(points, center + arm(angle) * radius)
        }
        
      case .Random:
        for _ in 0..<count {
            append(points, random_unilateral(&entropy, v2d))
        }
        
      case .BlueNoise:
        r := square_root(1.0 / (Pi * f64(count)))
        min_dist_squared := r * r
        
        for _ in 0..<count {
            valid := false
            new_point: v2d
            
            for !valid {
                new_point = random_unilateral(&entropy, v2d)
                valid = true
                check: for point in points {
                    if length_squared(point - new_point) < min_dist_squared {
                        valid = false
                        break check
                    }
                }
            }
            
            append(points, new_point)
        }
    }
}

draw_cell :: proc (cell: Cell, color: rl.Color) {
    @(static) buffer: [dynamic] v2 // @leak
    clear(&buffer)
    
    append(&buffer, world_to_screen(cell.p))
    for point in cell.points {
        append(&buffer, world_to_screen(point))
    }
    append(&buffer, buffer[1])
    
    rl.DrawTriangleFan(raw_data(buffer), auto_cast len(buffer), color)
}
draw_cell_outline :: proc (cell: Cell, color: rl.Color) {
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

direction_to_angles :: proc(direction: [2]$T) -> (angle: T) {
    angle = atan2(direction.y, direction.x) * DegreesPerRadian
    return angle
}