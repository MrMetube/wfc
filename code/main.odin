package main

import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

/* @todo(viktor): 
    - Make Neighbour Relation not per cell but per cell-pair, so that when limiting the neighbours with neighbour_mode, we don't get a cell that has a neighbour who does not have that cell as its neighbour
    - Make a visual editor for the closeness weighting function or make the viewing not a different mode but a window
    - dont mutate the states of a cell, instead store its states with a tag marking, when that state became invalid. thereby allowing us the backtrace the changes made without much work. we wouldn't need to reinit the grid all the time and could better search the space. !!!we need a non deterministic selection or we will always resample the same invalid path!!! we could also store the decision per each timestep and not pick random but the next most likely pick.
    X limit sides to length of <= 1
    X Clip/remove triangles outside of the region
*/

Screen_Size :: v2i{1920, 1080}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

paused: b32

wrapping: b32

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

dimension: v2i = {50, 50}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture2D,
}

view_slices: i32 = 4
view_slice_start: f32
view_mode := View_Mode.Nearest
View_Mode :: enum {
    Nearest,
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
    kind = {.Threshold},
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
    Shifted_Grid,
    Grid,
    Hex_Vertical,
    Hex_Horizontal,
    Spiral,
    Random,
    BlueNoise,
    Test,
}
generate_kind: Generate_Kind = .Shifted_Grid

////////////////////////////////////////////////

this_frame := Frame {
    desired_N         = N,
    desired_dimension = dimension,
}
Frame :: struct {
    tasks: bit_set[Task],
    
    // extract states
    desired_N:        i32,
    pixels:           [] rl.Color,
    pixels_dimension: v2i,
    
    // setup grid
    desired_dimension: v2i,
    desired_neighbour_mode: Neighbour_Mode,
}

Task :: enum {
    setup_grid, 
    extract_states, 
    restart, 
    update,
}

show_index: i32 = -1

main :: proc () {
    unused(screen_to_world)
    
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    init_spall()
    
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    images: map[string]File
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
    
    imgui.set_current_context(imgui.create_context(nil))
    rlimgui.ImGui_ImplRaylib_Init()

    entropy := seed_random_series(7458)
    collapse: Collapse
    setup_grid(&collapse, dimension, &entropy, &arena)
    
    for !rl.WindowShouldClose() {
        spall_scope("Frame")
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        this_frame.desired_dimension = dimension
        this_frame.pixels = nil
        this_frame.pixels_dimension = {}
        this_frame.desired_neighbour_mode = neighbour_mode
        
        ui(&collapse, images)
        
        if this_frame.desired_dimension != dimension {
            this_frame.tasks += { .setup_grid }
        }
        if this_frame.desired_neighbour_mode != neighbour_mode {
            this_frame.tasks += { .setup_grid }
        }
        
        ////////////////////////////////////////////////
        // Update 
        update_start: time.Time
        
        spall_begin("Update")
        task_loop: for this_frame.tasks != {} {
            // @todo(viktor): if drawing_initializing and do_restart: Tell the user that their drawing may be unsolvable
            if .setup_grid in this_frame.tasks {
                this_frame.tasks -= { .setup_grid }
                
                setup_grid(&collapse, this_frame.desired_dimension, &entropy, &arena)
                
                this_frame.tasks += { .restart }
                if paused do break task_loop
            }
            
            if .extract_states in this_frame.tasks {
                this_frame.tasks -= { .extract_states }
                
                assert(this_frame.pixels != nil)
                
                N = this_frame.desired_N
                reset_collapse(&collapse)
                extract_states(&collapse, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
                
                this_frame.tasks += { .restart }
                if paused do break task_loop
            }
            
            if .restart in this_frame.tasks {
                this_frame.tasks -= { .restart }
                
                restart_collapse(&collapse)
                
                update_state = .Initialize_States
                total_duration = 0
                zero(average_colors[:])
                if paused do break task_loop
            }
            
            if .update in this_frame.tasks {
                this_frame.tasks -= { .update }
                
                if update_start == {} do update_start = time.now()
                
                this_update_start := time.now()
                state := update(&collapse, &entropy)
                switch state {
                  case .CollapseUninialized: // nothing
                  case .AllCollapsed: 
                    
                  case .FoundContradiction:
                    this_frame.tasks += { .restart }
                    
                  case .Continue:
                    if update_state >= .Search_Cells {
                        total_duration += time.since(this_update_start)
                        if paused do break task_loop
                    }
                    
                    if time.duration_seconds(time.since(update_start)) < TargetFrameTime * 0.95 {
                        this_frame.tasks += { .update }
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
            
            if cell.collapsed {
                state    := collapse.states[cell.collapsed_state]
                color_id := state.values[N/4+N/4*N] // middle
                average.color = collapse.values[color_id]
                average.states_count_when_computed = 1
            } else {
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
                                color_id := state.values[N/4+N/4*N] // middle
                                color += rl_color_to_v4(collapse.values[color_id]) * cast(f32) state.frequency
                                count += cast(f32) state.frequency
                            }
                            
                            color = safe_ratio_0(color, count)
                            average.color = cast(rl.Color) v4_to_rgba(color * {1,1,1,0.3})
                        }
                    }
                }
            }
        }
        
        rl.DrawRectangleRec(world_to_screen(rectangle_min_dimension(v2{}, vec_cast(f32, dimension))), v4_to_rl_color(grid_background_color))
        
        if viewing_group == nil {
            for &cell, index in cells {
                if show_index != -1 && show_index != auto_cast index do continue
                
                average := average_colors[index].color
                
                a := world_to_screen(cell.p)
                for p_index in 0..<len(cell.points) {
                    b := world_to_screen(cell.points[p_index])
                    c := world_to_screen(cell.points[(p_index+1)%len(cell.points)])
                    rl.DrawTriangle(a, b, c, average)
                }
                
            }
            
            if show_voronoi_cells {
                for cell, index in cells {
                    if show_index != -1 && show_index != auto_cast index do continue
                    
                    center := world_to_screen(cell.p)
                    rl.DrawCircleV(center, 3, v4_to_rl_color(Blue))
                    
                    color_wheel := color_wheel
                    color := v4_to_rl_color(color_wheel[(index) % len(color_wheel)])
                    
                    for p_index in 0..<len(cell.points) {
                        begin := world_to_screen(cell.points[p_index])
                        end   := world_to_screen(cell.points[(p_index+1)%len(cell.points)])
                        rl.DrawLineV(begin, end, color)
                    }
                }
            }
            
            if show_neighbours {
                color := v4_to_rl_color(Emerald) 
                color_alpha := v4_to_rl_color(Emerald * {1,1,1,0.5}) 
                
                for cell in cells {
                    center := world_to_screen(cell.p)
                    rl.DrawCircleV(center, 4, color)
                    for neighbour in cell.neighbours {
                        end := world_to_screen(cell.p + neighbour.to_neighbour)
                        rl.DrawLineEx(center, end, 2, color_alpha)
                    }
                }
            }
            
            if highlight_changes {
                // @todo(viktor): we would need the whole cell here
                // for cell_p in collapse.changes {
                //     rec := world_to_screen(rectangle_min_dimension(cell_p, 1))
                //     rl.DrawRectangleRec(rec, rl.ColorAlpha(rl.YELLOW, 0.4))
                // }
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
            spall_scope("View Neighbours")
            center := get_center(rectangle_min_dimension(v2i{}, dimension))
            p := world_to_screen(center)
            
            size := min(cell_size_on_screen.x, cell_size_on_screen.y)
            center_size := size
            for comparing_group, group_index in color_groups {
                ring_size := size
                ring_padding := 0.2 * ring_size
                
                max_support: f32
                total_supports := make([dynamic] f32, view_slices, context.temp_allocator)
                
                turns := cast(f32) view_slices
                for slice in 0..<view_slices {
                    turn := cast(f32) slice
                    turn += view_slice_start
                    
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
                    turn += view_slice_start
                    
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
            spall_end()
        }
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
        
        spall_end(/* Frame */)
    }
}


generate_points :: proc(points: ^[dynamic] v2d, count: u32) {
    side := round(u32, square_root(cast(f32) count))
    entropy := seed_random_series(123456789)
    switch generate_kind  {
      case .Shifted_Grid:
        for x in 0 ..< side {
            for y in 0 ..< side {
                p := vec_cast(f64, x, y) / cast(f64) side
                p += random_bilateral(&entropy, v2d) * (0.05 / cast(f64) side)
                p = clamp(p, 0.01, 0.98)
                append(points, p)
            }
        }
        
      case .Grid:
        for x in 0 ..< side {
            for y in 0 ..< side {
                percent := vec_cast(f64, x, y) / cast(f64) side
                pad := 0.01
                append(points, pad + percent * (1-pad*2))
            }
        }
        
      case .Hex_Vertical:
        for x in 0 ..< side {
            for y in 0 ..< side {
                x := cast(f64) x
                if y % 2 == 0 do x += 0.5
                y := cast(f64) y
                append(points, v2d{x, y} / cast(f64) side)
            }
        }
        
      case .Hex_Horizontal:
        for x in 0 ..< side {
            for y in 0 ..< side {
                y := cast(f64) y
                if x % 2 == 0 do y += 0.5
                x := cast(f64) x
                append(points, v2d{x, y} / cast(f64) side)
            }
        }
        
      case .Spiral:
        center :: 0.5
        for index in 0..<count {
            angle := 1.6180339887 * cast(f64) index
            t := cast(f64) index / cast(f64) count
            radius := linear_blend(f64(0.01), 0.5, square_root(t))
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


setup_grid :: proc (c: ^Collapse, new_dimension: v2i, entropy: ^RandomSeries, arena: ^Arena) {
    dimension = new_dimension // @todo(viktor): this is a really stupid idea
    
    ratio := vec_cast(f32, Screen_Size-100) / vec_cast(f32, new_dimension)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    clear(&cells)
    
    area := new_dimension.x * new_dimension.y
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
        cell.collapsed = false
        
        delete(cell.states)
        make(&cell.states, len(c.states))
        for &it, index in cell.states do it = cast(State_Id) index
        
        make(&cell.points, 0, len(it.points))
        
        for point in it.points {
            p := vec_cast(f32, point * vec_cast(f64, dimension))
            append(&cell.points, p)
        }
        
        append(&cells, cell)
    }
    
    for &cell, index in cells {
        voronoi := voronoi_cells[index]
        for neighbour_index in voronoi.neighbour_indices {
            neighbour: Neighbour
            neighbour.cell = &cells[neighbour_index]
            neighbour.to_neighbour = neighbour.cell.p - cell.p
            
            do_append := true
            
            if do_append && .Threshold in neighbour_mode.kind {
                if length(neighbour.to_neighbour) > neighbour_mode.threshold {
                    do_append = false
                }
            }
            
            if do_append && .Closest_N in neighbour_mode.kind {
                if neighbour_mode.amount <= auto_cast len(cell.neighbours) {
                    to_neighbour := length_squared(neighbour.to_neighbour)
                    to_furthest: f32
                    removed := false
                    #reverse for &it, it_index in cell.neighbours {
                        to_it := length_squared(it.to_neighbour)
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