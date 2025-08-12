package main

import "core:os/os2"
import "core:strings"
import "core:time"

// @todo(viktor): Minesweeper fields should be possible to generate if you also count diagonal edges in the extraction

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Deltas := [Direction] v2i { 
    .East  = { 1, 0}, 
    .West  = {-1, 0}, 
    .North = { 0,-1}, 
    .South = { 0, 1},
}

Screen_Size :: v2i{1920, 1080}

TargetFps       :: 144
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
    ids:   []b32,
}

brush_size_speed: f32 = 60
brush_size: f32 = 2
d_brush_size: f32 = 0
dd_brush_size: f32 = 0

// @todo(viktor): Rethink this api now that I kinda know what I want to be able to do
drawing_initializing: b32
selected_group: ^Draw_Group
draw_board:     [] ^Draw_Group
draw_groups:    [dynamic] Draw_Group

dimension: v2i = {150, 100}

File :: struct {
    data:    [] u8,
    image:   rl.Image,
    texture: rl.Texture2D,
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
    
    // extract states
    desired_N: i32,  // @todo(viktor): cant change this in UI it snaps back
    pixels: []rl.Color,
    pixels_dimension: v2i,
    
    // resize grid
    desired_dimension: v2i,
    old_dimension: v2i,
    old_grid: [] Cell,
}

Task :: enum {
    resize_grid, 
    extract_states, 
    clear_drawing, 
    restart, 
    copy_old_grid,
    update,
}

@(no_instrumentation)
main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    init_spall()
    
    camera := rl.Camera2D { zoom = 1 }
    
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    w: WorkQueue
    h: WorkQueue
    init_work_queue(&h, "High queue", 2)
    init_work_queue(&w, "Low queue", 2)
    
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

    entropy := seed_random_series(123)
    collapse: Collapse
    setup_grid(&collapse, dimension, dimension)
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
        // this_frame.desired_N = N
        this_frame.pixels = nil
        this_frame.pixels_dimension = {}
        this_frame.old_grid = nil
        
        ui(&collapse, images)
        sp := rl.GetMousePosition()
        wp := screen_to_world(sp)
        
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
                                //  @copypasta from restart
                                // @todo(viktor): :Constrained the current implementation does not consider existing constraints
                                cell := &grid[index]
                                wave, ok := &cell.value.(WaveFunction)
                                if ok {
                                    delete(wave.supports)
                                } else {
                                    cell.value = WaveFunction  {}
                                    wave = &cell.value.(WaveFunction)
                                }
                                
                                make(&wave.supports, len(collapse.states))
                                for &it, index in wave.supports {
                                    it.id = cast(State_Id) index
                                    for &amount, direction in it.amount {
                                        amount = maximum_support[it.id][direction]
                                    }
                                }
                                
                                delete_key(&changes, p)
                            }
                        }
                    }
                }
            }
            
        }
        
        // if collapse.states != nil {
        //     if textures_length != len(collapse.states) {
        //         for it in textures_and_images do rl.UnloadTexture(it.texture)
                
        //         textures_length = len(collapse.states)
        //         resize(&textures_and_images, textures_length)
                
        //         for &state, index in collapse.states {
        //             image := rl.Image {
        //                 data = raw_data(state.values),
        //                 width  = N,
        //                 height = N,
        //                 mipmaps = 1,
        //                 format = .UNCOMPRESSED_R8G8B8A8,
        //             }
                    
        //             textures_and_images[index].image   = image
        //             textures_and_images[index].texture = rl.LoadTextureFromImage(image)
        //         }
        //     }
        // }
        
        ////////////////////////////////////////////////
        // Update 
        update_start: time.Time
        
        for this_frame.tasks != {} {
            // @todo(viktor): if drawing_initializing and do_restart: Tell the user that their drawing may be unsolvable
            if .resize_grid in this_frame.tasks {
                this_frame.tasks -= { .resize_grid }
                
                this_frame.old_grid = grid
                this_frame.old_dimension = dimension
                setup_grid(&collapse, dimension, this_frame.desired_dimension)
                
                this_frame.tasks += { .restart, .copy_old_grid }
            }
            
            if .extract_states in this_frame.tasks {
                this_frame.tasks -= { .extract_states }
                
                assert(this_frame.pixels != nil)
                
                N = this_frame.desired_N
                reset_collapse(&collapse)
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
                using this_frame
                new_dimension := desired_dimension
                
                // @cleanup
                // @todo(viktor): :Constrained When growing handle that it must connect to existing.
                if !wrapping && old_grid != nil && new_dimension != old_dimension {
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
        
        ////////////////////////////////////////////////
        // Render
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        rl.BeginMode2D(camera)
        
        rl.DrawRectangleRec(
            to_rl_rectangle(
                rectangle_min_dimension(world_to_screen({0,0}), 
                vec_cast(f32, dimension) * cell_size_on_screen),
            ), {0,255,255,32},
        )
        
        /* @todo(viktor): 
        1 - abstract support in a direction to allow that lookup to be as complex as needed
        2 - remove Direction from the grid / wavefunction and just work with the respective vector
        3 - display the neighbour likelyhood on a circle of each color with each other color
        4 - interpolate the likelyhood over the whole circle
        5 - make a graph/lattice that is still a regular grid
        6 - make the lattice irregular
        7 - display the lattice as a voronoi diagram
        */
        
        for cell, index in grid {
            average := &average_colors[index]
            
            switch value in cell.value {
              case WaveFunction: 
                if len(value.supports) == 0 {
                    average.color = { 255, 0, 255, 255 }
                    unreachable()
                }
                
                if render_wavefunction_as_average {
                    // @todo(viktor): also allow for most likely color
                    if average.states_count_when_computed != auto_cast len(value.supports) {
                        average.states_count_when_computed = auto_cast len(value.supports)
                        
                        color: v4
                        count: f32
                        for support in value.supports {
                            state    := collapse.states[support.id]
                            color_id := state.values[N/4+N/4*N] // middle
                            color += rl_color_to_v4(collapse.values[color_id]) * cast(f32) state.frequency
                            count += cast(f32) state.frequency
                        }
                        
                        color = safe_ratio_0(color, count)
                        average.color = cast(rl.Color) v4_to_rgba(color * {1,1,1,0.3})
                    }
                }
                
              case State_Id:
                state    := collapse.states[value]
                color_id := state.values[N/4+N/4*N] // middle
                average.color = collapse.values[color_id]
                average.states_count_when_computed = 1
            }
        
        }
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                index   := x + y * dimension.x
                p       := world_to_screen({x, y})
                rect    := rectangle_min_dimension(p, cell_size_on_screen)
                average := &average_colors[index]
                if average.states_count_when_computed == 1 {
                    rl.DrawRectangleRec(to_rl_rectangle(rect), average.color)
                } else {
                    if render_wavefunction_as_average {
                        rl.DrawCircleV(get_center(rect), get_dimension(rect).x / 2, average.color)
                    }
                }
            }
        }

        if highlight_drawing {
            for y in 0..<dimension.y {
                for x in 0..<dimension.x {
                    index := x + y * dimension.x
                    drawn := draw_board[index]
                    if drawn != nil {
                        p := world_to_screen({x, y})
                        rect := rectangle_min_dimension(p, cell_size_on_screen)
                        rl.DrawRectangleRec(to_rl_rectangle(rect), rl.ColorAlpha(drawn.color, 0.7))
                    }
                }
            }
        }
        
        if highlight_changes {
            for p, _ in changes {
                p := world_to_screen(p)
                rl.DrawRectangleRec({p.x, p.y, cell_size_on_screen, cell_size_on_screen}, rl.ColorAlpha(rl.YELLOW, 0.4))
            }
        }
        
        if to_be_collapsed != nil {
            p := world_to_screen(to_be_collapsed.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, cell_size_on_screen, cell_size_on_screen}, rl.ColorAlpha(color, 0.8))
        }
        
        if dimension_contains(dimension, wp) {
            wsp := world_to_screen(wp)
            rect := rl.Rectangle {wsp.x, wsp.y, cell_size_on_screen, cell_size_on_screen}
            
            color := selected_group == nil ? rl.RAYWHITE : selected_group.color
            rl.DrawRectangleRec(rect, color)
            rl.DrawCircleLinesV(sp,   brush_size * cell_size_on_screen, rl.YELLOW)
        }
        
        rl.EndMode2D()
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

setup_grid :: proc (c: ^Collapse, old_dimension, new_dimension: v2i) {
    dimension = new_dimension // @todo(viktor): this is a really stupid idea
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, new_dimension+10)
    if ratio.x < ratio.y {
        cell_size_on_screen = ratio.x
    } else {
        cell_size_on_screen = ratio.y 
    }
    
    delete(average_colors)
    delete(draw_board)
    
    area := new_dimension.x * new_dimension.y
    make(&grid, area)
    make(&average_colors, area)
    make(&draw_board, area)
    for y in 0..<new_dimension.y do for x in 0..<new_dimension.x do grid[x + y * new_dimension.x].p = {x, y}
}

ui :: proc (c: ^Collapse, images: map[string] File) {
    imgui.begin("Extract")
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &this_frame.desired_N, 1, 10)
        imgui.slider_int("Size X", &this_frame.desired_dimension.x, 3, 300)
        imgui.slider_int("Size Y", &this_frame.desired_dimension.y, 3, 150)
        if this_frame.desired_dimension != dimension {
            this_frame.tasks += { .resize_grid }
        }
        
        if len(c.states) == 0 {
            imgui.text("Select an input image")
        }
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                if image.image.format == .UNCOMPRESSED_R8G8B8 {
                    make(&this_frame.pixels, image.image.width * image.image.height, context.temp_allocator)
                    // @leak
                    raw := slice_from_parts([3]u8, image.image.data, image.image.width * image.image.height)
                    for &pixel, index in this_frame.pixels {
                        pixel.rgb = raw[index]
                        pixel.a   = 255
                    }
                } else if image.image.format == .UNCOMPRESSED_R8G8B8A8 {
                    this_frame.pixels = slice_from_parts(rl.Color, image.image.data, image.image.width * image.image.height)
                } else {
                    unreachable()
                }
                
                this_frame.pixels_dimension = {image.image.width, image.image.height}
                this_frame.tasks += { .extract_states }
            }
            imgui.pop_id()
            imgui.next_column()
        }
        imgui.columns(1)
    imgui.end()
    
    imgui.text("Stats")
    tile_count := len(c.states)
    imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
    imgui.text(tprint("Total time %",  view_time_duration(total_duration, show_limit_as_decimal = true, precision = 3)))
    
    if len(c.states) != 0 {
        if imgui.button("Restart") {
            this_frame.tasks += { .restart }
        }
    }
    
    if paused {
        if imgui.button("Unpause") do paused = false
        if imgui.button("Step")    {
            this_frame.tasks += { .update }
        }
    } else {
        if imgui.button("Pause") do paused = true
        this_frame.tasks += { .update }
    }
    
    imgui.checkbox("Average Color", &render_wavefunction_as_average)
    imgui.checkbox("Highlight changing cells", &highlight_changes)
    imgui.checkbox("Overlay drawing", &highlight_drawing)
    
    modes := [Search_Mode] string {
        .Scanline = "top to bottom, left to right",
        .Metric   = "search by a metric",
    }
    metrics := [Search_Metric] string {
        .States  = "fewest possible states",
        .Entropy = "lowest entropy",
    }
    for text, mode in modes {
        if imgui.radio_button(text, mode == search_mode) {
            search_mode = mode
        }
    }
    if search_mode == .Metric {
        imgui.tree_push("Metric")
        for text, metric in metrics {
            if imgui.radio_button(text, metric == search_metric) {
                search_metric = metric
            }
        }
        imgui.tree_pop()
    }
    
    imgui.begin("Drawing")
        if imgui.button("Clear drawing") {
            this_frame.tasks += { .clear_drawing }
        }
        
        imgui.columns(2)
        if imgui.radio_button("Erase", selected_group == nil) {
            selected_group = nil
        }
        imgui.next_column()
        imgui.next_column()
        
        for &group, index in draw_groups {
            selected := &group == selected_group
            if imgui.radio_button(tprint("%", index), selected) {
                selected_group = &group
            }
            imgui.next_column()
            
            flags: imgui.Color_Edit_Flags = .NoPicker | .NoOptions | .NoSmallPreview | .NoInputs | .NoTooltip | .NoSidePreview | .NoDragDrop
            imgui.color_button("", rgba_to_v4(cast([4]u8) group.color), flags = flags)
            imgui.next_column()
        }
        imgui.columns()
    imgui.end()
}

clear_draw_board :: proc () {
    for &it in draw_board do it = nil
}

restrict_cell_to_drawn :: proc (c: ^Collapse, p: v2i, group: ^Draw_Group) {
    selected := group.ids
    
    cell := &grid[p.x + p.y * dimension.x]
    if wave, ok := cell.value.(WaveFunction); ok {
        for it in wave.supports {
            is_selected:= selected[it.id]
            if !is_selected {
                remove_state(c, p, it.id)
            }
        }
    }
}

@(no_instrumentation)
world_to_screen :: proc (p: v2i) -> (result: v2) {
    result = vec_cast(f32, p) * cell_size_on_screen
    
    result += (vec_cast(f32, Screen_Size) - (cell_size_on_screen * vec_cast(f32, dimension))) * 0.5
    
    return result
}

screen_to_world :: proc (screen: v2) -> (world: v2i) {
    world = vec_cast(i32, (screen - (vec_cast(f32, Screen_Size) - (cell_size_on_screen * vec_cast(f32, dimension))) * 0.5) / cell_size_on_screen)
    
    return world
}