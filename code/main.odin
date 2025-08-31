package main

import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

/* @todo(viktor): 
    - Maybe dont collapse into a concrete state immediatly but just into a set with all the same color / "middle value"
    Decide on how to handle visual center vs. actual center for voronoi cells on the edge
    Neighbour_Mode
    - to filter connections: Make Neighbour Relation not per cell but per cell-pair, so that when limiting the neighbours with neighbour_mode, we don't get a cell that has a neighbour who does not have that cell as its neighbour
    - dont remove neighbours, just disable them, that way we dont ne do regenerate the whole grid again
    
    - Make a visual editor for the closeness weighting function or make the viewing not a different mode but a window
    - dont mutate the states of a cell, instead store its states with a tag marking, when that state became invalid. thereby allowing us the backtrack the changes made without much work. we wouldn't need to reinit the grid all the time and could better search the space. !!!we need a non deterministic selection or we will always resample the same invalid path!!! we could also store the decision per each timestep and not pick random but the next most likely pick.
*/

Screen_Size :: v2i{1920, 1080}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

// @todo(viktor): rethink Update_State.Done with pausing and step until desired state
paused: b32
desired_update_state: Maybe(Update_State)

cell_size_on_screen: v2

average_colors: [] Average_Color
Average_Color :: struct {
    states_count_when_computed: u32,
    color:                      rl.Color,
}

show_neighbours                := false
show_voronoi_cells             := true
render_wavefunction_as_average := true
highlight_changes              := true

viewing_group: ^Color_Group
color_groups:  [dynamic] Color_Group
Color_Group :: struct {
    color: rl.Color,
    ids:   [/* State_Id */] b32,
}

grid_background_color := DarkGreen

dimension: v2i = {20, 20}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture2D,
}

view_mode := View_Mode.Cos
View_Mode :: enum {
    Cos, 
    AcosCos, 
    AcosAcosCos,
}

////////////////////////////////////////////////

Direction :: enum {
    East, North, West, South,
}

Deltas := [Direction] v2i { 
    .East  = { 1, 0},
    .North = { 0, 1},
    .West  = {-1, 0},
    .South = { 0,-1},
}

Opposite := [Direction] Direction {
    .East  = .West,
    .North = .South,
    .West  = .East,
    .South = .North,
}

search_metric := Search_Metric.Entropy

////////////////////////////////////////////////

neighbour_mode := Neighbour_Mode {
    kind = { .Threshold },
    threshold = 1.2,
    // amount = 4,
    // allow_multiple_at_same_distance = true,
}
Neighbour_Kind :: enum {
    Threshold,
    Closest_N,
}
Neighbour_Mode :: struct {
    kind: bit_set[Neighbour_Kind],

    threshold: f32,
    
    amount: i32,
    allow_multiple_at_same_distance: bool,    
}

Generate_Kind :: enum {
    Grid,
    Shifted_Grid,
    Diamond_Grid,
    Hex_Vertical,
    Hex_Horizontal,
    Spiral,
    Random,
    BlueNoise,
    Test,
}
generate_kind: Generate_Kind = .Shifted_Grid

////////////////////////////////////////////////

Task :: enum {
    setup_grid, 
    setup_neighbours,
    extract_states, 
    restart, 
    update,
}

Frame :: struct {
    tasks: bit_set[Task],
    
    // extract states
    pixels:           [] rl.Color,
    pixels_dimension: v2i,
    
    // setup grid
    desired_dimension:      v2i,
    desired_neighbour_mode: Neighbour_Mode,
}

show_index: i32 = -1
desired_N:  i32 = N

main :: proc () {
    unused(screen_to_world)
    
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    init_spall()
    
    imgui.set_current_context(imgui.create_context(nil))
    rlimgui.ImGui_ImplRaylib_Init()
    
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    images: map[string] File
    image_dir := "./images"
    file_type := ".png"
    infos, err := os2.read_directory_by_path(image_dir, 0, context.temp_allocator)
    if err != nil do print("Error reading dir %: %", image_dir, err)
    for info in infos {
        if info.type == .Regular {
            if strings.ends_with(info.name, file_type) {
                data, ferr := os2.read_entire_file(info.fullpath, context.allocator)
                if ferr != nil do print("Error reading file %:%\n", info.name, ferr)
                
                temp := begin_temporary_memory(&arena)
                defer end_temporary_memory(temp)
                cstr := copy_cstring(temp.arena, file_type)
                
                image := File { data = data }
                image.image   = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                images[info.name] = image
            }
        }
    }
    
    entropy := seed_random_series(7458)
    collapse: Collapse
    setup_grid(&collapse, &entropy, &arena)
    setup_neighbours()
    
    for !rl.WindowShouldClose() {
        spall_scope("Frame")
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        this_frame := Frame {
            desired_dimension      = dimension,
            pixels                 = nil,
            pixels_dimension       = {},
            desired_neighbour_mode = neighbour_mode,
        }
        
        ui(&collapse, images, &this_frame)
        
        if dimension != this_frame.desired_dimension {
            dimension = this_frame.desired_dimension
            this_frame.tasks += { .setup_grid }
        }
        if neighbour_mode != this_frame.desired_neighbour_mode {
            neighbour_mode = this_frame.desired_neighbour_mode
            this_frame.tasks += { .setup_neighbours }
        }
        
        ////////////////////////////////////////////////
        // Update 
        update_start: time.Time
        
        spall_begin("Update")
        task_loop: for this_frame.tasks != {} {
            if .setup_grid in this_frame.tasks {
                this_frame.tasks -= { .setup_grid }
                
                setup_grid(&collapse, &entropy, &arena)
                
                this_frame.tasks += { .setup_neighbours, .restart }
            }
            
            if .setup_neighbours in this_frame.tasks {
                this_frame.tasks -= { .setup_neighbours }
                
                setup_neighbours()
                
                this_frame.tasks += { .restart }
                if paused do break task_loop
            }
            
            if .extract_states in this_frame.tasks {
                this_frame.tasks -= { .extract_states }
                
                assert(this_frame.pixels != nil)
                
                N = desired_N
                collapse_reset(&collapse)
                extract_states(&collapse, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
                
                // Extract color groups
                for state in collapse.states {
                    color_id := state.middle_value
                    color := collapse.values[color_id]
                    
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
                        make(&group.ids, len(collapse.states))
                    }
                    
                    group.ids[state.id] = true
                }
                
                this_frame.tasks += { .restart }
                if paused do break task_loop
            }
            
            if .restart in this_frame.tasks {
                this_frame.tasks -= { .restart }
                
                collapse_restart(&collapse)
                
                assert(len(collapse.changes) == 0)
                assert(len(collapse.to_be_collapsed) == 0)
                for &cell in cells {
                    cell.state = .Collapsed
                    cell_next_state(&collapse, &cell)
                }
                update_state = .Search_Cells
                
                total_duration = 0
                zero(average_colors[:])
                if paused do break task_loop
            }
            
            if .update in this_frame.tasks {
                this_frame.tasks -= { .update }
                
                if collapse.states != nil {
                    if update_start == {} do update_start = time.now()
                    
                    this_update_start := time.now()
                    if collapse_update(&collapse, &entropy) {
                        if update_state != .Done {
                            if update_state >= .Search_Cells {
                                total_duration += time.since(this_update_start)
                                if paused {
                                    if desired_update_state != nil {
                                        if desired_update_state != update_state {
                                            this_frame.tasks += { .update }
                                        } else {
                                            desired_update_state = nil
                                        }
                                    } else {
                                        break task_loop
                                    }
                                }
                            }
                            
                            if time.duration_seconds(time.since(update_start)) < TargetFrameTime * 0.95 {
                                this_frame.tasks += { .update }
                            }
                        }
                    } else {
                        this_frame.tasks += { .restart }
                    }
                }
            }
        }
        spall_end()
        
        
        ////////////////////////////////////////////////
        // Render
        
        spall_begin("Render")
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        if len(average_colors) != len(cells) {
            delete(average_colors)
            make(&average_colors, len(cells))
        }
        
        for cell, index in cells {
            average := &average_colors[index]
            
            switch cell.state {
              case .Uninitialized:
              case .Collapsing:
                if len(cell.states) == 0 {
                    average.color = { 0, 0, 0, 0 }
                } else {
                    if render_wavefunction_as_average {
                        if average.states_count_when_computed != auto_cast len(cell.states) {
                            average.states_count_when_computed = auto_cast len(cell.states)
                            
                            color: v4
                            count: f32
                            for id in cell.states {
                                state    := collapse.states[id]
                                color_id := state.middle_value
                                color += rl_color_to_v4(collapse.values[color_id]) * state.frequency
                                count += state.frequency
                            }
                            
                            color = safe_ratio_0(color, count)
                            average.color = cast(rl.Color) v4_to_rgba(color * {1,1,1,0.3})
                        }
                    }
                }
                
              case .Collapsed:
                state    := collapse.states[cell.collapsed_state]
                color_id := state.middle_value
                average.color = collapse.values[color_id]
                average.states_count_when_computed = 1
            }
        }
        
        rl.DrawRectangleRec(world_to_screen(rectangle_min_dimension(v2{}, vec_cast(f32, dimension))), v4_to_rl_color(grid_background_color))
        
        if viewing_group == nil {
            for &cell, index in cells {
                if show_index != -1 && show_index != auto_cast index do continue
                
                color: rl.Color
                if render_wavefunction_as_average {
                    color = average_colors[index].color
                } else {
                    if cell.state == .Collapsed {
                        color = collapse.values[collapse.states[cell.collapsed_state].middle_value]
                    } else {
                        color = 0
                    }
                }
                draw_cell(cell, color)
            }
            
            if show_voronoi_cells {
                for cell, index in cells {
                    if show_index != -1 && show_index != auto_cast index do continue
                    
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
                    for neighbour in cell.all_neighbours {
                        end := world_to_screen(neighbour.p)
                        rl.DrawLineEx(center, end, 1, rl.GRAY)
                    }
                    for neighbour in cell.neighbours {
                        end := world_to_screen(neighbour.p)
                        rl.DrawLineEx(center, end, 2, color_alpha)
                    }
                }
            }
                        
            if highlight_changes {
                color := rl.YELLOW
                for change in collapse.changes[collapse.changes_cursor:] {
                    if change == nil do continue
                    draw_cell_outline(change^, color)
                }
            }
            
            for cell in collapse.to_be_collapsed {
                a := world_to_screen(cell.p)
                for p_index in 0..<len(cell.points) {
                    b := world_to_screen(cell.points[p_index])
                    c := world_to_screen(cell.points[(p_index+1)%len(cell.points)])
                    rl.DrawTriangle(a, b, c, rl.PURPLE)
                }
            }
        } else {
            center := get_center(rectangle_min_dimension(v2i{}, dimension))
            p := world_to_screen(center)
            
            size := min(cell_size_on_screen.x, cell_size_on_screen.y) * 3
            center_size := size
            ring_size := size
            ring_padding := 0.2 * ring_size
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
                    
                    sampling_direction := arm(turn * Tau / turns)
                    
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
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
        
        spall_end(/* Render */)
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
    delete(average_colors)
    make(&average_colors, area)
    
    points := make([dynamic] v2d)
    defer delete(points)
    
    generate_points(&points, cast(u32) area)
    
    dt: Delauney_Triangulation
    begin_triangulation(&dt, arena, points[:])
    complete_triangulation(&dt)
    voronoi_cells := end_triangulation_voronoi_cells(&dt)
    
    for it in voronoi_cells {
        cell: Cell
        cell.p = vec_cast(f32, it.center * vec_cast(f64, dimension))
        
        make(&cell.points, 0, len(it.points))
        for point in it.points {
            p := vec_cast(f32, point * vec_cast(f64, dimension))
            append(&cell.points, p)
        }
        
        cell.state = .Uninitialized 
        append(&cells, cell)
    }
    
    for &cell, index in cells {
        voronoi := voronoi_cells[index]
        for neighbour_index in voronoi.neighbour_indices {
            neighbour := &cells[neighbour_index]
            
            append(&cell.all_neighbours, neighbour)
        }
    }
}

setup_neighbours :: proc () {
    for &cell in cells {
        clear(&cell.neighbours)
        
        for neighbour in cell.all_neighbours {
            do_append := true
            if do_append && .Threshold in neighbour_mode.kind {
                delta := neighbour.p - cell.p
                if length(delta) > neighbour_mode.threshold {
                    do_append = false
                }
            }
            
            if do_append && .Closest_N in neighbour_mode.kind {
                if neighbour_mode.amount <= auto_cast len(cell.neighbours) {
                    to_neighbour := length_squared(neighbour.p - cell.p)
                    to_furthest: f32
                    removed := false
                    #reverse for &it, it_index in cell.neighbours {
                        to_it := length_squared(it.p - cell.p)
                        if to_it > to_neighbour {
                            remove := false
                            if neighbour_mode.allow_multiple_at_same_distance {
                                if to_it >= to_furthest {
                                    remove = true
                                }
                            } else {
                                if to_it > to_furthest {
                                    remove = true
                                }
                            }
                            
                            if remove {
                                unordered_remove(&cell.neighbours, it_index)
                                removed = true
                            }
                        }
                    }
                    
                    if !removed do do_append = false
                }
            }
            
            if do_append do append(&cell.neighbours, neighbour)
        }
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
                offset := random_unilateral(&entropy, v2d) * (0.05 / cast(f64) side) + 0.001
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
        
      case .Test:
        append(points, v2d {.2, .2})
        append(points, v2d {.3, .7})
        append(points, v2d {.7, .3})
        append(points, v2d {.8, .8})
        append(points, v2d {.5, .5})
        
      case: unreachable()
    }
}

draw_cell :: proc (cell: Cell, color: rl.Color) {
    a := world_to_screen(cell.p)
    for p_index in 0..<len(cell.points) {
        b := cell.points[p_index]
        c := cell.points[(p_index+1)%len(cell.points)]
        rl.DrawTriangle(a, world_to_screen(b), world_to_screen(c), color)
    }
}
draw_cell_outline :: proc (cell: Cell, color: rl.Color) {
    for p_index in 0..<len(cell.points) {
        begin := world_to_screen(cell.points[p_index])
        end   := world_to_screen(cell.points[(p_index+1)%len(cell.points)])
        rl.DrawLineV(begin, end, color)
    }
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

screen_to_world :: proc (screen: v2) -> (world: v2i) {
    screen_size := vec_cast(f32, Screen_Size)
    screen_min := v2{0, screen_size.y}
    
    grid_size := cell_size_on_screen * vec_cast(f32, dimension)
    grid_min := screen_min + {1,-1} * 0.5 * (screen_size - grid_size)
    
    world = vec_cast(i32, (screen - grid_min) / cell_size_on_screen * {1, -1})
    
    return world
}

direction_to_angles :: proc(direction: [2]$T) -> (angle: T) {
    angle = atan2(direction.y, direction.x)  * DegreesPerRadian
    return angle
}