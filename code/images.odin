package main

import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import rl "vendor:raylib"

load_images :: proc (images: ^[dynamic] File) {
    image_dir := "./images"
    if len(os.args) > 1 {
        if len(os.args) > 2 {
            fmt.printfln("Usage: %v [<path/to/images/directory>]", os.args[0])
            os.exit(1)
        }
        image_dir = os.args[1]
    }
    file_type := ".png"
    infos, err := os2.read_directory_by_path(image_dir, 0, context.temp_allocator)
    if err != nil {
        print("Error reading image directory %v: %v", image_dir, err)
        os.exit(1)
    }
    for info in infos {
        if info.type == .Regular {
            if strings.ends_with(info.name, file_type) {
                data, ferr := os2.read_entire_file(info.fullpath, context.allocator)
                if ferr != nil do print("Error reading file %v:%v\n", info.name, ferr)
                
                cstr := ctprint("%v", file_type)
                
                image := File { data = data }
                image.image   = rl.LoadImageFromMemory(cstr, raw_data(image.data), auto_cast len(image.data))
                image.texture = rl.LoadTextureFromImage(image.image)
                append(images, image)
            }
        }
    }
}