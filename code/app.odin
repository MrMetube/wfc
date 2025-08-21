package main

import rl "vendor:raylib"
import imgui "../lib/odin-imgui/"

ui :: proc (c: ^Collapse, images: map[string] File) {
    imgui.begin("Extract")
        imgui.text("Choose Input Image")
        imgui.slider_int("Tile Size", &this_frame.desired_N, 1, 10)
        imgui.slider_int("Size X", &this_frame.desired_dimension.x, 3, 300)
        imgui.slider_int("Size Y", &this_frame.desired_dimension.y, 3, 150)
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
    
    if update_state >= .Search_Cells {
        imgui.text(tprint("Total time %",  view_time_duration(total_duration, precision = 3)))
    } else {
        if update_state == .Initialize_Supports {
            imgui.text_unformatted(tprint("Restart: % %%", view_percentage(init_cell_index, len(grid))))
        }
        
    }
    
    if len(c.states) != 0 {
        if imgui.button("Restart") {
            this_frame.tasks += { .restart }
        }
    }
    
    if paused {
        if imgui.button("Unpause") do paused = false
        if imgui.button("Step")    {
            this_frame.tasks += { .update }
        }
    } else {
        if imgui.button("Pause") do paused = true
        this_frame.tasks += { .update }
    }
    
    imgui.checkbox("Average Color", &render_wavefunction_as_average)
    imgui.checkbox("Show triangles", &show_triangulation)
    imgui.checkbox("Highlight changing cells", &highlight_changes)
    imgui.checkbox("Overlay drawing", &highlight_drawing)
    
    modes := [Search_Mode] string {
        .Scanline = "top to bottom, left to right",
        .Metric   = "search by a metric",
    }
    metrics := [Search_Metric] string {
        .States  = "fewest possible states",
        .Entropy = "lowest entropy",
    }
    for text, mode in modes {
        if imgui.radio_button(text, mode == search_mode) {
            search_mode = mode
        }
    }
    if search_mode == .Metric {
        imgui.tree_push("Metric")
        for text, metric in metrics {
            if imgui.radio_button(text, metric == search_metric) {
                search_metric = metric
            }
        }
        imgui.tree_pop()
    }
    
    imgui.begin("Drawing")
        if imgui.button("Clear drawing") {
            this_frame.tasks += { .clear_drawing }
        }
        
        if imgui.radio_button("Erase", selected_group == nil) {
            selected_group = nil
        }
        
        imgui.columns(2)
        for &group, index in draw_groups {
            selected := &group == selected_group
            if imgui.radio_button(tprint("%", index), selected) {
                selected_group = &group
            }
            imgui.next_column()
            
            imgui.color_button("", rl_color_to_v4(group.color), flags = color_edit_flags_just_display)
            imgui.next_column()
        }
        imgui.columns()
    imgui.end()
    
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
        for &group, index in draw_groups {
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

clear_draw_board :: proc () {
    for &it in draw_board do it = nil
}

restrict_cell_to_drawn :: proc (c: ^Collapse, p: v2i, group: ^Draw_Group) {
    selected := group.ids
    
    cell := &grid[p.x + p.y * dimension.x]
    if !cell.collapsed {
        for id in cell.states {
            is_selected:= selected[id]
            if !is_selected {
                remove_state(c, cell, id)
            }
        }
    }
}
