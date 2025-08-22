package main

import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

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

Screen_Size :: v2i{1920, 1080}

TargetFps       :: 60
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

total_duration: time.Duration

paused: b32

wrapping: b32

cell_size_on_screen: f32

average_colors: #soa [] Average_Color
Average_Color :: struct {
    states_count_when_computed: u32,
    color: rl.Color,
}

show_triangulation := false
render_wavefunction_as_average := true
highlight_changes := false

viewing_group: ^Color_Group
color_groups:  [dynamic] Color_Group
Color_Group :: struct {
    color: rl.Color,
    ids:   [/* State_Id */] b32,
}

grid_background_color := DarkGreen

dimension: v2i = {40, 40}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture2D,
}

view_slices: i32 = 4
view_slice_start: f32 // @todo(viktor): this can be used not only in viewing but also in the collapse itself. could be interesting.
view_mode := View_Mode.AcosCos
View_Mode :: enum {
    Cos, AcosCos, AcosAcosCos,
}

////////////////////////////////////////////////

Direction :: enum {
    East, North, West, South,
}

search_metric := Search_Metric.Entropy

////////////////////////////////////////////////

Neighbour_Threshold: f32 = 1.2

////////////////////////////////////////////////

this_frame: Frame
Frame :: struct {
    tasks: bit_set[Task],
    
    // extract states
    desired_N:        i32,
    pixels:           [] rl.Color,
    pixels_dimension: v2i,
    
    // resize grid
    desired_dimension: v2i,
    old_dimension:     v2i,
    old_grid:          [] Cell,
}

Task :: enum {
    resize_grid, 
    extract_states, 
    restart, 
    update,
}

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
    triangles: [] [3] v2
    setup_grid(&collapse, dimension, dimension, &entropy, &arena, &triangles)
    this_frame.desired_N = N
    
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
        this_frame.old_grid = nil
        
        ui(&collapse, images)
        
        ////////////////////////////////////////////////
        // Update 
        update_start: time.Time
        
        spall_begin("Update")
        for this_frame.tasks != {} {
            // @todo(viktor): if drawing_initializing and do_restart: Tell the user that their drawing may be unsolvable
            if .resize_grid in this_frame.tasks {
                this_frame.tasks -= { .resize_grid }
                
                this_frame.old_grid = grid[:]
                this_frame.old_dimension = dimension
                setup_grid(&collapse, dimension, this_frame.desired_dimension, &entropy, &arena, &triangles)
                
                this_frame.tasks += { .restart }
            }
            
            if .extract_states in this_frame.tasks {
                this_frame.tasks -= { .extract_states }
                
                assert(this_frame.pixels != nil)
                
                N = this_frame.desired_N
                extract_states(&collapse, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
                    
                this_frame.tasks += { .restart }
            }
            
            if .restart in this_frame.tasks {
                this_frame.tasks -= { .restart }
                
                update_state = .Initialize_States
                total_duration = 0
                for &it in average_colors do it = {}
            }
            
            if .update in this_frame.tasks {
                this_frame.tasks -= { .update }
                
                if update_start == {} do update_start = time.now()
                
                this_update_start := time.now()
                switch update(&collapse, &entropy) {
                  case .CollapseUninialized: // nothing
                  case .AllCollapsed: 
                    
                  case .FoundContradiction:
                    this_frame.tasks += { .restart }
                    
                  case .Continue:
                    if update_state >= .Search_Cells {
                        total_duration += time.since(this_update_start)
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
        
        /* @todo(viktor): 
        X - abstract support in a direction to allow that lookup to be as complex as needed
        X - remove Direction from the grid / wavefunction and just work with the respective vector
        X - display the neighbour likelyhood on a circle of each color with each other color
        X - interpolate the likelyhood over the whole circle
        5 - make a graph/lattice that is still a regular grid
        6 - make the lattice irregular
        X - display the lattice as a voronoi diagram
        
        - Clip/remove triangles outside of the region
        - limit sides to length of <= 1
        */
        
        for cell, index in grid {
            average := &average_colors[index]
            
            if cell.collapsed {
                state    := collapse.states[cell.collapsed_state]
                color_id := state.values[N/4+N/4*N] // middle
                average.color = collapse.values[color_id]
                average.states_count_when_computed = 1
            } else {
                if len(cell.states) == 0 {
                    average.color = { 255, 0, 255, 255 }
                }
                
                if render_wavefunction_as_average {
                    // @todo(viktor): also allow for most likely color
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
        
        
        if viewing_group == nil {
            spall_begin("Render cells")
            temp_points := make([dynamic] v2, context.temp_allocator)
            for cell, index in grid {
                clear(&temp_points)
                average := &average_colors[index]
                
                for point in cell.triangle_points {
                    append(&temp_points, world_to_screen(point))
                }
                if len(cell.triangle_points) < 2 do continue
                append(&temp_points, world_to_screen(cell.triangle_points[1]))
                rl.DrawTriangleFan(raw_data(temp_points), cast(i32) len(temp_points), average.color)
                
                // @todo(viktor): technically we draw every edge twice, once per adjoining cell
                for p_index in 1..<len(temp_points)-1 {
                    rl.DrawLineV(
                        temp_points[p_index],
                        temp_points[p_index+1],
                        rl.BLACK,
                    )
                }
            }
            spall_end()
            
            if show_triangulation {
                color := v4_to_rl_color(Emerald) 
                for tri in triangles {
                    a, b := tri[0], tri[1]
                    if length_squared(b-a) < square(Neighbour_Threshold) {
                        rl.DrawLineV(world_to_screen(a), world_to_screen(b), color)
                    }
                    
                    a = tri[2]
                    if length_squared(b-a) < square(Neighbour_Threshold) {
                        rl.DrawLineV(world_to_screen(a), world_to_screen(b), color)
                    }
                    
                    b = tri[0]
                    if length_squared(b-a) < square(Neighbour_Threshold) {
                        rl.DrawLineV(world_to_screen(a), world_to_screen(b), color)
                    }
                }
            }
            
            spall_begin("Render extra")
            if highlight_changes {
                // @todo(viktor): we would need the whole cell here
                for cell_p in changes {
                    // rec := world_to_screen(rectangle_min_dimension(cell_p, 1))
                    // rl.DrawRectangleRec(rec, rl.ColorAlpha(rl.YELLOW, 0.4))
                }
            }
            
            for cell in to_be_collapsed {
                clear(&temp_points)
                
                for point in cell.triangle_points {
                    append(&temp_points, world_to_screen(point))
                }
                if len(cell.triangle_points) < 2 do continue
                append(&temp_points, world_to_screen(cell.triangle_points[1]))
                rl.DrawTriangleFan(raw_data(temp_points), cast(i32) len(temp_points), rl.PURPLE)
            }
        } else {
            spall_scope("View Neighbours")
            center := get_center(rectangle_min_dimension(v2i{}, dimension))
            p := world_to_screen(center)
            
            center_size := cell_size_on_screen*3
            for comparing_group, group_index in color_groups {
                ring_size := cell_size_on_screen * 3
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
        
        spall_end()
        
        spall_begin("Execute Render")
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
        
        spall_end()
    }
}


generate_points :: proc(points: ^Array(v2d), count: u32) {
    side := round(u32, square_root(cast(f32) count))
    entropy := seed_random_series(123456789)
    switch -1  {
      case -1:
        for x in 0 ..< side {
            for y in 0 ..< side {
                p := vec_cast(f64, x, y) / cast(f64) side
                p += random_bilateral(&entropy, v2d) * (0.05 / cast(f64) side)
                p = clamp(p, 0, 1)
                append(points, p)
            }
        }
      case 0:
        for x in 0 ..< side {
            for y in 0 ..< side {
                append(points, vec_cast(f64, x, y) / cast(f64) side)
            }
        }
      case 1:
        for x in 0 ..< side {
            for y in 0 ..< side {
                x := cast(f64) x
                if y % 2 == 0 do x += 0.5
                y := cast(f64) y
                append(points, v2d{x, y} / cast(f64) side)
            }
        }
      case 2:
        for x in 0 ..< side {
            for y in 0 ..< side {
                y := cast(f64) y
                if x % 2 == 0 do y += 0.5
                x := cast(f64) x
                append(points, v2d{x, y} / cast(f64) side)
            }
        }
      case 3:
        center :: 0.5
        for index in 0..<count {
            angle := 1.6180339887 * cast(f64) index
            t := cast(f64) index / cast(f64) count
            radius := linear_blend(f64(0.01), 0.5, square_root(t))
            append(points, center + arm(angle) * radius)
        }
      case 4:
        for _ in 0..<count {
            append(points, random_unilateral(&entropy, v2d))
        }
    }
}


setup_grid :: proc (c: ^Collapse, old_dimension, new_dimension: v2i, entropy: ^RandomSeries, arena: ^Arena, triangles: ^[] [3] v2) {
    dimension = new_dimension // @todo(viktor): this is a really stupid idea
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, new_dimension+10)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    area := new_dimension.x * new_dimension.y
    delete(average_colors)
    make(&average_colors, area)
    
    points := make_array(arena, v2d, area)
    generate_points(&points, cast(u32) area)
    
    dt: Delauney_Triangulation
    begin_triangulation(&dt, arena, slice(points))
    complete_triangulation(&dt)
    voronoi_cells := end_triangulation_voronoi_cells(&dt)
    
    triangles_double := end_triangulation(&dt)
    make(triangles, len(triangles_double))
    for &it, index in triangles {
        for &p, p_index in it {
            pd := triangles_double[index][p_index] * vec_cast(f64, dimension)
            p = vec_cast(f32, pd)
        }
    }
    
    for it in voronoi_cells {
        cell: Cell
        cell.p = vec_cast(f32, it.center * vec_cast(f64, dimension))
        cell.collapsed = false
        
        delete(cell.states)
        make(&cell.states, len(c.states))
        for &it, index in cell.states do it = cast(State_Id) index
        
        make(&cell.triangle_points, 0, len(it.points)+1)
        append(&cell.triangle_points, cell.p)
        
        for point in it.points {
            p := vec_cast(f32, point * vec_cast(f64, dimension))
            append(&cell.triangle_points, p)
        }
        
        append(&grid, cell)
    }
    
    for &cell, index in grid {
        voronoi := voronoi_cells[index]
        for neighbour_index in voronoi.neighbour_indices {
            neighbour: Neighbour
            neighbour.cell = &grid[neighbour_index]
            neighbour.to_neighbour = neighbour.cell.p - cell.p
            // @todo(viktor): what should this threshold be?
            if length(neighbour.to_neighbour) <= Neighbour_Threshold {
                append(&cell.neighbours, neighbour)
            }
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
    angle = atan2(direction.y, direction.x)  * (360 / Tau)
    return angle
}