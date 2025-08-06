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
update_state: Update_State
Update_State :: enum {
    Paused, Step, Unpaused, Done,
}

screen_size_factor: f32

average_colors: [] Average_Color
Average_Color :: struct {
    states_count_when_computed: u32,
    color: rl.Color,
}
render_wavefunction_as_average: b32 = true

////////////////////////////////////////////////

////////////////////////////////////////////////

 /*
 * if we ignore even N values then the difference between overlapping and tiled mode is:
 * overlapping: tiles match on a side if N-1 rows/columns match
 * tiled:       tiles match on a side if   1 row/column matches
*/
N: i32 = 3

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

selected_group: int = -1
draw_groups:    [dynamic] Draw_Group
Draw_Group :: struct {
    color: rl.Color,
    ids:   [dynamic]State_Id
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

textures_length: int
textures_and_images: [dynamic] struct {
    image:   rl.Image,
    texture: rl.Texture,
}
states_direction: Direction

to_be_collapsed: ^Cell

changes: [dynamic] Change
changes_cursor: int

Change :: struct {
    p: v2i,
    removed_support: [Direction] [/* State_Id */] Directional_Support,
}

Search_Mode :: enum {
    Scanline, States, Entropy, 
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
    
    for y in 0..<dimension.y do for x in 0..<dimension.x do grid[x + y * dimension.x].p = {x, y}
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Pattern Size", &N, 1, 10)
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                assert(image.image.format == .UNCOMPRESSED_R8G8B8A8)
                
                reset_collapse(&collapse)
                pixels := slice_from_parts(rl.Color, image.image.data, image.image.width * image.image.height)
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
            
            switch update_state {
              case .Step: 
                update_state = .Paused
                fallthrough
              case .Paused:
               if imgui.button("Unpause") do update_state = .Unpaused
               if imgui.button("Step")    do update_state = .Step
               
              case .Unpaused:
               if imgui.button("Pause") do update_state = .Paused
            
              case .Done:
            }
            
            imgui.checkbox("Average Color", auto_cast &render_wavefunction_as_average)
            modes := [Search_Mode] string {
                .Scanline = "top to bottom, left to right",
                .States = "fewest possible states",
                .Entropy = "lowest entropy",
            }
            for text, mode in modes {
                if imgui.radio_button(text, mode == search_mode) {
                    search_mode = mode
                }
            }
        }
        
        imgui.text("Stats")
        tile_count := len(collapse.states)
        imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
        imgui.text(tprint("Total time %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        
        imgui.text("Pick a color to Draw")
        imgui.columns(2)
        _id: i32
        for &group, index in draw_groups {
            selected := index == selected_group
            if imgui.radio_button(tprint("%", index), selected) {
                selected_group = selected ? -1 : index
            }
            imgui.next_column()
            
            flags: imgui.Color_Edit_Flags = .NoPicker | .NoOptions | .NoSmallPreview | .NoInputs | .NoTooltip | .NoSidePreview | .NoDragDrop
            imgui.color_button("", rgba_to_v4(cast([4]u8) group.color), flags = flags)
            imgui.next_column()
        }
        imgui.columns()
        
        sp := rl.GetMousePosition()
        wp := screen_to_world(sp)
        if dimension_contains(dimension, wp) {
            if selected_group != -1 {
                place  := rl.IsMouseButtonDown(.LEFT)
                remove := rl.IsMouseButtonDown(.RIGHT)
                // @todo(viktor): Instead of directly modifying we should make a separate structure to keep these restrictions around and apply them again
                if remove ~ place {
                    cell := &grid[wp.x + wp.y * dimension.x]
                    if wave, ok := cell.value.(WaveFunction); ok {
                        for it in wave.supports {
                            is_selected: b32
                            for id in draw_groups[selected_group].ids {
                                if it.id == id {
                                    is_selected = true
                                    break
                                }
                            }
                            
                            if remove && is_selected || place && !is_selected {
                                remove_state(&collapse, wp, it.id)
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
            t_restart -= rl.GetFrameTime()
            if t_restart <= 0 {
                t_restart = 0
                should_restart = false
                if first_time {
                    
                    _total_start = time.now()
                    first_time = false
                } else {
                    update_state = .Paused
                    restart(&collapse)
                }
            }
            
            if update_state != .Done {
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
        
        is_done := true
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
                                    value := cast([4]u8) state.values[0] // middle
                                    color += rgba_to_v4(value) * cast(f32) state.frequency
                                    count += cast(f32) state.frequency
                                }
                                
                                if count > 0 {
                                    color /= count
                                }
                                
                                average.color = cast(rl.Color) v4_to_rgba(color)
                            }
                            rl.DrawRectangleRec(rect, average.color)
                            rl.DrawRectangleLinesEx(rect, 2,  rl.BLACK)
                            rl.DrawRectangleLinesEx(rect, 1,  rl.WHITE)
                        } else {
                            rl.DrawRectangleRec(rect, {0,255,255,32})
                        }
                    }
                    
                  case Collapsed:
                    values := collapse.states[value].values
                    color := values[0] // middle
                    rl.DrawRectangleRec(rect, color)
                }
            }
        }
        
        if is_done do update_state = .Done
        
        for change in changes[changes_cursor:] {
            p := world_to_screen(change.p)
            rl.DrawRectangleRec({p.x, p.y, screen_size_factor, screen_size_factor}, rl.ColorAlpha(rl.YELLOW, 0.4))
        }
        
        if to_be_collapsed != nil {
            p := world_to_screen(to_be_collapsed.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, screen_size_factor, screen_size_factor}, rl.ColorAlpha(color, 0.8))
        }
        
        if selected_group != -1 {
            if dimension_contains(dimension, wp) {
                wsp := world_to_screen(wp)
                rect := rl.Rectangle {wsp.x, wsp.y, screen_size_factor, screen_size_factor}
                
                rl.DrawRectangleRec(rect, collapse.states[draw_groups[selected_group].ids[0]].values[0])
                rl.DrawRectangleLinesEx(rect, 2,  rl.BLACK)
                rl.DrawRectangleLinesEx(rect, 1,  rl.WHITE)
            }
        }
        
        rl.EndMode2D()
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

update :: proc (c: ^Collapse, entropy: ^RandomSeries) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    update_start := time.now()
    
    update: for {
        if c.states == nil do break update
        
        if len(changes) == 0 {
            if to_be_collapsed == nil {
                if update_state == .Paused do break update
                
                // Find next cell to be collapsed 
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Find next cell to be collapsed")
    
                begin_search(c, search_mode)
                
                found_invalid: b32
                search: for &cell, index in grid {
                    if wave, ok := &cell.value.(WaveFunction); ok {
                        switch test_search_cell(c, &cell, wave) {
                        case .Continue: // nothing
                        case .Done:     break search
                        
                        case .Found_Invalid: 
                            found_invalid = true
                            break search
                        }
                    }
                }
                
                cells := end_search(c)
                if found_invalid {
                    should_restart = true
                    break update
                } else {
                    if len(cells) > 0 {
                        to_be_collapsed = random_value(entropy, cells)
                    }
                }
            } else {
                // Collapse chosen cell
                spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Collapse chosen cell")
                
                wave := to_be_collapsed.value.(WaveFunction)
                pick := Invalid_Id
                if len(wave.supports) == 1 {
                    pick = wave.supports[0].id
                } else if true {
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
                } else {
                    // User choses
                    imgui.begin_child("Choose")
                    
                    column_count := ceil(i32, square_root(cast(f32) len(wave.supports)))
                    imgui.columns(column_count)
                    i: i32
                    for support in wave.supports {
                        id := support.id
                        state := c.states[id]
                        color := state.values[0] // middle
                        
                        if imgui.color_button(tprint("choose-%", id), rgba_to_v4(cast([4]u8) color)) {
                            pick = id
                        }
                        
                        if i % column_count == 0 {
                            imgui.next_column()
                        }
                        i += 1
                    }
                    imgui.end_child()
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
                }
            }
        } else {
            // Propagate changes
            spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "Propagate changes")
            
            if changes_cursor >= len(changes) {
                clear_changes()
            } else {
                change := changes[changes_cursor]
                changes_cursor += 1
                assert(len(change.removed_support) > 0)
                
                for delta, direction in Deltas {
                    to_p := change.p + delta
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
                                break update
                            }
                        }
                    }
                }
            }
        }
        
        if time.duration_seconds(time.since(update_start)) > TargetFrameTime * 0.9 {
            break update
        }
    }
}

clear_changes :: proc () {
    changes_cursor = 0
    for it in changes {
        for d in Direction {
            delete(it.removed_support[d])
        }
    }
    clear(&changes)
}

remove_state :: proc (c: ^Collapse, p: v2i, removed_state: State_Id) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    
    change: ^Change
    for &other in changes[changes_cursor:] {
        if other.p == p {
            change = &other
        }
    }
    
    if change == nil {
        append(&changes, Change { p = p })
        change = &changes[len(changes)-1]
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
    
    clear_changes()
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
}

extract_tiles :: proc (c: ^Collapse, pixels: []rl.Color, width, height: i32) {
    for &group in draw_groups {
        delete(group.ids)
    }
    clear(&draw_groups)
    selected_group = -1
    
    // @Incomplete: Allow for rotations and mirroring here
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
                loop: for y in 0..<dim.y {
                    for x in 0..<dim.x {
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
        }
        
        append(&group.ids, state.id)
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