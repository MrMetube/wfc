package main

import "core:hash"
import "core:os/os2"
import "core:strings"
import "core:time"

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"
import rlimgui "../lib/odin-imgui/examples/raylib"

Screen_Size :: v2i{1920, 1080}

_total, _update, _render, _matches: time.Duration
_total_start: time.Time


TargetFps       :: 144
TargetFrameTime :: 1./TargetFps

////////////////////////////////////////////////

first_time := true
max_lives: i32 = 5
tries: i32
should_restart: b32
t_restart: f32
paused_update: b32
region_index:= 0
region: Rectangle2i
regions: [dynamic]Rectangle2i
wrap: [2]b32 = {false, false}
max_depth: i32 = 20
wait_time: f32 = 0.1

main :: proc () {
    Dim :: v2i {150, 100}
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
    
    temp_arena: Arena
    init_arena(&temp_arena, make([]u8, 128*Megabyte))
    // context.temp_allocator = to_allocator(&temp_arena)
    arena: Arena
    init_arena(&arena, make([]u8, 128*Megabyte))
    
    collapse: Collapse
    _entropy := seed_random_series()
    init_collapse(&collapse, Dim, &_entropy)
    
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
    
    using collapse
    
    full_region = rectangle_min_dimension(v2i{}, dimension)
    divisor: i32 : 1
    for y in 0..<divisor {
        for x in 0..<divisor {
            r := rectangle_min_max((dimension*{x,y})/divisor, (dimension*{x+1,y+1})/divisor)
            // r = add_radius(r, 1)
            // r = get_intersection(r, full_region)
            append_elem(&regions, r)
        }
    }
    
    region_index = 0
    region = regions[region_index]
    
    imgui.set_current_context(imgui.create_context(nil))
    rlimgui.ImGui_ImplRaylib_Init()
    
    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        
        rlimgui.ImGui_ImplRaylib_NewFrame()
        rlimgui.ImGui_ImplRaylib_ProcessEvent()
        imgui.new_frame()
        
        imgui.text("Choose Input Image")
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                // @todo(viktor): make this more explicite so i dont forget any one of these steps
                clear(&collapse.tiles)
                extract_tiles(&collapse, image.image)
                collapse.state = .Contradiction
                collapse.max_frequency = 0
                clear(&collapse.lowest_entropies)
                clear(&collapse.to_check)
                collapse.to_check_index = 0
                
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
        imgui.slider_int("Depth", &max_depth, 1, 200, flags = .Logarithmic)
        imgui.slider_float("Delay", &wait_time, 0, 5, flags = .Logarithmic)
        if imgui.input_int("Retries", &max_lives, 1, 10) {
            max_lives = clamp(max_lives, 1, 100)
        }
        
        if len(collapse.tiles) != 0 {
            if imgui.button(paused_update ? "Unpause" : "Pause") {
                paused_update = !paused_update
            }
            
            imgui.text(tprint("Retries %/% for this region", tries, max_lives))
            
            if imgui.button(should_restart ? tprint("Restarting in %", view_seconds(t_restart, precision = 3)) : "Restart") {
                if !should_restart {
                    should_restart = true
                    t_restart = 0.3
                } else {
                    t_restart = 0
                }
            }
        }
        
        imgui.text("Stats")
        is_late := cast(f32) time.duration_seconds(_update) > TargetFrameTime
        imgui.text_colored(is_late ? Orange : White, tprint(`Update %`, _update))
        imgui.text(tprint("  matches %",   _matches))
        imgui.text(tprint("Render %", _render))
        imgui.text(tprint("Total %",  view_time_duration(_total, show_limit_as_decimal = true, precision = 3)))
        
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
                update(&collapse)
            } else {
                assert(len(collapse.tiles) != 0)
                
                t_restart -= rl.GetFrameTime()
                if t_restart <= 0 {
                    t_restart = 0
                    should_restart = false
                    if first_time {
                        first_time = false
                        
                        _total_start = time.now()
                        
                        region_index = 0
                        region = regions[region_index]
                        entangle_grid(&collapse, full_region)
                    } else {
                        tries += 1
                        if region_index == 0 {
                            entangle_grid(&collapse, region)
                        } else {
                            entangle_grid(&collapse, region, tries < max_lives ? max_depth : 0)
                            if tries >= max_lives {
                                entangle_grid(&collapse, full_region)
                                region_index = 0
                                tries = 0
                                region = regions[region_index]
                            }
                        }
                    }
                }
            }
            
            if collapse.state != .Done {
                _total = time.since(_total_start)
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
        rlimgui.ImGui_ImplRaylib_Render(imgui.get_draw_data())
        rl.EndDrawing()
    }
}

update :: proc (collapse: ^Collapse) {
    update_start := time.now()
    defer _update = time.since(update_start)
    
    update_done := false
    for !update_done {
        switch collapse.state {
          case .Uninitialized:
            update_done = true
        
          case .FindLowestEntropy:
            collapse.state = find_lowest_entropy(collapse, region)
            
          case .CollapseCell:
            cell := collapse_one_of_the_cells_with_lowest_entropy(collapse)
            assert(cell != nil)
            add_neighbours(collapse, cell.p, max_depth)
            collapse.state = .Propagation
            
          case .Propagation:
            if check, ok := get_next_check(collapse); ok {
                p := check.raw_p
                wrapped := rectangle_modulus(collapse.full_region, p)
                for w, dim in wrap do if w {
                    p[dim] = wrapped[dim]
                }
                pp := p
                p = wrapped
                
                cell := &collapse.grid[p.x + p.y * collapse.dimension.x]
                assert(cell.p == p)
                
                
                if wave, ok := &cell.value.(WaveFunction); ok {
                    // @speed O(n*m*d)
                    // n = a.wave.state_count
                    // m = b.wave.state_count
                    // d = len(Direction)
                    
                    changed: b32
                    loop: for &state, index in wave.states do if state {
                        for direction in Direction {
                            bp := p + Delta[direction]
                            bwrapped := rectangle_modulus(collapse.full_region, bp)
                            for w, dim in wrap do if w {
                                bp[dim] = bwrapped[dim]
                            }
                            
                            if contains(collapse.full_region, bp) {
                                b := &collapse.grid[bp.x + bp.y * collapse.dimension.x]
                                if !matches(collapse, index, b, direction) {
                                    changed = true
                                    wave_remove_state(collapse, cell, wave, index)
                                    continue loop
                                }
                            }
                        }
                    }
                    
                    if changed {
                        if contains(region, pp) {
                            wave_recompute_entropy(collapse, wave)
                            
                            add_neighbours(collapse, cell.p, check.depth)
                        }
                    }
                }
                
            } else {
                collapse.state = .FindLowestEntropy
            }
            k := 123
            
          case .Contradiction:
            if !should_restart {
                should_restart = true
                t_restart = wait_time
            }
            
          case .Done:
            region_index += 1
            tries = 0
            if region_index < len(regions) {
                region = regions[region_index]
                entangle_grid(collapse, region, max_depth)
            } else {
                update_done = true
            }
        }
        
        if time.duration_seconds(time.since(update_start)) > TargetFrameTime * 0.9 {
            update_done = true
        }
    }
}

extract_tiles :: proc (using collapse: ^Collapse, img: rl.Image) {
    sockets := make(map[u32]u32, context.temp_allocator)
    next_socket_index: u32
    
    Socket :: struct {
        pixels: []rl.Color, // 2*center * Kernel*center
    }
    
    assert(img.format == .UNCOMPRESSED_R8G8B8A8)
    pixels := (cast([^]rl.Color) img.data)[:img.width * img.height]
    
    tile_pixels := make([dynamic]rl.Color, Kernel*center * Kernel*center, context.temp_allocator)
    data := make([dynamic]u8, context.temp_allocator)
    
    for min_y in 0..<img.height/center {
        for min_x in 0..<img.width/center {
            clear(&tile_pixels)
            clear(&data)
            
            tile: Tile
            for ky in i32(0)..<Kernel*center {
                for kx in i32(0)..<Kernel*center {
                    x := (min_x*center + kx) % img.width
                    y := (min_y*center + ky) % img.height
                    pixel := pixels[y*img.width+x]
                    append_elems(&tile_pixels, pixel)
                }
            }
            
            tile_pixels := tile_pixels[:]
            rw := 3 * center
            len := 2*center * Kernel*center
            
            {
                west, east: Socket
                west.pixels = make([]rl.Color, len, context.temp_allocator)
                east.pixels = make([]rl.Color, len, context.temp_allocator)
                
                sw := 2 * center
                for y in 0..<3 * center {
                    for x in 0..<sw {
                        west.pixels[y*sw + x] = tile_pixels[y*rw + x]
                        east.pixels[y*sw + x] = tile_pixels[y*rw + x+center]
                    }
                }
                
                west_hash := hash.djb2(slice_to_bytes(west.pixels))
                if west_hash not_in sockets {
                    sockets[west_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.West] = sockets[west_hash]
                
                east_hash := hash.djb2(slice_to_bytes(east.pixels))
                if east_hash not_in sockets {
                    sockets[east_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.East] = sockets[east_hash]
            }
            
            {
                south, north: Socket
                south.pixels = make([]rl.Color, len, context.temp_allocator)
                north.pixels = make([]rl.Color, len, context.temp_allocator)
                
                sw := 3 * center
                for y in 0..<2 * center {
                    for x in 0..<sw {
                        south.pixels[y*sw + x] = tile_pixels[(y+center)*rw + x]
                        north.pixels[y*sw + x] = tile_pixels[y*rw + x]
                    }
                }
                
                north_hash := hash.djb2(slice_to_bytes(north.pixels))
                if north_hash not_in sockets {
                    sockets[north_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.North] = sockets[north_hash]
                
                south_hash := hash.djb2(slice_to_bytes(south.pixels))
                if south_hash not_in sockets {
                    sockets[south_hash] = next_socket_index
                    next_socket_index += 1
                }
                tile.sockets_index[Direction.South] = sockets[south_hash]
            }
            
            {
                tile.center = make([]rl.Color, center*center)
                cw := center
                for y in 0..<center {
                    for x in 0..<cw {
                        tile.center[y*cw + x] = tile_pixels[(y+center)*rw + x]
                    }
                }
                
                for &it in tile.center        do append_elems(&data, ..to_bytes(&it))
                for &it in tile.sockets_index do append_elems(&data, ..to_bytes(&it))
                tile.hash = hash.djb2(data[:])
            }
            
            if present, ok := is_present(collapse, tile); ok {
                present.frequency += 1
            } else {
                temp := rl.Image {
                    data    = raw_data(tile_pixels), 
                    width   = center*Kernel, 
                    height  = center*Kernel, 
                    mipmaps = 1, 
                    format = .UNCOMPRESSED_R8G8B8A8,
                }
                tile.texture = rl.LoadTextureFromImage(temp)
                tile.frequency = 1
                append_elem(&tiles, tile)
            }
        }
    }
}

is_present :: proc (using collapse: ^Collapse, tile: Tile) -> (result: ^Tile, ok: bool) {
    loop: for &it in tiles {
        if tile.hash == it.hash {
            result = &it
            break loop
        }
    }
    
    return result, result != nil
}

add_neighbours :: proc (using collapse: ^Collapse, p: v2i, depth: i32) {
    for delta in Delta {
        maybe_append_to_check(collapse, p + delta, depth-1)
    }
}

draw_wave :: proc (using collapse: ^Collapse, wave: WaveFunction, p: v2, size: v2) {
    when true {
        total := cast(f32) len(tiles)
        count := cast(f32) wave.states_count
        if count != 0 {
            ratio := (1-safe_ratio_0(count, total))
            color := cast(rl.Color) vec_cast(u8, v4{ratio, ratio, ratio, 1-ratio} * 255)
            rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, color)
        } else {
            rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, {0xff, 0, 0xff, 0xff})
        }
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
        
        if count != 0 {
            average := safe_ratio_0(sum, count)
            color := cast(rl.Color) vec_cast(u8, average)
            rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, color)
        } else {
            rl.DrawRectangleRec({p.x, p.y, size.x, size.y}, rl.RED)
        }
    }
}

get_screen_p :: proc (dimension: v2i, size: f32, p: v2i) -> (result: v2) {
    result = vec_cast(f32, p) * size
    
    result += (vec_cast(f32, Screen_Size) - (size * vec_cast(f32, dimension))) * 0.5
    
    return result
}