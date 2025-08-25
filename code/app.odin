package main

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"

ui :: proc (c: ^Collapse, images: map[string] File) {
    imgui.begin("Extract")
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &this_frame.desired_N, 1, 10)
        imgui.slider_int("Size X", &this_frame.desired_dimension.x, 3, 50)
        imgui.slider_int("Size Y", &this_frame.desired_dimension.y, 3, 50)
        if this_frame.desired_dimension != dimension {
            this_frame.tasks += { .resize_grid }
        }
        
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
    } else {
        if imgui.button("Pause") do paused = true
        this_frame.tasks += { .update }
    }
    imgui.text(tprint("%", update_state))
    
    if update_state >= .Search_Cells {
        imgui.text(tprint("Total time %",  view_time_duration(total_duration, precision = 3)))
    }
    
    if len(c.states) != 0 {
        if update_state == .Initialize_Supports {
            percent := view_percentage(init_cell_index, len(cells))
            imgui.text_unformatted(tprint("Restart: % %%", percent))
        } else {
            if imgui.button("Restart") {
                this_frame.tasks += { .restart }
            }
        }
    }
        
    imgui.checkbox("Average Color", &render_wavefunction_as_average)
    imgui.checkbox("Show Neighbours", &show_neighbours)
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
    
    neighbours := [Neighbour_Kind] string {
        .Closest_N = "Closest N neighbours",
        .Threshold = "Distance Threshold",
    }
    imgui.text("Neighbour Mode")
    
    before := neighbour_mode
    for text, mode in neighbours {
        b := mode in neighbour_mode.kind
        if imgui.checkbox(text, &b) {
            if  b do neighbour_mode.kind += { mode }
            if !b do neighbour_mode.kind -= { mode }
        }
    }
    
    if .Threshold in neighbour_mode.kind {
        imgui.slider_float("Threshold", &neighbour_mode.threshold, 0, 5)
    }
    if .Closest_N in neighbour_mode.kind {
        imgui.slider_int("Amount", &neighbour_mode.amount, 0, 15)
        imgui.checkbox("allow multiple at same distance", &neighbour_mode.allow_multiple_at_same_distance)
    }
    
    if before != neighbour_mode do this_frame.tasks += { .resize_grid }
    
    imgui.slider_int("Show index", &show_index, -1, 99)
    
    if imgui.slider_int("Generate Kind", &Generate_Kind, -1, 5) {
        this_frame.tasks += { .resize_grid }
    }
    
    imgui.begin("Viewing")
        if viewing_group != nil {
            if imgui.button("Stop viewing") {
                viewing_group = nil
            }
        }
        
        imgui.columns(2)
        imgui.text("Center")
        imgui.next_column()
        imgui.text("Neighbour")
        imgui.next_column()
        for &group, index in color_groups {
            {
                selected := &group == viewing_group
                if imgui.radio_button(tprint("v%", index), selected) {
                    viewing_group = &group
                }
                imgui.next_column()
                
                imgui.color_button("", rl_color_to_v4(group.color), flags = color_edit_flags_just_display)
                
                imgui.next_column()
            }
        }
        imgui.columns()
        
        imgui.slider_float("Start Angle", &view_slice_start, 0, Tau)
        imgui.slider_int("Subdivision", &view_slices, 1, 500, flags = .Logarithmic)
        
        imgui.text("Directional Spread")
        view_modes := [View_Mode] string {
            .Cos         = "Gradual",
            .AcosCos     = "Linear",
            .AcosAcosCos = "Steep",
        }
        for text, mode in view_modes {
            if imgui.button(tprint("% %", text, mode == view_mode ? "*" : "")) do view_mode = mode
        }
        
    imgui.end()
}