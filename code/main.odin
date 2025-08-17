package main

import "core:os/os2"
import "core:strings"
import slices "core:slice"
import "core:time"

// @todo(viktor): Minesweeper fields should be possible to generate if you also count diagonal edges in the extraction

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

deviation: f32 = 0.05

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
highlight_drawing := true
highlight_changes := false

textures_length: int
textures_and_images: [dynamic] struct {
    image:   rl.Image,
    texture: rl.Texture,
}

Draw_Group :: struct {
    color: rl.Color,
    ids:   [/* State_Id */] b32,
}

brush_size_speed: f32 = 60
brush_size: f32 = 2
d_brush_size: f32 = 0
dd_brush_size: f32 = 0

viewing_group:   ^Draw_Group

grid_background_color := DarkGreen

// @todo(viktor): Rethink this api now that I kinda know what I want to be able to do. Can it be done with tasks?
drawing_initializing: b32
selected_group: ^Draw_Group
draw_board:     [] ^Draw_Group
draw_groups:    [dynamic] Draw_Group

dimension: v2i = {20, 20}

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

search_mode   := Search_Mode.Metric
search_metric := Search_Metric.Entropy

////////////////////////////////////////////////

this_frame: Frame
Frame :: struct {
    tasks: bit_set[Task],
    
    desired_regularity: f32,
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
    clear_drawing, 
    restart, 
    copy_old_grid,
    update,
}

main :: proc () {
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
    triangles: [] Triangle
    setup_grid(&collapse, dimension, dimension, &entropy, &arena, &triangles)
    this_frame.desired_N = N
    this_frame.desired_regularity = 1 - deviation
    
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
        sp := rl.GetMousePosition()
        wp := screen_to_world(sp)
        
        if viewing_group == nil {
            dd_brush_size = -rl.GetMouseWheelMove() * min(300, brush_size_speed * brush_size)
            d_brush_size += dd_brush_size * rl.GetFrameTime()
            d_brush_size += -d_brush_size * rl.GetFrameTime() * 10
            brush_size += d_brush_size * rl.GetFrameTime()
            brush_size = clamp(brush_size, 0.3, 10)
        
            if dimension_contains(dimension, wp) {
                if rl.IsMouseButtonDown(.LEFT) {
                    this_frame.tasks -= { .update }
                    
                    diameter := max(1, ceil(i32, brush_size*2))
                    area := rectangle_center_dimension(wp, diameter)
                    for y in area.min.y..<area.max.y {
                        for x in area.min.x..<area.max.x {
                            p := v2i{x, y}
                            if dimension_contains(dimension, p) && length_squared(p - wp) <= square(diameter/2) {
                                index := x + y * dimension.x
                                draw_board[index] = selected_group
                                if selected_group != nil {
                                    restrict_cell_to_drawn(&collapse, p, selected_group)
                                } else {
                                    println("unimplemented")
                                    // //  @copypasta from restart
                                    // // @todo(viktor): :Constrained the current implementation does not consider existing constraints
                                    // cell := &grid[index]
                                    // wave, ok := &cell.value.(Wave)
                                    // if ok {
                                    //     delete(wave.supports)
                                    // } else {
                                    //     cell.value = Wave  {}
                                    //     wave = &cell.value.(Wave)
                                    // }
                                    
                                    // make(&wave.supports, len(collapse.states))
                                    // for &it, index in wave.supports {
                                    //     it.id = cast(State_Id) index
                                    //     for &amount, direction in it.amount {
                                    //         amount = maximum_support[direction][it.id]
                                    //     }
                                    // }
                                    
                                    // delete_key(&changes, p)
                                }
                            }
                        }
                    }
                }
            }
        }
        
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
                deviation = 1 - this_frame.desired_regularity
                setup_grid(&collapse, dimension, this_frame.desired_dimension, &entropy, &arena, &triangles)
                
                this_frame.tasks += { .restart/* , .copy_old_grid */ }
            }
            
            if .extract_states in this_frame.tasks {
                this_frame.tasks -= { .extract_states }
                
                assert(this_frame.pixels != nil)
                
                N = this_frame.desired_N
                extract_states(&collapse, this_frame.pixels, this_frame.pixels_dimension.x, this_frame.pixels_dimension.y)
                    
                this_frame.tasks += { .restart, .clear_drawing }
            }
            
            if .clear_drawing in this_frame.tasks {
                this_frame.tasks -= { .clear_drawing }
                
                clear_draw_board()
                this_frame.tasks += { .restart }
            }
            
            if .restart in this_frame.tasks {
                this_frame.tasks -= { .restart }
                
                restart(&collapse)
                total_duration = 0
                for &it in average_colors do it = {}
            }
            
            if .copy_old_grid in this_frame.tasks {
                this_frame.tasks -= { .copy_old_grid }
                
                assert(this_frame.old_grid != nil)
                defer delete(this_frame.old_grid)
                // defer delete ps
                using this_frame
                
                // @cleanup
                // @todo(viktor): :Constrained When growing handle that it must connect to existing.
                when false do if !wrapping && old_grid != nil && new_dimension != old_dimension {
                    new_dimension := desired_dimension
                    delta := abs_vec(new_dimension - old_dimension) / 2
                    if (new_dimension.x > old_dimension.x || new_dimension.y > old_dimension.y) {
                        for y in 0..<old_dimension.y {
                            for x in 0..<old_dimension.x {
                                d := delta + {x, y}
                                grid[d.x + d.x * new_dimension.x].value = old_grid[x + y * old_dimension.x].value
                            }
                        }
                    } else {
                        for y in 0..<new_dimension.y {
                            for x in 0..<new_dimension.x {
                                d := delta + {x, y}
                                grid[x + y * new_dimension.x].value = old_grid[d.x + d.y * old_dimension.x].value
                            }
                        }
                    }
                }
                
                assert(false)
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
                    total_duration += time.since(this_update_start)
                    
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
        */
        
        // rl.DrawRectangleRec(world_to_screen(rectangle_min_dimension(v2i{}, dimension)), v4_to_rl_color(grid_background_color))
        
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
            for cell, index in grid {
                average := &average_colors[index]
                
                for tri in cell.triangles {
                    rl.DrawTriangle(
                        world_to_screen(tri[0]),
                        world_to_screen(tri[1]),
                        world_to_screen(tri[2]),
                        average.color
                    )
                    
                    rl.DrawLineV(
                        world_to_screen(tri[1]), 
                        world_to_screen(tri[2]),
                        rl.BLACK
                    )
                }
                
                // rect := world_to_screen(rectangle_min_dimension(cell.p, 1))
                // radius := cell_size_on_screen * 0.5
                // if average.states_count_when_computed == 1 {
                //     rl.DrawCircleV(v2{rect.x, rect.y} + radius, radius, average.color)
                // } else {
                //     if render_wavefunction_as_average {
                //         rl.DrawCircleV(v2{rect.x, rect.y} + radius, radius, average.color)
                //     }
                // }
            }
            spall_end()
            
            if show_triangulation {
                for tri in triangles {
                    rl.DrawTriangleLines(
                        world_to_screen(tri[0]),
                        world_to_screen(tri[1]),
                        world_to_screen(tri[2]),
                        v4_to_rl_color(Emerald)
                    )
                }
            }
            
            spall_begin("Render extra")
            // @todo(viktor): actually use cell.p and draw circles or something
            if highlight_drawing {
                for y in 0..<dimension.y {
                    for x in 0..<dimension.x {
                        index := x + y * dimension.x
                        drawn := draw_board[index]
                        if drawn != nil {
                            p := world_to_screen(v2i{x, y})
                            rect := rectangle_min_dimension(p, cell_size_on_screen)
                            rl.DrawRectangleRec(to_rl_rectangle(rect), rl.ColorAlpha(drawn.color, 0.7))
                        }
                    }
                }
            }
            
            if highlight_changes {
                for cell_p in changes {
                    rec := world_to_screen(rectangle_min_dimension(cell_p, 1))
                    rl.DrawRectangleRec(rec, rl.ColorAlpha(rl.YELLOW, 0.4))
                }
            }
            
            for cell in to_be_collapsed {
                rect := world_to_screen(rectangle_min_dimension(cell.p, 1))
                rl.DrawRectangleRec(rect, rl.PURPLE)
            }
            
            if dimension_contains(dimension, wp) {
                wsp := world_to_screen(wp)
                rect := rl.Rectangle {wsp.x, wsp.y, cell_size_on_screen, cell_size_on_screen}
                
                color := selected_group == nil ? rl.RAYWHITE : selected_group.color
                rl.DrawRectangleRec(rect, color)
                rl.DrawCircleLinesV(sp,   brush_size * cell_size_on_screen, rl.YELLOW)
            }
        } else {
            spall_scope("View Neighbours")
            center := get_center(rectangle_min_dimension(v2i{}, dimension))
            p := world_to_screen(center)
            
            center_size := cell_size_on_screen*3
            for comparing_group, group_index in draw_groups {
                ring_size := cell_size_on_screen * 3
                ring_padding := 0.2 * ring_size
                
                max_support: f32
                total_supports:= make([dynamic] f32, view_slices, context.temp_allocator)
                
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
        }
        spall_end()
        
        spall_end()
        
        spall_begin("Execute Render")
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
        
        spall_end()
    }
}


generate_points :: proc(points: ^Array(v2), count: u32) {
    side := round(u32, square_root(cast(f32) count))
    entropy := seed_random_series(123456789)
    switch -1  {
      case -1:
        for x in 0 ..< side {
            for y in 0 ..< side {
                p := vec_cast(f32, x, y) / cast(f32) side
                p += random_bilateral(&entropy, v2) * (0.05 / cast(f32) side)
                p = clamp(p, 0, 1)
                // p = rectangle_modulus(rectangle_min_dimension(v2{}, 1), p)
                append(points, p)
            }
        }
      case 0:
        for x in 0 ..< side {
            for y in 0 ..< side {
                append(points, vec_cast(f32, x, y) / cast(f32) side)
            }
        }
      case 1:
        for x in 0 ..< side {
            for y in 0 ..< side {
                x := cast(f32) x
                if y % 2 == 0 do x += 0.5
                y := cast(f32) y
                append(points, v2{x, y} / cast(f32) side)
            }
        }
      case 2:
        for x in 0 ..< side {
            for y in 0 ..< side {
                y := cast(f32) y
                if x % 2 == 0 do y += 0.5
                x := cast(f32) x
                append(points, v2{x, y} / cast(f32) side)
            }
        }
      case 3:
        center :: 0.5
        for index in 0..<count {
            angle := 1.6180339887 * cast(f32) index
            t := cast(f32) index / cast(f32) count
            radius := linear_blend(f32(0.01), 0.5, square_root(t))
            append(points, center + arm(angle) * radius)
        }
      case 4:
        for _ in 0..<count {
            append(points, random_unilateral(&entropy, v2))
        }
    }
}


setup_grid :: proc (c: ^Collapse, old_dimension, new_dimension: v2i, entropy: ^RandomSeries, arena: ^Arena, triangles: ^[] Triangle) {
    dimension = new_dimension // @todo(viktor): this is a really stupid idea
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, new_dimension+10)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    area := new_dimension.x * new_dimension.y
    _points := make_array(arena, v2, area)
    generate_points(&_points, cast(u32) area)
    dt: DelauneyTriangulation
    // @todo(viktor): use f64s to not have stupid artifacts all over
    begin_triangulation(&dt, arena, slice(_points))
    triangles ^= complete_triangulation(&dt)
    
    for &triangle in triangles {
        for &point in triangle {
            point *= vec_cast(f32, dimension)
        }
    }
    
    point_to_tris := make(map[v2] [dynamic] ^Triangle, context.temp_allocator)
    for &triangle in triangles {
        for point in triangle {
            if point not_in point_to_tris {
                point_to_tris[point] = make([dynamic] ^Triangle, context.temp_allocator)
            }
            tris := &point_to_tris[point]
            
            found: bool
            for it in tris do if it == &triangle {
                found = true
                break
            }
            
            if !found {
                append(tris, &triangle)
            }
        }
    }
    
    Foo :: struct { center, point: v2}
    centers := make([dynamic] Foo, context.temp_allocator)
    for point, tris in point_to_tris {
        clear(&centers)
        
        for triangle in tris {
            append(&centers, Foo {circum_circle(triangle^).center, point})
        }

        // Sort centers counterclockwise around `point`
        slices.sort_by(centers[:], proc(a: Foo, b: Foo) -> bool {
            angle_a := atan2(a.center.y - a.point.y, a.center.x - a.point.x)
            angle_b := atan2(b.center.y - b.point.y, b.center.x - b.point.x)
            return angle_a < angle_b
        })
        
        cell: Cell
        cell.p = point
        cell.collapsed = false
        
        delete(cell.states)
        make(&cell.states, len(c.states))
        for &it, index in cell.states do it = cast(State_Id) index
        
        cell.triangles = make([dynamic] Triangle)
        for i in 0..<len(centers) {
            a := centers[i]
            b := centers[(i + 1) % len(centers)]
            append(&cell.triangles, Triangle{point, a.center, b.center})
        }
        
        append(&grid, cell)
    }
    
    point_to_cell := make(map[v2] ^Cell, context.temp_allocator)
    for i in 0..<len(grid) {
        point_to_cell[grid[i].p] = &grid[i]
    }

    neighbour_set := make(map[v2] bool, context.temp_allocator)
    for point, tris in point_to_tris {
        clear(&neighbour_set)
        
        cell := point_to_cell[point]
        
        for triangle in tris {
                for vertex in triangle {
                if vertex != point {
                    neighbour_set[vertex] = true
                }
            }
        }

        for neighbour_point in neighbour_set {
            neighbour := Neighbour {
                cell = point_to_cell[neighbour_point],
                to_neighbour = neighbour_point - point,
                
            }
            append(&cell.neighbours, neighbour)
        }
    }
    
    for cell in grid {
        for neighbour in cell.neighbours {
            assert(neighbour.cell != nil)
        }
    }
    
    
    delete(average_colors)
    delete(draw_board)
    make(&average_colors, area)
    make(&draw_board, area)
    
    // temp_neighbours:= make([dynamic] Neighbour, context.temp_allocator)
    // for y in 0..<new_dimension.y do for x in 0..<new_dimension.x {
    //     index := x + y * new_dimension.x
    //     cell := &grid[index]
    //     cell.p = vec_cast(f32, x, y) + random_bilateral(entropy, v2) * deviation
    //     cell.collapsed = false
        
    //     delete(cell.states)
    //     make(&cell.states, len(c.states))
    //     for &it, index in cell.states do it = cast(State_Id) index
        
    //     for delta, direction in Deltas {
    //         to := v2i {x, y} + delta
    //         if !dimension_contains(dimension, to) && !wrapping do continue // :Wrapping we reached an edge
            
    //         to = rectangle_modulus(rectangle_min_dimension(v2i{}, dimension), to)
    //         neighbour := Neighbour {
    //             to_neighbour_in_grid = direction,
    //             cell                 = &grid[to.x + to.y * dimension.x],
    //         }
    //         append(&temp_neighbours, neighbour)
    //     }
        
    //     make(&cell.neighbours, len(temp_neighbours))
    //     copy(cell.neighbours, temp_neighbours[:])
    //     clear(&temp_neighbours)
    // }
    
    // for &cell in grid {
    //     for &neighbour in cell.neighbours {
    //         neighbour.to_neighbour = neighbour.cell.p - cell.p
    //     }
    // }
}

world_to_screen :: proc { world_to_screen_rec, world_to_screen_reci, world_to_screen_vec, world_to_screen_v2i }
world_to_screen_reci :: proc (world: Rectangle2i) -> (screen: rl.Rectangle) {
    wmin := world_to_screen(world.min)
    wmax := world_to_screen(world.max)
    screen.x = wmin.x
    screen.y = wmax.y
    dim := abs_vec(wmax - wmin)
    screen.width  = dim.x
    screen.height = dim.y
    return screen
}
world_to_screen_rec :: proc (world: Rectangle2) -> (screen: rl.Rectangle) {
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

direction_to_angles :: proc(direction: v2) -> (angle: f32) {
    angle = atan2(direction.y, direction.x)  * (360 / Tau)
    return angle
}