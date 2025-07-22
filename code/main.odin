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

_total, _update, _render, _pick_next, _add_neighbours, _matches, _collect: time.Duration
_total_start: time.Time
main :: proc () {
    Dim :: [2]int {200, 100}
    size: f32
    
    ratio := vec_cast(f32, Screen_Size) / vec_cast(f32, Dim+10)
    if ratio.x < ratio.y {
        size = ratio.x
    } else {
        size = ratio.y 
    }

    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(Screen_Size.x, Screen_Size.y, "Wave Function Collapse")
    rl.SetTargetFPS(60)
    
    camera := rl.Camera2D { zoom = 1 }
    
    the_font = rl.LoadFontEx(`.\Caladea-Regular.ttf`, rl_font_scale, raw_data(code_points[:]), len(code_points))
    
    arena: Arena
    init_arena(&arena, make([]u8, 1*Gigabyte))
    
    collapse: Collapse
    init_collapse(&collapse, &arena, 256, Dim, false, false, 50)
    
    
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
    should_restart: b32
    t_restart: f32
    paused_update: b32
    
    context_ := imgui.igCreateContext(nil)
    imgui.igSetCurrentContext(context_)
    
    rlimgui.ImGui_ImplRaylib_Init()

    for !rl.WindowShouldClose() {
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        imgui.text("Choose Input Image")
        i: i32
        imgui.columns(6)
        for _, &image in images {
            defer i += 1
            
            imgui.push_id(i)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                // @leak
                collapse.tiles = make_array(&arena, Tile, 1<<16)
                extract_tiles(&collapse, image.image)
                
                should_restart = true
                t_restart = 0.3
            }
            imgui.pop_id()
            imgui.next_column()
        }
        imgui.columns(1)
        imgui.checkbox("Loop on X Axis", cast(^bool) &collapse.wrap_x)
        imgui.checkbox("Loop on Y Axis", cast(^bool) &collapse.wrap_y)
        imgui.slider_int("Recursion Depth", cast(^i32) &collapse.max_depth, 1, 1000, flags = .Logarithmic)
        
        if collapse.tiles.count != 0 {
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
            _pick_next = 0
            _collect = 0
            _add_neighbours = 0
            _matches = 0
            
            /* @todo(viktor): How can we separate the core of the algorithm from the data is works on.
                The should be able to feed in the data however they want 
                The current higher level functionality should be seen as wrapper around the core api
                This would allow for non grid based data, as well as user space handling of wrapping and the like.
                
                For the input data we already abstract over the sockets as pixels with socket indices.
                
                The main idea is that the user drives the algorith and the wfc only provides services instead of being a blackbox
                That way it should be possible to for example prevent having huge frame spikes when the recursion is too deep and we cant pause it 
                and continue the work on the next frame.
                
                This should also allow for easier special cases like stiched wfc, where we only give a region at a time(with some overlap)
            */
            
            if !should_restart {
                update_start := time.now()
                for time.duration_seconds(time.since(update_start)) < 0.016 {
                    switch collapse.state {
                      case .Uninitialized:
                        collapse.state = .PickNextCell
                        
                      case .PickNextCell:
                        clear(&to_check)
                        to_check_index = 0
                        
                        cell, pick := pick_next_cell(&collapse, &entropy)
                        if cell != nil {
                            collapse_cell_and_add_neighbours(&collapse, cell, pick)
                        }
                        collapse.state = .UpdateCell
                        
                      case .UpdateCell:
                        if to_check_index < to_check.count {
                            next := to_check.data[to_check_index]
                            to_check_index += 1
                            check_all_neighbours_once(&collapse, next)
                        } else {
                            collapse.state = find_lowest_entropy(&collapse)
                        }
                      case .Contradiction:
                        if !should_restart {
                            should_restart = true
                            t_restart = 3
                        }
                      case .Done:
                        _total = time.since(_total_start)
                    }
                }
                _update = time.since(update_start)
            } else {
                if collapse.tiles.count == 0 {
                    should_restart = false
                    t_restart = 0
                } else {
                    t_restart -= rl.GetFrameTime()
                    if t_restart <= 0 {
                        t_restart = 0
                        _total_start = time.now()
                        should_restart = false
                        entangle_grid(&collapse)
                        collapse.state = .Uninitialized
                    }
                }
            }
        }
        
        // @todo(viktor): let user collapse manually
        
        // 
        // Render
        // 
        render_start := time.now()
        rl.BeginDrawing()
        rl.ClearBackground({0x54, 0x57, 0x66, 0xFF})
        rl.BeginMode2D(camera)
        
        for y in 0..<Dim.y {
            for x in 0..<Dim.x {
                cell := &grid[y*Dim.x + x]
                
                p := get_screen_p(collapse.dimension, size, {x, y})
                
                switch value in cell.value {
                  case Tile:
                    for cy in 0..<center {
                        for cx in 0..<center {
                            fcenter := cast(f32) center
                            rect := rl.Rectangle {p.x+ cast(f32)cx*size/fcenter, p.y + cast(f32) cy*size/fcenter, size/fcenter, size/fcenter}
                            rl.DrawRectangleRec(rect, value.center[cy*center+cx])
                        }
                    }
                    
                  case WaveFunction:
                    invalid:= true
                    loop: for state in value.states do if state {
                        invalid = false
                        break loop
                    }
                    if invalid {
                        rl.DrawRectangleRec({p.x, p.y, size, size}, rl.RED)
                    } else {
                        draw_wave(&collapse, value, p, size)
                    }
                }
            }
        }
        
        for entry in slice(to_check) {
            p := get_screen_p(collapse.dimension, size, entry.index)
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(rl.YELLOW, 0.8))
        }
        
        for cell in slice(lowest_entropies) {
            p := get_screen_p(collapse.dimension, size, cell.p)
            color := rl.PURPLE
            rl.DrawRectangleRec({p.x, p.y, size, size}, rl.ColorAlpha(color, 0.8))
        }
        
        rl.EndMode2D()
        _render = time.since(render_start)
        
        
        imgui.begin("Stats")
            if paused_update {
                imgui.text_colored(Blue, "### Paused ###")
            }
            is_late := cast(f32) time.duration_seconds(_update) > rl.GetFrameTime()
            imgui.text_colored(is_late ? Orange : White, format_string(buffer[:], `Update %`, _update))
            if !should_restart {
                imgui.text(format_string(buffer[:], "  pick next %",        _pick_next))
                imgui.text(format_string(buffer[:], "  get neighbours %",  _add_neighbours))
                imgui.text(format_string(buffer[:], "  matches %",         _matches))
                imgui.text(format_string(buffer[:], "  collect %",         _collect))
            }
            imgui.text(format_string(buffer[:], "Render %", _render))
            imgui.text(format_string(buffer[:], "Total %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        imgui.end()
        
        if collapse.tiles.count != 0 {
            imgui.begin("Tiles")
                imgui.columns(ceil(i32, square_root(cast(f32)collapse.tiles.count)))
                for &tile in slice(collapse.tiles) {
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

draw_wave :: proc (using collapse: ^Collapse, wave: WaveFunction, p: v2, size: v2) {
    count: f32
    sum:   v4
    for state, index in wave.states {
        if !state do continue
        tile := tiles.data[index]
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

get_screen_p :: proc (dimension: [2]int, size: f32, p: [2]int) -> (result: v2) {
    result = vec_cast(f32, p) * size
    
    result += (vec_cast(f32, Screen_Size) - (size * vec_cast(f32, dimension))) * 0.5
    
    return result
}