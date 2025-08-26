package main

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"

ui :: proc (c: ^Collapse, images: map[string] File, this_frame: ^Frame) {
    imgui.begin("Extract")
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &desired_N, 1, 10)
        
        if len(c.states) == 0 {
            imgui.text("Select an input image")
        }
        
        imgui.columns(4)
        for _, &image in images {
            imgui.push_id(&image)
            if imgui.image_button(auto_cast &image.texture.id, 30) {
                if image.image.format == .UNCOMPRESSED_R8G8B8 {
                    make(&this_frame.pixels, image.image.width * image.image.height, context.temp_allocator)
                    // @leak
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
    imgui.color_edit4("Background", &grid_background_color, flags = .NoInputs | .NoTooltip | .Float)
    
    tile_count := len(c.states)
    imgui.text_colored(tile_count > 200 ? Red : White, tprint("Tile count %", tile_count))

    if paused {
        if imgui.button("Unpause") do paused = false
        if imgui.button("Step")    {
            this_frame.tasks += { .update }
        }
        // @todo(viktor): step until next phase
    } else {
        if imgui.button("Pause") do paused = true
        this_frame.tasks += { .update }
    }
    imgui.text(tprint("%", update_state))
    
    if len(c.states) != 0 {
        if update_state == .Initialize_Supports {
            percent := view_percentage(c.init_cell_index, len(cells))
            imgui.text_unformatted(tprint("Restart: % %%", percent))
        } else {
            if imgui.button("Restart") {
                this_frame.tasks += { .restart }
            }
        }
    }
        
    imgui.checkbox("Average Color", &render_wavefunction_as_average)
    imgui.checkbox("Highlight changing cells", &highlight_changes)
    
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
    
    if update_state >= .Search_Cells {
        imgui.text(tprint("Total time %",  view_time_duration(total_duration, precision = 3)))
    }
    
    imgui.begin("Viewing")
        if viewing_group != nil {
            if imgui.button("Stop viewing") {
                viewing_group = nil
            }
        }
        
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
        
        imgui.text("Directional Spread")
        view_modes := [View_Mode] string {
            .Nearest     = "Nearest",
            .Cos         = "Gradual",
            .AcosCos     = "Linear",
            .AcosAcosCos = "Steep",
        }
        for text, mode in view_modes {
            if imgui.button(tprint("% %", text, mode == view_mode ? "*" : "")) do view_mode = mode
        }
        
    imgui.end()
    
    imgui.begin("Cells")
        generates := [Generate_Kind] string {
            .Shifted_Grid = "Wonky Grid",
            .Grid = "Grid",
            .Hex_Vertical = "Hex Rows",
            .Hex_Horizontal = "Hex Columns",
            .Spiral = "Spiral",
            .Random = "White Noise",
            .BlueNoise = "Blue Noise",
            .Test = "Test",
        }
        imgui.text("Generate Kind")
        for text, kind in generates {
            if imgui.radio_button(text, kind == generate_kind) {
                generate_kind = kind
                this_frame.tasks += { .setup_grid }
            }
        }
        imgui.slider_int2("Size", &this_frame.desired_dimension, 3, 500)
        
        imgui.slider_int("Show index", &show_index, -1, auto_cast len(cells))
        imgui.checkbox("Show Neighbours", &show_neighbours)
        imgui.checkbox("Show Voronoi Cells", &show_voronoi_cells)
        
        neighbours := [Neighbour_Kind] string {
            .Closest_N = "Closest N neighbours",
            .Threshold = "Distance Threshold",
        }
        imgui.text("Neighbour Mode")
        
        for text, mode in neighbours {
            b := mode in neighbour_mode.kind
            if imgui.checkbox(text, &b) {
                if  b do this_frame.desired_neighbour_mode.kind += { mode }
                if !b do this_frame.desired_neighbour_mode.kind -= { mode }
            }
        }
        
        if .Threshold in neighbour_mode.kind {
            imgui.slider_float("Threshold", &this_frame.desired_neighbour_mode.threshold, 0.5, 2)
        }
        if .Closest_N in neighbour_mode.kind {
            imgui.slider_int("Amount", &this_frame.desired_neighbour_mode.amount, 0, 10)
            imgui.checkbox("allow multiple at same distance", &this_frame.desired_neighbour_mode.allow_multiple_at_same_distance)
        }
        
        
    imgui.end()
}