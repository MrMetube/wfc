package main

import rl "vendor:raylib"
import "lib:imgui"

step_depth: [dynamic] f32

ui :: proc (c: ^Collapse, images: map[string] File, this_frame: ^Frame) {
    spall_proc()
    
    imgui.begin("Extract")
        imgui.text("Choose Input Image")
        region: v2
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*2/3)
        imgui.slider_int("Tile Size", &desired_N, 1, 10)
        imgui.pop_item_width()
        
        if len(c.states) == 0 {
            imgui.text("Select an input image")
        }
        
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
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
            imgui.next_column()
        }
        imgui.columns(1)
    imgui.end()
    
    imgui.text("Stats")
    
    current := peek(c.steps)
    append(&step_depth, cast(f32) current.step)
    imgui.plot_lines_float_ptr("Depth", raw_data(step_depth), auto_cast len(step_depth), graph_size = {0, 100})
    
    imgui.color_edit4("Background", &cells_background_color, flags = .NoInputs | .NoTooltip | .Float | .DisplayHsv )
    
    tile_count := len(c.states)
    imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))

    if paused {
        if imgui.button("Unpause") do paused = false
        
        if imgui.button("Step") {
            this_frame.tasks += { .update }
            desired_update_state = cast(Update_State) ((cast(int) current.update_state + 1) % len(Update_State))
        }
        
        if imgui.button("Rewind")  do this_frame.tasks += { .rewind  }
        
        if imgui.button("Update once") do this_frame.tasks += { .update }
    } else {
        if imgui.button("Pause") do paused = true
        this_frame.tasks += { .update }
    }
    
    imgui.text(tprint("Current Step: %", cast(int) current.step))
    choices_count := len(c.steps)
    imgui.text(tprint("Choices since start: %", choices_count))
    
    imgui.text(tprint("%", current.update_state))
    if imgui.button("Restart") do this_frame.tasks += { .restart }
    
    imgui.checkbox("Average Color", &render_wavefunction_as_average)
    imgui.checkbox("Highlight step", &highlight_step)
    
    metrics := [Search_Metric] string {
        .States  = "fewest possible states",
        .Entropy = "lowest entropy",
    }
    imgui.text("Search Metric")
    for text, metric in metrics {
        if imgui.radio_button(text, metric == search_metric) {
            search_metric = metric
        }
    }
    
    imgui.text(tprint("Total time %",  view_time_duration(total_duration, precision = 3)))
    
    imgui.begin("Viewing")
        if viewing_group != nil {
            if imgui.button("Stop viewing") {
                viewing_group = nil
            }
        }
        
        imgui.text("Directional Spread")
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*2/3)
        if imgui.slider_float("Blend Factor %.1f", &view_mode_t, 0, 1) {
            if viewing_group == nil {
                this_frame.tasks += { .restart }
            }
        }
        imgui.pop_item_width()
        
        imgui.get_content_region_avail(&region)
        imgui.progress_bar(1-view_mode_t, {region.x, 0}, overlay="Cosine")
        imgui.progress_bar(view_mode_t-0, {region.x, 0}, overlay="Linear")
        
        imgui.columns(2)
        for &group, index in color_groups {
            selected := &group == viewing_group
            if imgui.radio_button(tprint("v%", index), selected) {
                viewing_group = &group
            }
            imgui.next_column()
            
            imgui.color_button("", rl_color_to_v4(group.color), flags = color_edit_flags_just_display)
            
            imgui.next_column()
        }
        imgui.columns()
    imgui.end()
    
    imgui.begin("Cells")
        generates := [Generate_Kind] string {
            .Grid           = "Grid",
            .Shifted_Grid   = "Wonky Grid",
            .Diamond_Grid   = "Diamond Grid",
            .Hex_Vertical   = "Hex Rows",
            .Hex_Horizontal = "Hex Columns",
            .Spiral         = "Spiral",
            .Random         = "White Noise",
            .BlueNoise      = "Blue Noise",
            .Test           = "Test",
        }
        imgui.text("Generate Kind")
        for text, kind in generates {
            if imgui.radio_button(text, &generate_kind, kind) {
                this_frame.tasks += { .setup_grid }
            }
        }
        imgui.slider_int2("Size", &this_frame.desired_dimension, 3, 300, flags = .Logarithmic)
        
        imgui.checkbox("Show Neighbours", &show_neighbours)
        imgui.checkbox("Show Voronoi Cells", &show_voronoi_cells)
    imgui.end()
}