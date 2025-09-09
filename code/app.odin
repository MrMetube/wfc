package main

import rl "vendor:raylib"
import "lib:imgui"

step_depth: [dynamic] f32

ui :: proc (c: ^Collapse, images: map[string] File, this_frame: ^Frame) {
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
            
            if imgui.button("Rewind one step")  do this_frame.tasks += { .rewind  }
            
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
            
            for &cell in cells {
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
        
        generates := [Generate_Kind] string {
            .Grid           = "Grid",
            .Shifted_Grid   = "Wonky Grid",
            .Diamond_Grid   = "Diamond Grid",
            .Hex_Vertical   = "Hex Rows",
            .Hex_Horizontal = "Hex Columns",
            .Spiral         = "Spiral",
            .Random         = "White Noise",
            .BlueNoise      = "Blue Noise",
        }
        imgui.text("Grid Kind")
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x)
        imgui.begin_list_box("##generate_kind")
        for text, kind in generates {
            if imgui.radio_button(text, &generate_kind, kind) {
                this_frame.tasks += { .setup_grid }
            }
        }
        imgui.end_list_box()
        imgui.pop_item_width()
        
        imgui.slider_int2("Size", &this_frame.desired_dimension, 3, 300, flags = .Logarithmic)
        
    imgui.end()
    
    imgui.begin("Visualization")
        imgui.color_edit4("Background", &cells_background_color, flags = .NoInputs | .NoTooltip | .Float | .DisplayHsv )
        
        imgui.checkbox("Highlight step", &highlight_step)
        
        imgui.text("Cells")
        imgui.checkbox("Average Color", &render_wavefunction_as_average)
        imgui.checkbox("Show Neighbours", &show_neighbours)
        imgui.checkbox("Show Voronoi Cells", &show_voronoi_cells)
    imgui.end()
    
    imgui.begin("Extraction")
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*2/3)
        imgui.slider_int("Tile Size", &desired_N, 1, 10)
        imgui.pop_item_width()
        
        if len(c.states) == 0 {
            imgui.text("Select an input image")
        }
        
        {
            image_width: f32 = 60
            pad: f32 = 6
            columns := max(1, round(int, region.x / (image_width+pad)))
            imgui.push_item_width(image_width)
            image_index := 0
            for _, &image in images {
                defer image_index += 1
                column := image_index % columns
                if column != 0 do imgui.same_line(image_width * cast(f32) column + pad)
                
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
        if imgui.slider_float("Factor", &t_directional_strictness, 0, 1.5) {
            if viewing_group == nil {
                restart(this_frame)
            }
        }
        imgui.pop_item_width()
        
        imgui.get_content_region_avail(&region)
        imgui.progress_bar(1.5-t_directional_strictness, {region.x, 0}, overlay="Overlapping")
        imgui.progress_bar(t_directional_strictness-0,   {region.x, 0}, overlay="Separated")
        
        imgui.checkbox("Preview", &preview_angles)
        if preview_angles {
            @(static) angle: f32
            imgui.slider_float("Angle", &angle, 0, 360)
            radians := angle == 0 ? 0 : angle * RadiansPerDegree
            closeness := transmute([8] f32) get_closeness(arm(radians))
            
            imgui.get_content_region_avail(&region)
            for direction in Direction {
                imgui.progress_bar(closeness[direction], {region.x, 0}, overlay=tprint("%", direction))
            }
        }
        
        imgui.text("States")
        {
            imgui.get_content_region_avail(&region)
            group_width: f32 = 60
            group_pad: f32 = 6
            group_columns := max(1, round(int, region.x / (group_width+group_pad)))
            item_width := group_width/2
            imgui.push_item_width(item_width)
            group_index := 0
            for &group, index in color_groups {
                selected := &group == viewing_group
                
                defer group_index += 1
                column := group_index % group_columns
                if column != 0 do imgui.same_line(cast(f32) column * group_width + 0 * item_width)
                
                if imgui.radio_button(tprint("##v%", index), selected) {
                    viewing_group = &group
                }
                imgui.same_line(cast(f32) column * group_width + 1 * item_width)
                
                imgui.color_button("", group.color, flags = color_edit_flags_just_display)
            }
            imgui.pop_item_width()
        }
        
        if viewing_group != nil {
            if imgui.button("Stop viewing") {
                viewing_group = nil
            }
            imgui.image(auto_cast &viewing_render_target.texture.id, region.x)
        }
        
        
    imgui.end()
}