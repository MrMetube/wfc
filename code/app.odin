package main

import "core:fmt"
import rl "vendor:raylib"
import imgui "../lib/imgui"

step_depth: [dynamic] f32

ui :: proc (c: ^Collapse, images: map[string] File, this_frame: ^Frame, generates: ^[dynamic] Generate_Kind) {
    region: v2
    current := len(c.steps) != 0 ? peek(c.steps)^ : {}
    
    imgui.begin("Stats")
        imgui.text("Total time %v", total_duration)
        
        tile_count := len(c.states)
        imgui.text("Tile count %v", tile_count)
        imgui.text("Depth")
        
        imgui.plot_lines_float_ptr("##Depth", raw_data(step_depth), auto_cast len(step_depth))
        
    imgui.end()
    
    imgui.begin("Generate")
        imgui.get_content_region_avail(&region)
        
        imgui.push_item_width(region.x*0.5)
        if imgui.slider_int("Heat", &base_heat, 1, 8) {
            restart(this_frame, true)
        }
        imgui.pop_item_width()
        
        if imgui.button("Restart") do restart(this_frame)
        imgui.same_line()
        
        if paused {
            if imgui.button("Unpause") do paused = false
            
            if imgui.button("Step") {
                this_frame.tasks += { .update }
                wait_until_this_state = cast(Step_State) ((cast(int) current.state + 1) % len(Step_State))
            }
            imgui.same_line()
            
            if imgui.button("Update once") do this_frame.tasks += { .update }
            imgui.same_line()
            
            imgui.text("%v", current.state)
        } else {
            if imgui.button("Pause") do paused = true
            this_frame.tasks += { .update }
        }
        
        imgui.text("Steps")
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*2/3)
        if imgui.slider_int("View Step", auto_cast &viewing_step, 0, auto_cast current.step) {
            viewing_step_detached = viewing_step != current.step
        }
        imgui.pop_item_width()
        
        if viewing_step_detached {
            if imgui.button("View latest") do viewing_step_detached = false
            imgui.same_line()
            if imgui.button("Rewind to here") {
                this_frame.tasks += { .rewind  }
                this_frame.rewind_to = viewing_step
                viewing_step_detached = false
            }
        } else {
            viewing_step = current.step
        }
    imgui.end()
    
    imgui.begin("Grid")
        imgui.slider_int2("Size", &desired_dimension, 3, 500, flags = .Logarithmic)
        
        if imgui.button("Generate Graph") {
            this_frame.tasks += { .setup_grid }
            dimension = desired_dimension
        }
        
        imgui.text("Presets")
        for preset, index in presets {
            imgui.same_line(); if imgui.button(fmt.tprintf("P%v", index)) do preset(generates)
        }
        
        {
            for _, index in generates {
                is_active := index == active_generate_index
                if index != 0 do imgui.same_line()
                if imgui.radio_button(tprint("L%v", index), is_active) {
                    active_generate_index = index
                }
            }
            imgui.same_line()
            if imgui.button("New") {
                active_generate_index = len(generates)
                append(generates, Generate_Noise {
                    center = .5,
                    radius = .51,
                })
            }
            
            imgui.get_content_region_avail(&region)
            if active_generate_index >= 0 && active_generate_index < len(generates) { // Active one
                generate := &generates[active_generate_index]
                
                if imgui.button("Remove") do ordered_remove(generates, active_generate_index)
                
                _, is_grid := &generate.(Generate_Grid)
                _, is_circle := &generate.(Generate_Circle)
                _, is_noise := &generate.(Generate_Noise)
                if imgui.radio_button("Square", is_grid) {
                    generate ^= Generate_Grid {
                        radius = 0.51,
                        center = 0.5,
                    }
                }
                imgui.same_line()
                if imgui.radio_button("Circular", is_circle) {
                    generate ^= Generate_Circle { radius = .5, spiral_size = 1 }
                }
                imgui.same_line()
                if imgui.radio_button("Noise", is_noise) {
                    generate ^= Generate_Noise {
                        radius = 0.51,
                        center = 0.5,
                    }
                }
                
                imgui.indent(); defer imgui.unindent()
                imgui.push_item_width(region.x/2); defer imgui.pop_item_width()
                switch &kind in generate {
                case Generate_Grid:
                    degrees := kind.angle * DegreesPerRadian
                    imgui.slider_float("angle", &degrees, 0, 90, format = "%.0f°")
                    kind.angle = degrees * RadiansPerDegree
                    imgui.slider_float2("center", &kind.center, 0, 1)
                    imgui.slider_float2("radius", &kind.radius, 0, 1)
                    imgui.checkbox("hexagonal", &kind.is_hex)
                    
                case Generate_Circle:
                    imgui.slider_float("radius", &kind.radius, 0, 1)
                    imgui.slider_float("spiral", &kind.spiral_size, 0, 2)
                    
                case Generate_Noise:
                    imgui.slider_float2("center", &kind.center, 0, 1)
                    imgui.slider_float2("radius", &kind.radius, 0, 1)
                    imgui.slider_float("minimum distance", &kind.min_distance, 0, 1)    
                }
                
            }
        }
    imgui.end()
    
    imgui.begin("Visual Options")
        imgui.color_edit4("Background", &cells_background_color, flags = .NoInputs | .NoTooltip | .Float | .DisplayHsv)
        
        imgui.checkbox("Show step details", &show_step_details)
        
        imgui.text("Cells")
        imgui.checkbox("Show Cells", &show_cells)
        imgui.checkbox("Show Average Colors", &show_average_colors)
        imgui.checkbox("Show Points", &show_points)
        imgui.checkbox("Show Triangulation", &show_triangulation)
        imgui.checkbox("Show Voronoi Cells", &show_voronoi_cells)
        imgui.checkbox("Show Cells Filled", &show_cells_filled)
        imgui.checkbox("Show Heat", &show_heat)
        imgui.checkbox("Show Entropy", &show_entropy)
        
        imgui.get_content_region_avail(&region)
        imgui.push_item_width(region.x*1/2)
        imgui.slider_float("Cell Size", &voronoi_shape_t, 0, 1)
        imgui.pop_item_width()
    imgui.end()
    
    imgui.begin("Extraction")
        imgui.checkbox("Wrap X", &wrap_when_extracting.x)
        imgui.same_line()
        imgui.checkbox("Wrap Y", &wrap_when_extracting.y)
        
        imgui.text("Tile Size = 3x3")
        imgui.text("Select an input image")
        {
            imgui.get_content_region_avail(&region)
            image_width: f32 = 60
            pad: f32 = 6
            columns := max(1, round(int, region.x / (image_width+pad)))
            imgui.push_item_width(image_width)
            @static selected_image_index: int
            image_index := 0
            for _, &image in images {
                defer image_index += 1
                
                if image_index % columns != 0 do imgui.same_line()
                
                imgui.push_id(&image)
                factor: f32 = 0.7
                if image_index == selected_image_index do factor = 0.8
                
                if imgui.image_button(auto_cast &image.texture.id, size = image_width*factor, frame_padding = 1) {
                    selected_image_index = image_index
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
}