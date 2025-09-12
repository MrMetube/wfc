package main

import rl "vendor:raylib"
import "lib:imgui"

step_depth: [dynamic] f32

ui :: proc (c: ^Collapse, images: map[string] File, this_frame: ^Frame, generates: ^[dynamic] Generate_Kind) {
    region: v2
    current := len(c.steps) != 0 ? peek(c.steps)^ : {}
    
    imgui.begin("Stats")
        imgui.text(tprint("Total time %",  view_time_duration(total_duration, precision = 3)))
        
        tile_count := len(c.states)
        imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))
        
        if len(step_depth) == 0 || (cast(f32) current.step != peek(step_depth)^) {
            append(&step_depth, cast(f32) current.step)
        }
        imgui.plot_lines_float_ptr("Depth", raw_data(step_depth), auto_cast len(step_depth), graph_size = {0, 100})
        
    imgui.end()
    
    imgui.begin("Controls")
        if paused {
            if imgui.button("Unpause") do paused = false
            
            if imgui.button("Step") {
                this_frame.tasks += { .update }
                wait_until_this_state = cast(Step_State) ((cast(int) current.state + 1) % len(Step_State))
            }
            
            if imgui.button("Update once") do this_frame.tasks += { .update }
            
            imgui.text(tprint("%", current.state))
        } else {
            if imgui.button("Pause") do paused = true
            this_frame.tasks += { .update }
        }
        
        if imgui.button("Restart") do restart(this_frame)
        
        imgui.text("Steps")
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*2/3)
        if imgui.slider_int("View Step", auto_cast &viewing_step, 0, auto_cast current.step) {
            viewing_step_detached = viewing_step != current.step
            
            for &cell in c.cells {
                calculate_average_color(c, &cell, viewing_step)
            }
        }
        imgui.pop_item_width()
        
        if viewing_step_detached {
            if imgui.button("View latest step") do viewing_step_detached = false
            if imgui.button("Rewind to viewed step") {
                this_frame.tasks += { .rewind  }
                this_frame.rewind_to = viewing_step
                viewing_step_detached = false
            }
        } else {
            viewing_step = current.step
        }
    
        metrics := [Search_Metric] string {
            .States  = "fewest possible states",
            .Entropy = "lowest entropy",
        }
        imgui.text("Search Metric")
        for text, metric in metrics {
            if imgui.radio_button(text, metric == c.search_metric) {
                c.search_metric = metric
            }
        }
        
        imgui.text("Grid")
        imgui.slider_int2("Size", &desired_dimension, 3, 300, flags = .Logarithmic)
        
        if imgui.button("Generate Grid") {
            this_frame.tasks += { .setup_grid }
            dimension = desired_dimension
        }
        
        {
            for _, index in generates {
                is_active := index == active_generate_index
                if index != 0 do imgui.same_line()
                if imgui.radio_button(tprint("%", index), is_active) do active_generate_index = index
            }
            imgui.same_line()
            if imgui.button("New") do append(generates, Generate_Noise {} )
            
            imgui.get_content_region_avail(&region)
            if active_generate_index >= 0 && active_generate_index < len(generates) { // Active one
                generate := &generates[active_generate_index]
                
                grid, is_grid := &generate.(Generate_Grid)
                if imgui.radio_button("Square", is_grid) {
                    generate ^= Generate_Grid {
                        radius = 0.5,
                    }
                }
                if is_grid {
                    imgui.indent(); defer imgui.unindent()
                    imgui.push_item_width(region.x/2); defer imgui.pop_item_width()
                    
                    imgui.slider_float("angle", &grid.angle, 0, Tau/4)
                    imgui.slider_float2("center", &grid.center, 0, 1)
                    imgui.slider_float2("radius", &grid.radius, 0, 1)
                    imgui.checkbox("hexagonal", &grid.is_hex)
                }
                
                circle, is_circle := &generate.(Generate_Circle)
                if imgui.radio_button("Circular", is_circle) {
                    generate ^= Generate_Circle { radius = .25 }
                }
                if is_circle {
                    imgui.indent();                    defer imgui.unindent()
                    imgui.push_item_width(region.x/2); defer imgui.pop_item_width()
                    
                    imgui.slider_float("radius", &circle.radius, 0, 1)
                    imgui.slider_float("spiral", &circle.spiral_strength, 0, 2)
                }
                
                noise, is_noise := &generate.(Generate_Noise)
                if imgui.radio_button("Noise", is_noise) {
                    generate ^= Generate_Noise {}
                }
                if is_noise {
                    imgui.indent(); defer imgui.unindent()
                    
                    imgui.checkbox("blue noise", &noise.is_blue)
                }
                
                if imgui.button("Remove") do ordered_remove(generates, active_generate_index)
            }
        }
    imgui.end()
    
    imgui.begin("Visualization")
        imgui.color_edit4("Background", &cells_background_color, flags = .NoInputs | .NoTooltip | .Float | .DisplayHsv)
        
        imgui.checkbox("Show step details", &show_step_details)
        
        imgui.text("Cells")
        imgui.checkbox("Show Average Colors", &show_average_colors)
        imgui.checkbox("Show Neighbours", &show_neighbours)
        imgui.checkbox("Show Voronoi Cells", &show_voronoi_cells)
    imgui.end()
    
    imgui.begin("Extraction")
        imgui.checkbox("Wrap X", &wrap_in_extraction.x)
        imgui.same_line()
        imgui.checkbox("Wrap Y", &wrap_in_extraction.y)
        
        imgui.text("Tile Size = 3")
        imgui.text("Select an input image")
        {
            imgui.get_content_region_avail(&region)
            image_width: f32 = 60
            pad: f32 = 6
            columns := max(1, round(int, region.x / (image_width+pad)))
            imgui.push_item_width(image_width)
            image_index := 0
            for _, &image in images {
                defer image_index += 1
                
                if image_index % columns != 0 do imgui.same_line()
                
                imgui.push_id(&image)
                if imgui.image_button(auto_cast &image.texture.id, size = image_width*0.8, frame_padding = 1) {
                    if image.image.format == .UNCOMPRESSED_R8G8B8 {
                        make(&this_frame.pixels, image.image.width * image.image.height, context.temp_allocator)
                        
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
            }
        }
    imgui.end()
    
    imgui.begin("Neighbourhood")
        imgui.get_content_region_avail(&region)
        
        imgui.text("Directional Strictness")
        imgui.push_item_width(region.x*0.5)
        if imgui.slider_int("Bucket Count", &strictness, 1, 8) {
            restart(this_frame)
        }
        imgui.pop_item_width()
        
        // // @todo(viktor): its a boolean value, so no f32s
        @(static) angle: f32
        imgui.slider_float("Angle", &angle, 0, 360)
        radians := angle == 0 ? 0 : angle * RadiansPerDegree
        closeness := get_closeness(arm(radians))
        
        imgui.get_content_region_avail(&region)
        for direction in Direction {
            imgui.progress_bar(direction in closeness ? 1 : 0, {region.x, 0}, overlay=tprint("%", direction))
        }
    imgui.end()
}