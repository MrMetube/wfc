package main

import "core:os/os2"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Screen_Size :: [2]i32{1920, 1080}

the_font: rl.Font
rl_font_scale :: 32
code_points := [?]rune {
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ',',';','.',':','-','_','#','\'','+','*','~','´','`','?','\\','=','}',')',']','(','[','/','{','&','%','$','§','"','!','^','°',' ',
    'µ','@','€','²','³','<','>','|',
    '1','2','3','4','5','6','7','8','9','0',
}

buffer: [256]u8

_total, _update, _render, _matches: time.Duration
_total_start: time.Time


TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////

first_time := true
max_lives := 5
lives := max_lives
should_restart: b32
t_restart: f32
paused_update: b32
region_index:= 0
region: Rectangle2i
full_region: Rectangle2i
regions: [dynamic]Rectangle2i
wrap: [2]b32

main :: proc () {
    Dim :: [2]i32 {200, 100}
    size: f32
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, Dim+10)
    if ratio.x < ratio.y {
        size = ratio.x
    } else {
        size = ratio.y 
    }

    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(TargetFps)
    
    camera := rl.Camera2D { zoom = 1 }
    
    the_font = rl.LoadFontEx(`.\Caladea-Regular.ttf`, rl_font_scale, raw_data(code_points[:]), len(code_points))
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Megabyte))
    
    collapse: Collapse
    wrap = { false, false }
    init_collapse(&collapse, Dim, 50)
    
    
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
    
    entropy := seed_random_series()
    
    using collapse
    
    full_region = rectangle_min_dimension([2]i32{}, dimension)
    divisor: i32 : 3
    for y in 0..<divisor {
        for x in 0..<divisor {
            r := rectangle_min_max((dimension*{x,y})/divisor, (dimension*{x+1,y+1})/divisor)
            r = add_radius(r, 1)
            append_elem(&regions, r)
        }
    }
    
    region_index = 0
    region = regions[region_index]
    
    imgui.igSetCurrentContext(imgui.igCreateContext(nil))
    
    rlimgui.ImGui_ImplRaylib_Init()
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        imgui.text("Choose Input Image")
        imgui.columns(6)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                clear(&collapse.tiles)
                extract_tiles(&collapse, image.image)
                collapse.state = .Contradiction
                first_time = true
                should_restart = true
                t_restart = 0
            }
            imgui.pop_id()
            imgui.next_column()
        }
        imgui.columns(1)
        imgui.checkbox("Loop on X Axis", cast(^bool) &wrap.x)
        imgui.checkbox("Loop on Y Axis", cast(^bool) &wrap.y)
        imgui.slider_int("Recursion Depth", cast(^i32) &collapse.max_depth, 1, 1000, flags = .Logarithmic)
        
        if len(collapse.tiles) != 0 {
            imgui.columns(2)
            if imgui.button(paused_update ? "Unpause" : "Pause") {
                paused_update = !paused_update
            }
            if !should_restart {
                if imgui.button("Restart") {
                    should_restart = true
                    t_restart = 0.3
                }
            } else {
                if imgui.button("Restart now") {
                    t_restart = 0
                }
                imgui.next_column()
                imgui.text(format_string(buffer[:], "Restarting in %", view_seconds(t_restart, precision = 3)))
            }
            imgui.columns(1)
        }
        
        if !paused_update {
            /* @todo(viktor): How can we separate the core of the algorithm from the data is works on.
                The should be able to feed in the data however they want 
                The current higher level functionality should be seen as wrapper around the core api
                This would allow for non grid based data, as well as user space handling of wrapping and the like.
                
                For the input data we already abstract over the sockets as pixels with socket indices.
            */
        
            // @todo(viktor): let user collapse manually
                    
            if !should_restart {
                _matches = 0
                
                update(&collapse, &entropy)
                
                if collapse.state != .Done {
                    _total = time.since(_total_start)
                }
                
            } else {
                if len(collapse.tiles) == 0 {
                    should_restart = false
                    t_restart = 0
                } else {
                    t_restart -= rl.GetFrameTime()
                    if t_restart <= 0 {
                        t_restart = 0
                        should_restart = false
                        if first_time {
                            first_time = false
                            
                            _total_start = time.now()
                            
                            region_index = 0
                            region = regions[region_index]
                            entangle_grid(&collapse, full_region, full_region)
                        } else {
                            lives -= 1
                            entangle_grid(&collapse, region, full_region)
                            if lives == 0 {
                                if region_index != 0 {
                                    region_index -= 1
                                    lives = max_lives
                                    region = regions[region_index]
                                    entangle_grid(&collapse, region, full_region)
                                    for y in region.min.y..<region.max.y {
                                        append_elem(&to_check, Check {{region.min.x, y}, 1})
                                        append_elem(&to_check, Check {{region.max.x-1, y}, 1})
                                    }
                                    for x in region.min.x..<region.max.x {
                                        append_elem(&to_check, Check {{x, region.min.y}, 1})
                                        append_elem(&to_check, Check {{x, region.max.y-1}, 1})
                                    }
                                } else {
                                    entangle_grid(&collapse, full_region, full_region)
                                }
                            } else {
                                for y in region.min.y..<region.max.y {
                                    append_elem(&to_check, Check {{region.min.x, y}, 1})
                                    append_elem(&to_check, Check {{region.max.x-1, y}, 1})
                                }
                                for x in region.min.x..<region.max.x {
                                    append_elem(&to_check, Check {{x, region.min.y}, 1})
                                    append_elem(&to_check, Check {{x, region.max.y-1}, 1})
                                }
                            }
                        }
                    }
                }
            }
        }

        // 
        // Render
        // 
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        
        render_start := time.now()
        rl.BeginMode2D(camera)
        
        for y in 0..<dimension.y {
            for x in 0..<dimension.x {
                cell := &grid[x + y * dimension.x]
                p := get_screen_p(collapse.dimension, size, {x, y})
                
                switch value in cell.value {
                  case TileIndex:
                    for cy in 0..<center {
                        for cx in 0..<center {
                            fcenter := cast(f32) center
                            rect := rl.Rectangle {p.x+ cast(f32)cx*size/fcenter, p.y + cast(f32) cy*size/fcenter, size/fcenter, size/fcenter}
                            tile := &tiles[value]
                            rl.DrawRectangleRec(rect, tile.center[cy*center+cx])
                        }
                    }
                    
                  case WaveFunction:
                    draw_wave(&collapse, value, p, size)
                }
            }
        }
        
        for check in to_check {
            // @todo(viktor): correct raw p
            cell_p := check.raw_p
            for w, dim in wrap do if w {
                cell_p[dim] = (cell_p[dim] + dimension[dim]) % dimension[dim]
            }
            if contains(region, cell_p) {
                p := get_screen_p(collapse.dimension, size, cell_p)
                rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.YELLOW, 0.4))
            }
        }
        
        for cell in lowest_entropies {
            p := get_screen_p(collapse.dimension, size, cell.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(color, 0.8))
        }
        
        min := get_screen_p(collapse.dimension, size, region.min)
        max := get_screen_p(collapse.dimension, size, region.max)
        rl.DrawRectangleLinesEx({min.x, min.y, max.x-min.x, max.y-min.y}, 1, rl.ORANGE)
        
        rl.EndMode2D()
        _render = time.since(render_start)
        
        imgui.begin("Stats")
            if paused_update {
                imgui.text_colored(Blue, "### Paused ###")
            }
            is_late := cast(f32) time.duration_seconds(_update) > TargetFrameTime
            imgui.text_colored(is_late ? Orange : White, format_string(buffer[:], `Update %`, _update))
            if !should_restart {
                imgui.text(format_string(buffer[:], "  matches %",   _matches))
            }
            imgui.text(format_string(buffer[:], "Render %", _render))
            imgui.text(format_string(buffer[:], "Total %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        imgui.end()
        
        if len(collapse.tiles) != 0 {
            imgui.begin("Tiles")
                imgui.columns(ceil(i32, square_root(cast(f32) len(collapse.tiles))))
                for &tile in collapse.tiles {
                    imgui.image_button(auto_cast &tile.texture.id, 25)
                    imgui.next_column()
                }
                imgui.columns(1)
            imgui.end()
        }
        
        imgui.render()
        rlimgui.ImGui_ImplRaylib_Render(imgui.igGetDrawData())
        rl.EndDrawing()
    }
}

update :: proc (collapse: ^Collapse, entropy: ^RandomSeries) {
    update_start := time.now()
    defer _update = time.since(update_start)
                
    update_done := false
    for !update_done {
        switch collapse.state {
          case .Uninitialized:
            
          case .FindLowestEntropy:
            collapse.state = find_lowest_entropy(collapse, region, full_region)
            
          case .CollapseCell:
            cell := collapse_one_of_the_cells_with_lowest_entropy(collapse, entropy)
            assert(cell != nil)
            
            add_neighbours(collapse, cell, collapse.max_depth)
            collapse.state = .Propagation
            
          case .Propagation:
            if check, ok := get_next_check(collapse); ok {
                p := check.raw_p
                wrapped := rectangle_modulus(full_region, p)
                for w, dim in wrap do if w {
                    p[dim] = wrapped[dim]
                }
                
                if contains(region, p) {
                    p = wrapped
                    next_cell := &collapse.grid[p.x + p.y * collapse.dimension.x]
                    assert(next_cell.p == p)
                    if !next_cell.checked {
                        next_cell.checked = true
                        
                        if wave, ok := &next_cell.value.(WaveFunction); ok {
                            // @speed O(n*m*d)
                            // n = a.wave.state_count
                            // m = b.wave.state_count
                            // d = len(Direction)
                            
                            loop: for &state, index in wave.states do if state {
                                for direction in Direction {
                                    bp := p + Delta[direction]
                                    bwrapped := rectangle_modulus(full_region, bp)
                                    for w, dim in wrap do if w {
                                        bp[dim] = bwrapped[dim]
                                    }
                                    
                                    if contains(full_region, bp) {
                                        b := &collapse.grid[bp.x + bp.y * collapse.dimension.x]
                                        if !matches(collapse, index, b, direction) {
                                            wave_remove_state(collapse, next_cell, wave, index) 
                                            continue loop
                                        }
                                    }
                                }
                            }
                            
                            if next_cell.changed {
                                wave_recompute_entropy(collapse, wave)
                                if check.depth > 0 {
                                    add_neighbours(collapse, next_cell, check.depth)
                                }
                            }
                        }
                    }
                }
            } else {
                collapse.state = .FindLowestEntropy
            }
            
          case .Contradiction:
            if !should_restart {
                should_restart = true
                t_restart = .1
            }
            
          case .Done:
            region_index += 1
            lives = max_lives
            if region_index < len(regions) {
                region = regions[region_index]
                entangle_grid(collapse, region, full_region)
                
                for y in region.min.y..<region.max.y {
                    append_elem(&collapse.to_check, Check {{0, y}, 1})
                    append_elem(&collapse.to_check, Check {{region.max.x-1, y}, 1})
                }
                for x in region.min.x..<region.max.x {
                    append_elem(&collapse.to_check, Check {{x, 0}, 1})
                    append_elem(&collapse.to_check, Check {{x, region.max.y-1}, 1})
                }
            } else {
                update_done = true
            }
        }
        
        if time.duration_seconds(time.since(update_start)) > TargetFrameTime * 0.9 {
            update_done = true
        }
    }
}

add_neighbours :: proc (using collapse: ^Collapse, cell: ^Cell, depth: u32) {
    for delta in Delta {
        add_neighbour(collapse, cell.p + delta, depth)
    }
}

draw_wave :: proc (using collapse: ^Collapse, wave: WaveFunction, p: v2, size: v2) {
    when true {
        total := cast(f32) len(tiles)
        count := cast(f32) wave.states_count
        ratio := (1-safe_ratio_0(count, total))
        color := cast(rl.Color) vec_cast(u8, v4{ratio, ratio, ratio, 1-ratio} * 255)
        rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, color)
    } else {
        count: f32
        sum:   v4
        for state, index in wave.states {
            if !state do continue
            tile := tiles[index]
            if tile.center != nil {
                count += cast(f32) tile.frequency
                assert(len(tile.center) == 1)
                sum += cast(f32) tile.frequency * vec_cast(f32, cast([4]u8) tile.center[0])
            }
        }
        
        average := safe_ratio_0(sum, count)
        color := cast(rl.Color) vec_cast(u8, average)
        rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, color)
    }
}

get_screen_p :: proc (dimension: [2]i32, size: f32, p: [2]i32) -> (result: v2) {
    result = vec_cast(f32, p) * size
    
    result += (vec_cast(f32, Screen_Size) - (size * vec_cast(f32, dimension))) * 0.5
    
    return result
}