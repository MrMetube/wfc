package main

import "core:os/os2"
import "core:strings"
import "core:time"


import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

// @important @todo(viktor): should north be +1 or -1 ! Check this!
Deltas := [Direction] v2i { .East = {1,0}, .West = {-1,0}, .North = {0,-1}, .South = {0,1}}

Screen_Size :: v2i{1920, 1080}

_total, _update, _render: time.Duration
_total_start: time.Time


TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////

first_time := true
should_restart: b32
t_restart: f32
paused_update: b32
wait_time: f32 = 0.1

dimension: v2i = {150, 100}
grid: [] Cell
average_colors: [] Average_Color
Average_Color :: struct {
    color: rl.Color,
    states_count_when_computed: u32,
}

Cell :: struct {
    p: v2i,
    
    value: union {
        Collapsed,
        WaveFunction,
    },
}

Collapsed :: struct {
    value: State_Id
}
WaveFunction :: struct {
    supports: [dynamic] Support,
}
Support :: struct {
    id:     State_Id,
    amount: [Direction] i32
}

Matches :: [/* a State_Id */] [Direction] [/* b State_Id */] b32
matches: Matches

Direction :: enum {
    East, North, West, South,
}

textures_length: int
textures_and_images: [dynamic] struct {
    image:   rl.Image,
    texture: rl.Texture,
}
states_direction: Direction
render_wavefunction_as_average: b32

main :: proc () {
    size: f32
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, dimension+10)
    if ratio.x < ratio.y {
        size = ratio.x
    } else {
        size = ratio.y 
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
    
    entropy := seed_random_series(123)
    collapse: Collapse
    
    grid = make(type_of(grid), dimension.x * dimension.y)
    average_colors = make(type_of(average_colors), dimension.x * dimension.y)
    for y in 0..<dimension.y do for x in 0..<dimension.x {
        grid[x + y * dimension.x].p = {x,y}
    }
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        ////////////////////////////////////////////////
        // UI
        
        imgui.text("Choose Input Image")
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                assert(image.image.format == .UNCOMPRESSED_R8G8B8A8)
                
                if collapse._states != nil {
                    resize(&collapse._states, 0)
                    collapse.Extraction = {} // @leak
                }
                
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
        
        if len(collapse._states) != 0 {
            if imgui.button(paused_update ? "Unpause" : "Pause") {
                paused_update = !paused_update
            }
            
            if imgui.button(should_restart ? tprint("Restarting in %", view_seconds(t_restart, precision = 3)) : "Restart") {
                if !should_restart {
                    should_restart = true
                    t_restart = 0.3
                } else {
                    t_restart = 0
                }
            }
            
            imgui.checkbox("Average Color", auto_cast &render_wavefunction_as_average)
        }
        
        imgui.text("Stats")
        is_late := cast(f32) time.duration_seconds(_update) > TargetFrameTime
        imgui.text_colored(is_late ? Orange : White, tprint(`Update %`, _update))
        imgui.text(tprint("Render %", _render))
        imgui.text(tprint("Total %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        
        ////////////////////////////////////////////////
        // Update 
        
        if !paused_update {
            if !should_restart {
                update(&collapse, &entropy)
            } else {
                t_restart -= rl.GetFrameTime()
                if t_restart <= 0 {
                    t_restart = 0
                    should_restart = false
                    if first_time {
                        first_time = false
                        
                        _total_start = time.now()
                    } else {
                        restart(&collapse)
                    }
                }
            }
            
            // if collapse.state != .Done {
                _total = time.since(_total_start)
            // }
        }
        
        ////////////////////////////////////////////////
        // Render
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        render_start := time.now()
        rl.BeginMode2D(camera)
        
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                index := x + y * dimension.x
                cell := grid[index]
                p := get_screen_p(dimension, size, {x, y})
                
                rect := rl.Rectangle {p.x, p.y, size, size}
                switch value in cell.value {
                  case WaveFunction: 
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
                                    state := collapse._states[support.id]
                                    value := cast([4]u8) state.values[1 + 1 * 3] // middle
                                    color += rgba_to_v4(value) * cast(f32) state.frequency
                                    count += cast(f32) state.frequency
                                }
                                
                                if count > 0 {
                                    color /= count
                                }
                                
                                average.color = cast(rl.Color) v4_to_rgba(color)
                            }
                            rl.DrawRectangleRec(rect, average.color)
                        } else {
                            rl.DrawRectangleRec(rect, {0,255,255,32})
                        }
                    }
                    
                  case Collapsed:
                    values := collapse._states[value.value].values
                    color := values[1 + 1 * 3] // middle
                    rl.DrawRectangleRec(rect, color)
                }
            }
        }
        
        for change in changes[changes_cursor:] {
            p := get_screen_p(dimension, size, change.p)
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.YELLOW, 0.4))
        }
        
        if to_be_collapsed != nil {
            p := get_screen_p(dimension, size, to_be_collapsed.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(color, 0.8))
        }
        
        rl.EndMode2D()
        _render = time.since(render_start)
        
        if collapse._states != nil {
            if textures_length != len(collapse._states) {
                for it in textures_and_images do rl.UnloadTexture(it.texture)
                
                textures_length = len(collapse._states)
                resize(&textures_and_images, textures_length)
                
                for &state, index in collapse._states {
                    image := rl.Image {
                        data = raw_data(state.values),
                        width  = 3,
                        height = 3,
                        mipmaps = 1,
                        format = .UNCOMPRESSED_R8G8B8A8,
                    }
                    
                    textures_and_images[index].image   = image
                    textures_and_images[index].texture = rl.LoadTextureFromImage(image)
                }
            }
            
            when false {
                imgui.begin("States")
                
                if imgui.button("East") do states_direction = .East
                if imgui.button("West") do states_direction = .West
                if imgui.button("North") do states_direction = .North
                if imgui.button("South") do states_direction = .South
                
                imgui.columns(auto_cast len(collapse._states)+1)
                for &a, a_index in collapse._states {
                    for &b, b_index in collapse._states {
                        if a_index == 0 {
                            imgui.push_id(cast(i32) textures_and_images[a_index].texture.id)
                            imgui.image_button(auto_cast &textures_and_images[a_index].texture.id, 15)
                            imgui.pop_id()
                            imgui.next_column()
                        } else if b_index == 0 {
                            // imgui.push_id(cast(i32) b_index)
                            imgui.image_button(auto_cast &textures_and_images[b_index].texture.id, 15)
                            // imgui.pop_id()
                            imgui.next_column()
                        }
                        
                        if matches[a_index][states_direction][b_index] {
                            a := a
                            b := b
                            imgui.text("o")
                        } else {
                            // imgui.text("x")
                        }
                        
                        imgui.next_column()
                    }
                }
                imgui.columns(1)
                imgui.end()
            }
        }
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

extract_tiles :: proc (c: ^Collapse, pixels: []rl.Color, width, height: i32) {
    N :: 3
    // @Incomplete: make N a parameter, Allow for rotations and mirroring here
    for by in 0..<height {
        for bx in 0..<width {
            begin_state(c)
            for dy in cast(i32) 0..<N {
                for dx in cast(i32) 0..<N {
                    x := (bx + dx) % width
                    y := (by + dy) % height
                    append_state_value(c, pixels[x + y * width])
                }
            }
            end_state(c)
        }
    }
    
    matches = make(Matches, len(c._states))
    offsets := [Direction] v2i {
        .East  = {-1,0},
        .North = {0, 1},
        .West  = { 1,0},
        .South = {0,-1},
    }
    
    for a in c._states {
        for offset, d in offsets {
            matches[a.id][d] = make([] b32, len(c._states))
            
            region := rectangle_min_dimension(cast(i32) 0,0,N,N)
            dim := get_dimension(region)
            for b in c._states {
                does_match: b32 = true
                // @speed we could hash these regions and only compare hashes in the n²-loop
                loop: for y in 0..<dim.y {
                    for x in 0..<dim.x {
                        ap := v2i{x,y}
                        bp := v2i{x,y} + offset
                        
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
                
                matches[a.id][d][b.id] = does_match
            }
        }
    }
    
    for as, a in matches {
        for ds, d in as {
            for ok, b in ds {
                assert(ok == matches[b][opposite(d)][a])
            }
        }
    }
}

to_be_collapsed: ^Cell
changes: [dynamic] Change
Change :: struct {
    p: v2i,
    removed_states: [dynamic] State_Id,
}
changes_cursor: int

update :: proc (collapse: ^Collapse, entropy: ^RandomSeries) {
    update_start := time.now()
    defer _update = time.since(update_start)
    
    update: for {
        if collapse._states == nil do break update
        
        if len(changes) == 0 {
            if to_be_collapsed == nil {
                cells_with_lowest_entropy := make([dynamic]^Cell, context.temp_allocator)
                lowest_entropy := max(u32)
                
                if !true {
                    // Linear
                    search: for &cell in grid do if wave, ok := cell.value.(WaveFunction); ok {
                        if len(wave.supports) == 0 {
                            restart(collapse)
                            break update
                        }
                        
                        entropy := cast(u32) len(wave.supports)
                        lowest_entropy = entropy
                        append(&cells_with_lowest_entropy, &cell)
                        break search
                    }
                } else {
                    // Entropy
                    for &cell in grid do if wave, ok := cell.value.(WaveFunction); ok {
                        when false {
                            count: u32
                            for support in wave.states do if support > 0 {
                                count += 1
                            }
                            assert(count == wave.states_count)
                        }
                        
                        if len(wave.supports) == 0 {
                            restart(collapse)
                            break update
                        }
                        
                        // @todo(viktor): Measure entropy
                        entropy := cast(u32) len(wave.supports)
                        if lowest_entropy > entropy {
                            lowest_entropy = entropy
                            clear(&cells_with_lowest_entropy)
                        }
                        
                        if lowest_entropy == entropy {
                            append(&cells_with_lowest_entropy, &cell)
                        }
                    }
                }
                
                
                if lowest_entropy != max(u32) {
                    if len(cells_with_lowest_entropy) > 0 {
                        to_be_collapsed = random_value(entropy, cells_with_lowest_entropy[:])
                    }
                }
            } else {
                wave := to_be_collapsed.value.(WaveFunction)
                pick := Invalid_Id
                if len(wave.supports) == 1 {
                    for support in wave.supports {
                        state := &collapse._states[support.id]
                        pick = support.id
                        break
                    }
                    assert(pick != Invalid_Id)
                } else if true {
                    // Random
                    total_frequency: i32
                    for support in wave.supports {
                        total_frequency += collapse._states[support.id].frequency
                    }
                    
                    target := random_between(entropy, i32, 0, total_frequency)
                    picking: for support in wave.supports {
                        state := &collapse._states[support.id]
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
                        state := collapse._states[id]
                        color := state.values[1+1*3]
                        
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
                    change: Change
                    change.p = to_be_collapsed.p
                    for support in wave.supports {
                        id := support.id
                        if pick != id {
                            append(&change.removed_states, id)
                        }
                    }
                    
                    delete(wave.supports)
                    to_be_collapsed.value = Collapsed { pick }
                    
                    append(&changes, change)
                    to_be_collapsed = nil
                }
            }
        } else {
            if changes_cursor >= len(changes) {
                changes_cursor = 0
                for it in changes {
                    delete(it.removed_states)
                }
                clear(&changes)
            } else {
                change := changes[changes_cursor]
                p := change.p
                from_cell := &grid[p.x + p.y * dimension.x]
                changes_cursor += 1
                
                for delta, direction in Deltas {
                    np := p + delta
                    if !dimension_contains(dimension, np) do continue 
                    
                    to_cell := &grid[np.x + np.y * dimension.x]
                    if to_wave, ok := &to_cell.value.(WaveFunction); ok {
                        next_change := Change { p = to_cell.p }
                        
                        if !true {
                            #reverse for &sup, sup_index in to_wave.supports {
                                to_id := sup.id
                                if true {
                                    support_now: i32
                                    switch from in from_cell.value {
                                      case Collapsed:
                                        if matches[from.value][direction][to_id] {
                                            support_now += 1
                                        }
                                      case WaveFunction:
                                        for from_support in from.supports {
                                            if matches[from_support.id][direction][to_id] {
                                                support_now += 1
                                            }
                                        }
                                    }
                                    
                                    sup.amount[direction] = support_now
                                } else {
                                    support_before := sup.amount[direction]
                                    removed_support: i32
                                    for from_id in change.removed_states {
                                        if matches[from_id][direction][to_id] {
                                            removed_support += 1
                                        }
                                    }
                                    
                                    sup.amount[direction] -= removed_support
                                }
                                
                                if sup.amount[direction] <= 0 {
                                    append(&next_change.removed_states, to_id)
                                    sup.amount = {}
                                    unordered_remove(&to_wave.supports, sup_index)
                                    if len(to_wave.supports) == 0 {
                                        break update
                                    }
                                }
                            }
                        } else {
                            #reverse for &to_support, sup_index in to_wave.supports {
                                any_matches := false
                                support_count: i32
                                switch from in from_cell.value {
                                  case Collapsed:
                                    if matches[from.value][direction][to_support.id] {
                                        any_matches = true
                                        support_count += 1
                                    }
                                  case WaveFunction:
                                    for from_support in from.supports {
                                        if matches[from_support.id][direction][to_support.id] {
                                            any_matches = true
                                            support_count += 1
                                        }
                                    }
                                }
                                
                                to_support.amount[direction] = support_count
                                if !any_matches {
                                    assert(support_count == 0)
                                    append(&next_change.removed_states, to_support.id)
                                    to_support.amount = {}
                                    unordered_remove(&to_wave.supports, sup_index)
                                    if len(to_wave.supports) == 0 {
                                        break update
                                    }
                                }
                            }
                            
                            when false {
                                for support in to_wave.supports {
                                    maximum_support: i32
                                    minimum_support: i32 = max(i32)
                                    if support.amount > 0 {
                                        for b_direction in Direction {
                                            maximum_support_per_direction: i32
                                            
                                            dp := to_cell.p + Deltas[b_direction]
                                            if !dimension_contains(dimension, dp) do continue
                                            
                                            other := grid[dp.x + dp.y * dimension.x]
                                            switch other_value in other.value {
                                            case Collapsed:
                                                maximum_support_per_direction += matches[id][b_direction][other_value.value] ? 1 : 0
                                            case WaveFunction:
                                                for it, other_id in other_value.supports do if it.amount > 0 {
                                                    maximum_support_per_direction += matches[id][b_direction][other_id] ? 1 : 0
                                                }
                                            }
                                            
                                            minimum_support = min(minimum_support, maximum_support_per_direction)
                                            maximum_support += maximum_support_per_direction
                                        }
                                    }
                                    if minimum_support == max(i32) do minimum_support = 0
                                    assert(support.amount <= maximum_support)
                                }
                            }
                        }
                        
                        if len(next_change.removed_states) != 0 {
                            append(&changes, next_change)
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

get_maximum_support :: proc (c: ^Collapse, a: State_Id, direction: Direction) -> (result: i32) {
    a_matches_in_direction := matches[a][direction]
    for b in c._states {
        if a_matches_in_direction[b.id] do result += 1
    }
    return result
}

restart :: proc (c: ^Collapse) {
    println("Restarting")
    for it in changes do delete(it.removed_states)
    clear(&changes)
    changes_cursor = 0
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
            
            wave.supports = make([dynamic] Support, len(c._states))
            for &it, index in wave.supports do it.id = cast(State_Id) index
        }
    }
    
    for y in 0..<dimension.y {
        for x in 0..<dimension.x {
            cell := &grid[x + y * dimension.x]
            wave := &cell.value.(WaveFunction)
            
            for &it in wave.supports {
                for delta, direction in Deltas {
                    dp := cell.p + delta
                    if !dimension_contains(dimension, dp) do continue
                    it.amount[direction] += get_maximum_support(c, it.id, direction)
                }
            }
            cell = cell
        }
    }
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


get_screen_p :: proc (dimension: v2i, size: f32, p: v2i) -> (result: v2) {
    result = vec_cast(f32, p) * size
    
    result += (vec_cast(f32, Screen_Size) - (size * vec_cast(f32, dimension))) * 0.5
    
    return result
}