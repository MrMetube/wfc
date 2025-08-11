package main

import "core:os/os2"
import "core:strings"
import "core:time"

import "core:prof/spall"
spall :: spall

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Deltas := [Direction] v2i { .East = {1,0}, .West = {-1,0}, .North = {0,-1}, .South = {0,1}}

Screen_Size :: v2i{1920, 1080}

// @todo(viktor): measure the total time in updates until is_done

TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

is_done: b32
wrapping: b32

work_queue: WorkQueue

update_state: Update_State
Update_State :: enum {
    Paused, Step, Unpaused,
}

screen_size_factor: f32

average_colors: [] Average_Color
Average_Color :: struct {
    states_count_when_computed: u32,
    color: rl.Color,
}
render_wavefunction_as_average: b32 = true

desired_N: i32 = N

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
desired_dimension := dimension
////////////////////////////////////////////////

Direction :: enum {
    East, North, West, South,
}

search_mode   := Search_Mode.Metric
search_metric := Search_Metric.Entropy

////////////////////////////////////////////////
pixels: []rl.Color
pixels_dimension: v2i

Task :: enum {
    resize_grid, 
    extract_states, 
    clear_drawing, 
    restart, 
    copy_old_grid,
}
Tasks :: bit_set[Task]
do_tasks: Tasks

main :: proc () {
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    camera := rl.Camera2D { zoom = 1 }
    
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    init_work_queue(&work_queue, 0)
    
    File :: struct {
        name: string,
        data: []u8,
        image: rl.Image,
        texture: rl.Texture2D,
        type: string,
        read_time: time.Time,
    }
    
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
                
                image := File {
                    name = copy_string(&arena, info.name),
                    data = data,
                    type = file_type,
                    read_time = time.now(),
                }
                image.image = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                images[info.name] = image
            }
        }
    }
    
    imgui.set_current_context(imgui.create_context(nil))
    rlimgui.ImGui_ImplRaylib_Init()
    
    ////////////////////////////////////////////////
    ////////////////////////////////////////////////
    ////////////////////////////////////////////////
    
    spall_ctx = spall.context_create("trace_test.spall", 10 * time.Millisecond)
	defer spall.context_destroy(&spall_ctx)

	buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
	defer delete(buffer_backing)

	spall_buffer = spall.buffer_create(buffer_backing, 0)
	defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    
    ////////////////////////////////////////////////
    ////////////////////////////////////////////////
    ////////////////////////////////////////////////
    
    entropy := seed_random_series(123)
    collapse: Collapse
    setup_grid(&collapse, dimension, desired_dimension)
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &desired_N, 1, 10)
        imgui.slider_int("Size X", &desired_dimension.x, 3, 300)
        imgui.slider_int("Size Y", &desired_dimension.y, 3, 150)
        if desired_dimension != dimension {
            do_tasks += { .resize_grid }
        }
        
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                if image.image.format == .UNCOMPRESSED_R8G8B8 {
                    pixels = make([]rl.Color, image.image.width * image.image.height, context.temp_allocator)
                    // @leak
                    raw := slice_from_parts([3]u8, image.image.data, image.image.width * image.image.height)
                    for &pixel, index in pixels {
                        pixel.rgb = raw[index]
                        pixel.a   = 255
                    }
                } else if image.image.format == .UNCOMPRESSED_R8G8B8A8 {
                    pixels = slice_from_parts(rl.Color, image.image.data, image.image.width * image.image.height)
                } else {
                    unreachable()
                }
                
                pixels_dimension = {image.image.width, image.image.height}
                do_tasks += { .extract_states }
            }
            imgui.pop_id()
            imgui.next_column()
        }
        imgui.columns(1)
        
        if len(collapse.states) != 0 {
            if imgui.button("Restart") {
                do_tasks += { .restart }
            }
        } else {
            imgui.text("Select an input image")
        }
            
        switch update_state {
          case .Step: 
            update_state = .Paused
            fallthrough
          case .Paused:
           if imgui.button("Unpause") do update_state = .Unpaused
           if imgui.button("Step")    do update_state = .Step
           
          case .Unpaused:
           if imgui.button("Pause") do update_state = .Paused
        }
        
        imgui.checkbox("Average Color", auto_cast &render_wavefunction_as_average)
        
        modes := [Search_Mode] string {
            .Scanline = "top to bottom, left to right",
            .Metric   = "search by a metric",
        }
        metrics := [Search_Metric] string {
            .States   = "fewest possible states",
            .Entropy  = "lowest entropy",
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
        
        imgui.text("Stats")
        tile_count := len(collapse.states)
        imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
        // imgui.text(tprint("Total time %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        
        imgui.text("Drawing")
        if imgui.button("Clear drawing") {
            do_tasks += { .clear_drawing }
        }
        
        imgui.columns(2)
        _id: i32
        if imgui.radio_button("All", selected_group == nil) {
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
        
        sp := rl.GetMousePosition()
        wp := screen_to_world(sp)
        
        dd_brush_size = -rl.GetMouseWheelMove() * min(300, brush_size_speed * brush_size)
        d_brush_size += dd_brush_size * rl.GetFrameTime()
        d_brush_size += -d_brush_size * rl.GetFrameTime() * 10
        brush_size += d_brush_size * rl.GetFrameTime()
        brush_size = clamp(brush_size, 0.3, 10)
        
        if dimension_contains(dimension, wp) {
            if rl.IsMouseButtonDown(.LEFT) {
                diameter := max(1, ceil(i32, brush_size))
                area := rectangle_center_dimension(wp, diameter)
                for y in area.min.y..<area.max.y {
                    for x in area.min.x..<area.max.x {
                        p := v2i{x, y}
                        if dimension_contains(dimension, p) && length_squared(p - wp) < square(diameter) {
                            index := x + y * dimension.x
                            draw_board[index] = selected_group
                            if selected_group != nil {
                                restrict_cell_to_drawn(&collapse, p, selected_group)
                            } else {
                                //  @copypasta from restart
                                cell := &grid[index]
                                wave, ok := &cell.value.(WaveFunction)
                                if ok {
                                    delete(wave.supports)
                                } else {
                                    cell.value = WaveFunction  {}
                                    wave = &cell.value.(WaveFunction)
                                }
                                
                                wave.supports = make([dynamic] Supported_State, len(collapse.states))
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
        
        ////////////////////////////////////////////////
        // Update 
        
        // @todo(viktor): if drawing_initializing and do_restart do Tell the user that their drawing may be unsolvable
        
        old_dimension, new_dimension := dimension, dimension
        old_grid := grid
        if .resize_grid in do_tasks {
            do_tasks -= { .resize_grid }
            old_dimension = dimension
            new_dimension = desired_dimension
            setup_grid(&collapse, dimension, desired_dimension)
            
            do_tasks += { .restart, .copy_old_grid }
        }
        
        if .extract_states in do_tasks {
            do_tasks -= { .extract_states }
            assert(pixels != nil)
            defer pixels = nil
            
            N = desired_N
            reset_collapse(&collapse)
            extract_states(&collapse, pixels, pixels_dimension.x, pixels_dimension.y)
                
            do_tasks += { .restart, .clear_drawing }
        }
        
        if .clear_drawing in do_tasks {
            do_tasks -= { .clear_drawing }
            clear_draw_board()
            do_tasks += { .restart }
        }
        
        if .restart in do_tasks {
            do_tasks -= { .restart }
            restart(&collapse)
            for &it in average_colors do it = {}
        }
        
        if .copy_old_grid in do_tasks {
            do_tasks -= { .copy_old_grid }
            defer delete(old_grid)
            
            // @todo(viktor): When growing handle that it must connect to existing.
            if !wrapping && old_grid != nil && new_dimension != old_dimension {
                delta := abs_vec(new_dimension - old_dimension) / 2
                if (new_dimension.x > old_dimension.x || new_dimension.y > old_dimension.y) {
                    for y in 0..<old_dimension.y {
                        for x in 0..<old_dimension.x {
                            grid[(x + delta.x) + (y + delta.y) * new_dimension.x].value = old_grid[x + y * old_dimension.x].value
                        }
                    }
                } else {
                    for y in 0..<new_dimension.y {
                        for x in 0..<new_dimension.x {
                            grid[x + y * new_dimension.x].value = old_grid[(x + delta.x) + (y + delta.y) * old_dimension.x].value
                        }
                    }
                }
            }
        }
        
        update(&collapse, &entropy)
        
        ////////////////////////////////////////////////
        // Render
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        rl.BeginMode2D(camera)
        
        if collapse.states != nil {
            if textures_length != len(collapse.states) {
                for it in textures_and_images do rl.UnloadTexture(it.texture)
                
                textures_length = len(collapse.states)
                resize(&textures_and_images, textures_length)
                
                for &state, index in collapse.states {
                    image := rl.Image {
                        data = raw_data(state.values),
                        width  = N,
                        height = N,
                        mipmaps = 1,
                        format = .UNCOMPRESSED_R8G8B8A8,
                    }
                    
                    textures_and_images[index].image   = image
                    textures_and_images[index].texture = rl.LoadTextureFromImage(image)
                }
            }
        }
        
        is_done = true
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                index := x + y * dimension.x
                cell := grid[index]
                p := world_to_screen({x, y})
                
                rect := rl.Rectangle {p.x, p.y, screen_size_factor, screen_size_factor}
                switch value in cell.value {
                  case WaveFunction: 
                    is_done = false
                    if len(value.supports) == 0 {
                        color := rl.Color { 255, 0, 255, 255 }
                        rl.DrawRectangleRec(rect, color)
                    } else {
                        if render_wavefunction_as_average {
                            average := &average_colors[index]
                            if average.states_count_when_computed != auto_cast len(value.supports) {
                                average.states_count_when_computed = auto_cast len(value.supports)
                                
                                color: [4]f32
                                count: f32
                                for support in value.supports {
                                    state := collapse.states[support.id]
                                    value := cast([4]u8) state.values[N/4+N/4*N] // middle
                                    color += rgba_to_v4(value) * cast(f32) state.frequency
                                    count += cast(f32) state.frequency
                                }
                                
                                if count > 0 {
                                    color /= count
                                }
                                
                                average.color = cast(rl.Color) v4_to_rgba(color)
                            }
                            rl.DrawRectangleRec(rect, average.color)
                            // rl.DrawRectangleLinesEx(rect, 4,  rl.BLACK)
                            // rl.DrawRectangleLinesEx(rect, 1,  rl.WHITE)
                        } else {
                            rl.DrawRectangleRec(rect, {0,255,255,32})
                        }
                    }
                    
                  case State_Id:
                    values := collapse.states[value].values
                    color := values[N/4+N/4*N] // middle
                    rl.DrawRectangleRec(rect, color)
                }
            }
        }
        
        for p, _ in changes {
            p := world_to_screen(p)
            rl.DrawRectangleRec({p.x, p.y, screen_size_factor, screen_size_factor}, rl.ColorAlpha(rl.YELLOW, 0.4))
        }
        
        if to_be_collapsed != nil {
            p := world_to_screen(to_be_collapsed.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, screen_size_factor, screen_size_factor}, rl.ColorAlpha(color, 0.8))
        }
        
        if dimension_contains(dimension, wp) {
            wsp := world_to_screen(wp)
            rect := rl.Rectangle {wsp.x, wsp.y, screen_size_factor, screen_size_factor}
            
            color := selected_group == nil ? rl.RAYWHITE : selected_group.color
            rl.DrawRectangleRec(rect, color)
            rl.DrawCircleLinesV(sp,   brush_size * screen_size_factor, rl.YELLOW)
        }
        
        rl.EndMode2D()
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

setup_grid :: proc (c: ^Collapse, old_dimension, new_dimension: v2i) {
    dimension = new_dimension
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, new_dimension+10)
    if ratio.x < ratio.y {
        screen_size_factor = ratio.x
    } else {
        screen_size_factor = ratio.y 
    }
    
    delete(average_colors)
    delete(draw_board)
    
    area := new_dimension.x * new_dimension.y
    make(&grid, area)
    make(&average_colors, area)
    make(&draw_board, area)
    for y in 0..<new_dimension.y do for x in 0..<new_dimension.x do grid[x + y * new_dimension.x].p = {x, y}
}

clear_draw_board :: proc () {
    for &it in draw_board do it = nil
}

restrict_cell_to_drawn :: proc (c: ^Collapse, p: v2i, group: ^Draw_Group) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
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

world_to_screen :: proc (p: v2i) -> (result: v2) {
    result = vec_cast(f32, p) * screen_size_factor
    
    result += (vec_cast(f32, Screen_Size) - (screen_size_factor * vec_cast(f32, dimension))) * 0.5
    
    return result
}

screen_to_world :: proc (screen: v2) -> (world: v2i) {
    world  = vec_cast(i32, (screen - (vec_cast(f32, Screen_Size) - (screen_size_factor * vec_cast(f32, dimension))) * 0.5) / screen_size_factor)
    
    return world
}