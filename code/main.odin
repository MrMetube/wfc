package main

import "core:os/os2"
import "core:strings"
import "core:time"

import "core:prof/spall"

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Deltas := [Direction] v2i { .East = {1,0}, .West = {-1,0}, .North = {0,-1}, .South = {0,1}}

Screen_Size :: v2i{1920, 1080}

// @todo(viktor): make time spent accumalative and dont count paused time
_total: time.Duration
_total_start: time.Time


TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////
// App

should_restart: b32
t_restart: f32
is_done: b32

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
    _ids:   []b32,
}

brush_size_speed: f32 = 30
brush_size: f32 = 1
d_brush_size: f32 = 0
dd_brush_size: f32 = 0

drawing_initializing: b32
selected_group: ^Draw_Group
draw_board:     [] ^Draw_Group
draw_groups:    [dynamic] Draw_Group

////////////////////////////////////////////////

////////////////////////////////////////////////

 /*
 * if we ignore even N values then the difference between overlapping and tiled mode is:
 * overlapping: tiles match on a side if N-1 rows/columns match
 * tiled:       tiles match on a side if   1 row/column matches
 * 
 * overlapping: extract NxN at every pixel
 * tiled:       extract NxN at every N-th pixel
*/
N: i32 = 3
mirror_input: bool

first_time := true

dimension: v2i = {150, 100}
grid: [] Cell

Cell :: struct {
    p: v2i,
    
    value: union {
        Collapsed,
        WaveFunction,
    },
}

Collapsed :: State_Id
WaveFunction :: struct {
    supports: [dynamic] Support,
}

supports: [/* from State_Id */] [Direction] [dynamic/* ascending */] Directional_Support
Directional_Support :: struct {
    id:     State_Id,
    amount: i32,
}
Support :: struct {
    id:     State_Id,
    amount: [Direction] i32,
}

maximum_support: [][Direction] i32

Direction :: enum {
    East, North, West, South,
}

states_direction: Direction

to_be_collapsed: ^Cell

doing_changes: b32
changes: map[v2i]Change
Change :: struct {
    removed_support: [Direction] [/* State_Id */] Directional_Support,
}

search_mode := Search_Mode.Entropy

main :: proc () {
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, dimension+10)
    if ratio.x < ratio.y {
        screen_size_factor = ratio.x
    } else {
        screen_size_factor = ratio.y 
    }
    
    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    camera := rl.Camera2D { zoom = 1 }
    
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    init_work_queue(&work_queue, 11)
    
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
                _total_start = time.now()
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
    
    make(&grid, dimension.x * dimension.y)
    make(&average_colors, dimension.x * dimension.y)
    make(&draw_board, dimension.x * dimension.y)
    
    for y in 0..<dimension.y do for x in 0..<dimension.x do grid[x + y * dimension.x].p = {x, y}
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &desired_N, 1, 10)
        imgui.checkbox("Mirror", &mirror_input)
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                pixels: []rl.Color
                if image.image.format == .UNCOMPRESSED_R8G8B8 {
                    pixels = make([]rl.Color, image.image.width * image.image.height)
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
                
                N = desired_N
                reset_collapse(&collapse)
                extract_tiles(&collapse, pixels, image.image.width, image.image.height)
                
                restart(&collapse)
                
                first_time = true
                should_restart = true
                t_restart = 0
            }
            imgui.pop_id()
            imgui.next_column()
        }
        imgui.columns(1)
        
        if len(collapse.states) != 0 {
            if imgui.button(should_restart ? tprint("Restarting in %", view_seconds(t_restart, precision = 3)) : "Restart") {
                if !should_restart {
                    should_restart = true
                    t_restart = 0.3
                } else {
                    t_restart = 0
                }
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
            .States   = "fewest possible states",
            .Entropy  = "lowest entropy",
        }
        for text, mode in modes {
            if imgui.radio_button(text, mode == search_mode) {
                search_mode = mode
            }
        }
        
        imgui.text("Stats")
        tile_count := len(collapse.states)
        imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
        imgui.text(tprint("Total time %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        
        imgui.text("Pick a color to Draw")
        if imgui.button("Clear drawing") {
            clear_draw_board()
            restart(&collapse)
        }
        imgui.columns(4)
        _id: i32
        for &group, index in draw_groups {
            selected := &group == selected_group
            if imgui.radio_button(tprint("%", index), selected) {
                selected_group = selected ? nil : &group
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
            if selected_group != nil {
                if rl.IsMouseButtonDown(.LEFT) {
                    diameter := max(1, round(i32, brush_size))
                    area := rectangle_center_dimension(wp, diameter)
                    for y in area.min.y..<area.max.y {
                        for x in area.min.x..<area.max.x {
                            p := v2i{x, y}
                            if dimension_contains(dimension, p) && length_squared(p - wp) < square(diameter) {
                                index := x + y * dimension.x
                                draw_board[index] = selected_group
                                restrict_cell_to_drawn(&collapse, p, selected_group)
                            }
                        }
                    }
                }
            }
        }
        
        ////////////////////////////////////////////////
        // Update 
        
        if !should_restart {
            update(&collapse, &entropy)
        } else {
            if drawing_initializing {
                // @todo(viktor): Tell the user it doesnt work
                update_state = .Paused
            } else {
                t_restart -= rl.GetFrameTime()
                if t_restart <= 0 {
                    t_restart = 0
                    should_restart = false
                    
                    if first_time {
                        _total_start = time.now()
                        first_time = false
                    } else {
                        restart(&collapse)
                    }
                }
            }
            
            if !is_done {
                _total = time.since(_total_start)
            }
        }
        
        ////////////////////////////////////////////////
        // Render
        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Render")
        
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
                    
                  case Collapsed:
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
        
        if selected_group != nil {
            if dimension_contains(dimension, wp) {
                wsp := world_to_screen(wp)
                rect := rl.Rectangle {wsp.x, wsp.y, screen_size_factor, screen_size_factor}
                
                rl.DrawRectangleRec(rect, selected_group.color)
                rl.DrawCircleLinesV(sp,   brush_size * screen_size_factor, rl.YELLOW)
            }
        }
        
        rl.EndMode2D()
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

spall :: spall

update :: proc (c: ^Collapse, entropy: ^RandomSeries) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    update_start := time.now()
    
    update: for {
        if c.states == nil do break update
        
        if !doing_changes {
            if to_be_collapsed == nil {
                // Find next cell to be collapsed 
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Find next cell to be collapsed")
                
                Data :: struct {
                    search:  Search,
                    
                    grid_section:  [] Cell,
                    found_invalid: b32,
                    reached_end: b32,
                }
                
                rows := dimension.y / 4
                work_units := make([] Data, rows, context.temp_allocator)
                for &work, row in work_units {
                    size := dimension.x * 4
                    work.grid_section = grid[cast(i32) row * size:][:size]
                    
                    init_search(&work.search, c, search_mode, context.temp_allocator)
                    
                    enqueue_work_t(&work_queue, &work, proc (work: ^Data) {
                        using work
                        loop: for &cell in grid_section {
                            if wave, ok := &cell.value.(WaveFunction); ok {
                                switch test_search_cell(&search, &cell, wave) {
                                case .Continue: // nothing
                                case .Done:     break loop
                                
                                case .Found_Invalid: 
                                    found_invalid = true
                                    break loop
                                }
                            }
                        }
                        
                        reached_end = true
                    })
                }
                complete_all_work(&work_queue)
                
                // join 
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Join searches")
                
                all_reached_end := true
                minimal: Search
                init_search(&minimal, c, search_mode, context.temp_allocator)
                
                least: for work in work_units {
                    all_reached_end &&= work.reached_end
                    if work.found_invalid {
                        should_restart = true
                        break update
                    } else {
                        if len(work.search.cells) > 0 {
                            if search_mode == .Scanline {
                                minimal = work.search
                                break least
                            }
                            
                            // @todo(viktor): Scanline needs special handling herre and in the test_search_cell, just make it a special case in general. It should also not need the multithreaded search as it is always just the first value
                            assert(search_mode != .Scanline)
                            if minimal.lowest > work.search.lowest {
                                minimal = work.search
                            } else if minimal.lowest == work.search.lowest {
                                append(&minimal.cells, ..work.search.cells[:])
                            }
                        }
                    }
                }
                
                if len(minimal.cells) > 0 {
                    to_be_collapsed = random_value(entropy, minimal.cells[:])
                } else {
                    if all_reached_end {
                        break update
                    }
                }
            } else {
                // Collapse chosen cell
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Collapse chosen cell")
                
                wave := to_be_collapsed.value.(WaveFunction)
                pick := Invalid_Id
                if len(wave.supports) == 1 {
                    pick = wave.supports[0].id
                } else {
                    if update_state == .Paused {
                        to_be_collapsed = nil
                        break update
                    }
                    
                    // Random
                    total_frequency: i32
                    for support in wave.supports {
                        total_frequency += c.states[support.id].frequency
                    }
                    
                    target := random_between(entropy, i32, 0, total_frequency)
                    picking: for support in wave.supports {
                        state := &c.states[support.id]
                        target -= state.frequency
                        if target <= 0 {
                            pick = support.id
                            break picking
                        }
                    }
                    assert(pick != Invalid_Id)
                }
                
                if pick != Invalid_Id {
                    for support in wave.supports {
                        id := support.id
                        if pick != id {
                            remove_state(c, to_be_collapsed.p, id)
                        }
                    }
                    
                    delete(wave.supports)
                    to_be_collapsed.value = pick
                    to_be_collapsed = nil
                    doing_changes = true
                }
            }
        } else {
            // Propagate changes
            spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Propagate changes")
            
            if len(changes) == 0 {
                drawing_initializing = false
                doing_changes = false
            } else {
                change_p: v2i
                change: Change
                for k, v in changes {
                    change_p = k
                    change = v
                    break
                }
                delete_key(&changes, change_p)
                assert(len(change.removed_support) > 0)
                
                for delta, direction in Deltas {
                    to_p := change_p + delta
                    // @wrapping
                    if !dimension_contains(dimension, to_p) do continue 
                    
                    to_cell := &grid[to_p.x + to_p.y * dimension.x]
                    to_wave, ok := &to_cell.value.(WaveFunction)
                    if !ok do continue 
                    
                    #reverse for &to_support, sup_index in to_wave.supports {
                        removed := change.removed_support[direction][to_support.id]
                        if removed.id != to_support.id do continue
                        
                        amount := &to_support.amount[direction]
                        assert(amount^ != 0)
                        
                        amount^ -= removed.amount
                        // assert(amount^ >= 0) // this could become negative if the user draws in and thereby removes states
                        
                        if amount^ <= 0 {
                            remove_state(c, to_p, to_support.id)
                            
                            unordered_remove(&to_wave.supports, sup_index)
                            if len(to_wave.supports) == 0 {
                                should_restart = true
                                break update
                            }
                        }
                    }
                }
            }
        }
        
        if false && time.duration_seconds(time.since(update_start)) > TargetFrameTime * 0.9 {
            break update
        }
    }
}

remove_state :: proc (c: ^Collapse, p: v2i, removed_state: State_Id) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    
    change, ok := &changes[p]
    if !ok {
        changes[p] = {}
        change = &changes[p]
    }
    
    for direction in Direction {
        for removed in supports[removed_state][direction] {
            if change.removed_support[direction] == nil {
                change.removed_support[direction] = make([] Directional_Support, len(c.states))
            }
            change.removed_support[direction][removed.id].id = removed.id
            change.removed_support[direction][removed.id].amount += removed.amount
        }
    }
}

restart :: proc (c: ^Collapse) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    
    clear(&changes)
    to_be_collapsed = nil
    
    for y in 0..<dimension.y {
        for x in 0..<dimension.x {
            cell := &grid[x + y * dimension.x]
            wave, ok := &cell.value.(WaveFunction)
            if ok {
                delete(wave.supports)
            } else {
                cell.value = WaveFunction  {}
                wave = &cell.value.(WaveFunction)
            }
            
            wave.supports = make([dynamic] Support, len(c.states))
            for &it, index in wave.supports {
                it.id = cast(State_Id) index
                for &amount, direction in it.amount {
                    support_now := maximum_support[it.id][direction]
                    amount = support_now
                }
            }
        }
        print("Restart: initialize support % %% \r", view_percentage(y, dimension.y))
    }
    println("Restart: initialize support done           ")
    
    for y in 0..<dimension.y {
        for x in 0..<dimension.x {
            group := draw_board[x + y * dimension.x]
            if group != nil {
                restrict_cell_to_drawn(c, {x, y}, group)
                drawing_initializing = true
            }
        }
    }
}

clear_draw_board :: proc () {
    for &it in draw_board do it = nil
}

restrict_cell_to_drawn :: proc (c: ^Collapse, p: v2i, group: ^Draw_Group) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    selected := group._ids
    
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
        
extract_tiles :: proc (c: ^Collapse, pixels: []rl.Color, width, height: i32) {
    for &group in draw_groups {
        delete(group._ids)
    }
    clear(&draw_groups)
    selected_group = nil
    clear_draw_board()
    
    // @incomplete: Allow for rotations and mirroring here
    if mirror_input {
        // @incomplete: Assuming mirror on x axis
        for by in 0..<height {
            for bx in 0..<width {
                begin_state(c)
                for dy in 0..<N {
                    for dx := N-1; dx >= 0; dx -= 1 {
                        x := (bx + dx) % width
                        y := (by + dy) % height
                        append_state_value(c, pixels[x + y * width])
                    }
                }
                end_state(c)
            }
        
            print("Extraction: State extraction % %%\r", view_percentage(by, height))
        }
        println("Extraction: State extraction done         ")
    }
    
    for by in 0..<height {
        for bx in 0..<width {
            begin_state(c)
            for dy in 0..<N {
                for dx in 0..<N {
                    x := (bx + dx) % width
                    y := (by + dy) % height
                    append_state_value(c, pixels[x + y * width])
                }
            }
            end_state(c)
        }
    
        print("Extraction: State extraction % %%\r", view_percentage(by, height))
    }
    println("Extraction: State extraction done         ")
    
    offsets := [Direction] v2i {
        .East  = {-1,0},
        .North = {0, 1},
        .West  = { 1,0},
        .South = {0,-1},
    }
    
    for a in supports do for d in a do delete(d)
    delete(supports)
    supports = make([][Direction][dynamic] Directional_Support, len(c.states))
    
    for a, a_index in c.states {
        assert(a.id == auto_cast a_index)
        for offset, d in offsets {
            region := rectangle_min_dimension(cast(i32) 0, 0, N, N)
            dim := get_dimension(region)
            for b in c.states {
                does_match: b8 = true
                // @speed we could hash these regions and only compare hashes in the n²-loop
                loop: for y: i32; y < dim.y; y += 1 {
                    for x: i32; x < dim.x; x += 1 {
                        ap := v2i{x, y}
                        bp := v2i{x, y} + offset
                        
                        if contains(region, bp) {
                            a_value := a.values[ap.x + ap.y * dim.x]
                            b_value := b.values[bp.x + bp.y * dim.x]
                            if a_value != b_value {
                                does_match = false
                                break loop
                            }
                        }
                    }
                }
            
                if does_match {
                    found_support: b32
                    for &support in supports[a.id][d] {
                        if support.id == b.id {
                            found_support = true
                            support.amount += 1
                        }
                    }
                    // @todo(viktor): Think if this is even reasonably
                    if !found_support {
                        append(&supports[a.id][d], Directional_Support {b.id, 1})
                    }
                }
            }
        }
        
        print("Extraction: Supports generation % %%\r", view_percentage(a_index, len(c.states)))
    }
    println("Extraction: Supports generation done        ")

    for state in c.states {
        color := state.values[1 + 1 * N] // middle
        group: ^Draw_Group
        for &it in draw_groups {
            if it.color == color {
                group = &it
                break
            }
        }
        if group == nil {
            append(&draw_groups, Draw_Group { color = color })
            group = &draw_groups[len(draw_groups)-1]
            make(&group._ids, len(c.states))
        }
        
        group._ids[state.id] = true
    }
    
    delete(maximum_support)
    maximum_support = make([][Direction] i32, len(c.states))
        
    for from, index in c.states {
        for direction in Direction {
            for support in supports[from.id][direction] {
                amount := &maximum_support[support.id][direction]
                amount^ += support.amount
            }
        }
        print("Extraction: calculate maximum support % %% \r", view_percentage(index, len(c.states)))
    }
    println("Extraction: calculate maximum support done          ")
}

opposite :: proc (direction: Direction) -> Direction {
    switch direction {
      case .East: return .West
      case .West: return .East
      case .North: return .South
      case .South: return .North
    }
    unreachable()
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