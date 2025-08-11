#+private
package build
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"
import win "core:sys/windows"

optimizations := false ? ` -o:speed ` : ` -o:none `
Pedantic      :: false

flags    :: ` -error-pos-style:unix -vet-cast -vet-shadowing -ignore-vs-search -use-single-module -microarch:native -target:windows_amd64`
debug    :: ` -debug `
windows  := !true ? ` -subsystem:windows ` : ` -subsystem:console `
pedantic :: ` -warnings-as-errors -vet-unused-imports -vet-semicolon -vet-unused-variables -vet-style -vet-packages:main -vet-unused-procedures` 
check    :: ` -custom-attribute:printlike `
flags_for_imgui :: ` -extra-linker-flags:"/NODEFAULTLIB:LIBCMTD" `

build_src_path :: `.\build\`   
build_exe_path :: `.\build\build.exe`

build_dir :: `.\build\`
data_dir  :: `.\data`

odin      :: ODIN_ROOT + `odin.exe`
code_dir  :: `..\code` 

main :: proc() {
    context.allocator = context.temp_allocator
    
    // @todo(viktor): I am no longer using any of the vscode features for debugging and running so why am I not just making a tiny build app that has some global keyboard shortcuts for the stuff i need? I could delete so much javascript from this world <3. 
    
    // @todo(viktor): make force rebuild param explicit
    go_rebuild_yourself()
    
    make_directory_if_not_exists(data_dir)
    
    err := os.set_current_directory(build_dir)
    assert(err == nil)
    
    if !check_printlikes(code_dir) do os.exit(1)
    
    debug_exe :: `debug.exe`
    // @todo(viktor): make .Kill and such also setable from the command line
    if handle_running_exe_gracefully(debug_exe, .Kill) {
        args: [dynamic]string
        odin_build(&args, code_dir, `.\`+debug_exe)
        append(&args, flags)
        append(&args, debug)
        append(&args, flags_for_imgui)
        append(&args, check)
        append(&args, windows)
        append(&args, optimizations)
        if Pedantic do append(&args, pedantic)
        run_command_or_exit(odin, args[:])
    }
    
    fmt.println("\nDone.\n")
}



















Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Rename,
    Kill,
}

handle_running_exe_gracefully :: proc(exe_name: string, handling: Handle_Running_Exe) -> (ok: b32) {
    if ok, pid := is_running(exe_name); ok {
        switch handling {
          case .Skip:
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Skipping build.", exe_name)
            return false
            
          case .Abort: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Aborting build!", exe_name)
            os.exit(0)
            
          case .Kill: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Killing running instance in order to build.", exe_name)
            handle := win.OpenProcess(win.PROCESS_TERMINATE, false, pid, )
            if handle != nil {
                win.TerminateProcess(handle, 0)
                win.CloseHandle(handle)
            }
            return true
            
          case .Rename:
            // @todo(viktor): cleanup the renamed exes when they close
            new_name := fmt.tprintf(`%v-%d.exe`, exe_name, random_number())
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Renaming running instance to '%v' in order to build.", exe_name, new_name)
            _ = os2.rename(exe_name, new_name)
            return true
        }
    }
    
    return true
}

odin_build :: proc(args: ^[dynamic]string, dir: string, out: string) {
    append(args, `odin build `)
    append(args, dir)
    append(args, ` -out:`)
    append(args, out)
    append(args, ` `)
}

Error :: union { os2.Error, os.Error }

go_rebuild_yourself :: proc() -> Error {
    if strings.ends_with(os.get_current_directory(), "build") {
        os.set_current_directory("..") or_return
    }
    
    gitignore := fmt.tprint(build_dir, `\.gitignore`, sep="")
    if !os.exists(gitignore) {
        contents := "*\n!*.odin"
        os.write_entire_file(gitignore, transmute([]u8) contents)
    }
    
    needs_rebuild := false
    if len(os.args) > 1 {
        // @todo(viktor): validate param
        needs_rebuild = true
    }
    
    build_exe_info, err := os.stat(build_exe_path)
    if err != nil {
        needs_rebuild = true
    }
    
    if !needs_rebuild {
        src_dir := os2.read_all_directory_by_path(build_src_path, context.allocator) or_return
        for file in src_dir {
            if strings.ends_with(file.name, ".odin") {
                if time.diff(file.modification_time, build_exe_info.modification_time) < 0 {
                    needs_rebuild = true
                    break
                }
            }
        }
    }
    
    // @todo(viktor): do we still need the old one?
    old_path := fmt.tprintf("%s-old", build_exe_path)
    remove_if_exists(old_path)
    
    if needs_rebuild {
        fmt.println("Rebuilding!")
        
        pdb_path, _ := strings.replace_all(build_exe_path, ".exe", ".pdb")
        remove_if_exists(pdb_path)
        os.rename(build_exe_path, old_path) or_return
        
        args: [dynamic]string
        odin_build(&args, build_src_path, build_exe_path)
        append(&args, debug)
        append(&args, flags)
        append(&args, pedantic)
        if !run_command(odin, args[:]) {
            os.rename(old_path, build_exe_path) or_return
        }
        
        fmt.println("\nDone.\n")
        os.exit(0)
    }
    
    return nil
}

remove_if_exists :: proc(path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc(pattern: string) {
    find_data := win.WIN32_FIND_DATAW{}

    handle := win.FindFirstFileW(win.utf8_to_wstring(pattern), &find_data)
    if handle == win.INVALID_HANDLE_VALUE do return
    defer win.FindClose(handle)
    
    for {
        file_name, err := win.utf16_to_utf8(find_data.cFileName[:])
        assert(err == nil)
        file_path := fmt.tprintf(`.\%v`, file_name)
        
        os.remove(file_path)
        if !win.FindNextFileW(handle, &find_data){
            break 
        }
    }
}

is_running :: proc(exe_name: string) -> (running: b32, pid: u32) {
    snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPALL, 0)
    assert(snapshot != win.INVALID_HANDLE_VALUE, "could not take a snapshot of the running programms")
    defer win.CloseHandle(snapshot)

    process_entry := win.PROCESSENTRY32W{ dwSize = size_of(win.PROCESSENTRY32W)}

    if win.Process32FirstW(snapshot, &process_entry) {
        for {
            test_name, err := win.utf16_to_utf8(process_entry.szExeFile[:])
            assert(err == nil)
            if exe_name == test_name {
                return true, process_entry.th32ProcessID
            }
            if !win.Process32NextW(snapshot, &process_entry) {
                break
            }
        }
    }

    return false, 0
}

run_command_or_exit :: proc(program: string, args: []string) {
    if !run_command(program, args) {
        os.exit(1)
    }
}

run_command :: proc(program: string, args: []string = {}) -> (success: b32) {
    startup_info := win.STARTUPINFOW{ cb = size_of(win.STARTUPINFOW) }
    process_info := win.PROCESS_INFORMATION{}
    
    
    working_directory := win.utf8_to_wstring(os.get_current_directory())
    joined_args := strings.join(args, "")
    
    fmt.println("CMD:", joined_args, "#", program)
    
    if win.CreateProcessW(win.utf8_to_wstring(program), win.utf8_to_wstring(joined_args), nil, nil, win.TRUE, 0, nil, working_directory, &startup_info, &process_info) {
        win.WaitForSingleObject(process_info.hProcess, win.INFINITE)
        
        exit_code: win.DWORD
        win.GetExitCodeProcess(process_info.hProcess, &exit_code)
        success = exit_code == 0
        
        win.CloseHandle(process_info.hProcess)
        win.CloseHandle(process_info.hThread)
    } else {
        fmt.printfln("ERROR: Command failed to start with error '%s'", os.error_string(os.get_last_error()))
        success = false
    }
    return
}

make_directory_if_not_exists :: proc(path: string) -> (result: b32) {
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

random_number :: proc() -> (result: u32) {
    return cast(u32) intrinsics.read_cycle_counter() % 255
}