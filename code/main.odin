package main

import "core:os/os2"
import "core:strings"
import "core:time"


import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Deltas := [Direction] v2i { .East = {1,0}, .West = {-1,0}, .North = {0,-1}, .South = {0,1}}

Screen_Size :: v2i{1920, 1080}

_total, _update, _render: time.Duration
_total_start: time.Time


TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////

N: i32 = 3

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
render_wavefunction_as_average: b32 = true

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

supports: [/* from State_Id */][Direction][/* to State_Id */] i32

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
    removed_states: [dynamic] State_Id,
}

is_done: b32

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
        imgui.slider_int("Tile Pattern Size", &N, 1, 10)
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                assert(image.image.format == .UNCOMPRESSED_R8G8B8A8)
                
                if collapse.states != nil {
                    resize(&collapse.states, 0)
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
        
        if len(collapse.states) != 0 {
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
        tile_count := len(collapse.states)
        imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
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
            
            if !is_done {
                _total = time.since(_total_start)
            }
        }
        
        ////////////////////////////////////////////////
        // Render
        
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        render_start := time.now()
        rl.BeginMode2D(camera)
        
        is_done = true
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                index := x + y * dimension.x
                cell := grid[index]
                p := get_screen_p(dimension, size, {x, y})
                
                rect := rl.Rectangle {p.x, p.y, size, size}
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
                        } else {
                            rl.DrawRectangleRec(rect, {0,255,255,32})
                        }
                    }
                    
                  case Collapsed:
                    values := collapse.states[value.value].values
                    color := values[0] // middle
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
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

extract_tiles :: proc (c: ^Collapse, pixels: []rl.Color, width, height: i32) {
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
    
    matches := make([] [Direction] [] b8, len(c.states), context.temp_allocator)
    offsets := [Direction] v2i {
        .East  = {-1,0},
        .North = {0, 1},
        .West  = { 1,0},
        .South = {0,-1},
    }
    
    for a, a_index in c.states {
        for offset, d in offsets {
            matches[a.id][d] = make([] b8, len(c.states), context.temp_allocator)
            
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
                
                matches[a.id][d][b.id] = does_match
            }
        }
        
        print("Extraction: Matches generation % %%\r", view_percentage(a_index, len(c.states)))
    }
    println("Extraction: Matches generation done        ")
    
    // @todo(viktor): Matches is symmetric so we only need to store about half as many values as we currently do
    when false {
        for as, a in matches {
            for ds, d in as {
                for ok, b in ds {
                    assert(ok == matches[b][opposite(d)][a])
                }
            }
            print("Extraction: Matches sanity check % %% \r", view_percentage(a, len(matches)))
        }
        println("Extraction: Matches sanity check done         ")
    }
    
    delete(supports)
    supports = make([][Direction][]i32, len(c.states))
    
    for from in c.states {
        for direction in Direction {
            if supports[from.id][direction] == nil {
                supports[from.id][direction] = make([]i32, len(c.states))
            }
            
            for to in c.states {
                if matches[from.id][direction][to.id] {
                    supports[from.id][direction][to.id] += 1
                }
            }
        }
    }
}

update :: proc (c: ^Collapse, entropy: ^RandomSeries) {
    update_start := time.now()
    defer _update = time.since(update_start)
    
    update: for {
        if c.states == nil do break update
        
        if len(changes) == 0 {
            if to_be_collapsed == nil {
                // Find next cell to be collapsed 
                
                cells_with_lowest_entropy := make([dynamic]^Cell, context.temp_allocator)
                lowest_entropy := max(u32)
                
                if false {
                    // Linear
                    search: for &cell in grid do if wave, ok := cell.value.(WaveFunction); ok {
                        if len(wave.supports) == 0 {
                            restart(c)
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
                        if len(wave.supports) == 0 {
                            restart(c)
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
                // Collapse chosen cell
                
                wave := to_be_collapsed.value.(WaveFunction)
                pick := Invalid_Id
                if len(wave.supports) == 1 {
                    for support in wave.supports {
                        state := &c.states[support.id]
                        pick = support.id
                        break
                    }
                    assert(pick != Invalid_Id)
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
                    
                    if len(change.removed_states) > 0 {
                        append(&changes, change)
                    }
                    to_be_collapsed = nil
                }
            }
        } else {
            // Propagate changes
            
            if changes_cursor >= len(changes) {
                changes_cursor = 0
                for it in changes {
                    delete(it.removed_states)
                }
                clear(&changes)
            } else {
                change := changes[changes_cursor]
                assert(len(change.removed_states) > 0)
                
                from_cell := &grid[change.p.x + change.p.y * dimension.x]
                changes_cursor += 1
                
                for delta, direction in Deltas {
                    to_p := change.p + delta
                    // @wrapping
                    if !dimension_contains(dimension, to_p) do continue 
                    
                    to_cell := &grid[to_p.x + to_p.y * dimension.x]
                    to_wave, ok := &to_cell.value.(WaveFunction)
                    if !ok do continue 
                    
                    next_change := Change { p = to_cell.p }
                    #reverse for &to_support, sup_index in to_wave.supports {
                        amount := &to_support.amount[direction]
                        support_before := amount^
                        
                        remove: b32
                        if support_before == 0 {
                            remove = true
                        } else {
                            removed_support: i32
                            for from_id in change.removed_states {
                                removed_support += supports[from_id][direction][to_support.id]
                            }
                            
                            amount^ -= removed_support
                            amount^ = max(0, amount^)
                        }
                        assert(amount^ >= 0)
                        
                        if amount^ == 0 {
                            remove = true
                        }
                        
                        if remove {
                            append(&next_change.removed_states, to_support.id)
                            to_support.amount = {}
                            unordered_remove(&to_wave.supports, sup_index)
                            if len(to_wave.supports) == 0 {
                                break update
                            }
                        }
                    }
                    
                    if len(next_change.removed_states) > 0 {
                        found: b32
                        entry: ^Change
                        for &other in changes[changes_cursor:] {
                            if other.p == next_change.p {
                                found = true
                                entry = &other
                            }
                        }
                        
                        if !found {
                            assert(len(next_change.removed_states) > 0)
                            append(&changes, Change { p = next_change.p })
                            entry = &changes[len(changes)-1]
                        }
                        assert(entry != nil)
                        
                        for it in next_change.removed_states {
                            append(&entry.removed_states, it)
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

restart :: proc (c: ^Collapse) {
    for it in changes { delete(it.removed_states) }
    clear(&changes)
    changes_cursor = 0
    to_be_collapsed = nil
    
    amounts_cache := make([][Direction] i32, len(c.states), context.temp_allocator)
    for from, index in c.states {
        for &amounts, id in amounts_cache {
            for &amount, direction in amounts {
                amount += supports[from.id][direction][id]
            }
        }
        print("Restart: calculate maximum support % %% \r", view_percentage(index, len(c.states)))
    }
    println("Restart: calculate maximum support done          ")
    
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
                    support_now := amounts_cache[it.id][direction]
                    amount = support_now
                }
            }
        }
        print("Restart: initialize support % %% \r", view_percentage(y, dimension.y))
    }
    println("Restart: initialize support done           ")
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