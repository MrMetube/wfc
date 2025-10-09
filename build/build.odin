
package build

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"
import win "core:sys/windows"

optimizations := !false ? `-o:speed` : `-o:none`
Pedantic      :: false

debug    :: `-debug`
check    :: `-custom-attribute:printlike`

flags    := [] string {`-error-pos-style:unix`,`-vet-cast`,`-vet-shadowing`,`-microarch:native`,`-target:windows_amd64`}
pedantic := [] string {
    `-warnings-as-errors`,`-vet-unused-imports`,`-vet-semicolon`,`-vet-unused-variables`,`-vet-style`,
    `-vet-packages:main`,`-vet-unused-procedures`
}

lib             :: `-collection:lib=../lib/`
flags_for_imgui :: `-extra-linker-flags:/NODEFAULTLIB:LIBCMTD`

////////////////////////////////////////////////

build_src_path :: `.\build\`   
build_exe_name :: `build.exe`

build_dir   :: `.\build\`
data_dir    :: `.\data`
code_dir    :: `..\code` 
raddbg      :: `raddbg.exe`
raddbg_path :: `C:\tools\raddbg\`+ raddbg

debug_exe :: `debug.exe`
debug_exe_path :: `.\`+debug_exe

////////////////////////////////////////////////

Task :: enum {
    help,
    debugger, 
    run,
    renderdoc,
}
Tasks :: bit_set [Task]

tasks: Tasks

main :: proc() {
    context.allocator = context.temp_allocator

    for arg, index in os.args[1:] {
        switch arg {
          case "run":       tasks += { .run }
          case "debugger":  tasks += { .debugger }
          case "help":      tasks += { .help }
          case "renderdoc": tasks += { .renderdoc }
          case:             tasks += { .help }
        }
    }
    
    if .help in tasks {
        usage()
        os.exit(1)
    }
    
    make_directory_if_not_exists(data_dir)
    err := os.set_current_directory(build_dir)
    assert(err == nil)
    
    if !check_printlikes(code_dir) do os.exit(1)
    
    cmd: Cmd
    if .debugger in tasks {
        if ok, pid := is_running(raddbg); ok {
            fmt.printfln("INFO: Killing running debugger in order to build.")
            kill(pid)
        }
    }
    
    // @todo(viktor): make .Kill and such also setable from the command line
    if handle_running_exe_gracefully(debug_exe, .Kill) {
        build := true
        if (tasks & {.debugger, .renderdoc }) != {} {
            if !did_change(debug_exe_path, code_dir) {
                fmt.println("INFO: No changes detected. Skipping build.")
                build = false
            }
        }
        
        if build {
            odin_build(&cmd, code_dir, debug_exe_path)
            append(&cmd, ..flags)
            append(&cmd, debug)
            append(&cmd, flags_for_imgui)
            append(&cmd, check)
            append(&cmd, lib)
            append(&cmd, optimizations)
            when Pedantic do append(&cmd, ..pedantic)
            
            run_command(&cmd)
        }
    }
    
    fmt.println("INFO: Build done.\n")
    
    procs: Procs
    if .renderdoc in tasks {
        fmt.println("INFO: Starting the Program with RenderDoc attached.")
        renderdoc_cmd := `C:\Program Files\RenderDoc\renderdoccmd.exe`
        renderdoc_gui := `C:\Program Files\RenderDoc\qrenderdoc.exe`
        
        os.change_directory("..")
        append(&cmd, renderdoc_cmd, `capture`, `-d`, data_dir, `-c`, `.\capture`, build_dir + debug_exe_path)
        run_command(&cmd)
        
        os.change_directory(data_dir)
        captures := all_like("capture*")
        // @todo(viktor): What if we had multiple captures?
        if len(captures) == 1 {
            append(&cmd, renderdoc_gui, captures[0])
            run_command(&cmd)
            // @todo(viktor): Ask if old should be deleted?
            fmt.printfln("INFO: Cleanup old captures")
            for capture in captures {
                os.remove(capture)
            }
        } else if len(captures) == 0 {
            fmt.printfln("INFO: No captures made, not starting RenderDoc.")
        } else {
            fmt.printfln("INFO: More than one capture made, please select for yourself.")
            append(&cmd, "cmd", "/c", "start", ".")
            run_command(&cmd)
        }
    }
    
    if .debugger in tasks {
        fmt.println("INFO: Starting the Rad Debugger.")
        // @study(viktor): raddbg -ipc usage
        append(&cmd, raddbg_path)
        if .run in tasks {
            append(&cmd, "--auto_run")
        }
        run_command(&cmd, async = &procs)
    } else {
        if .run in tasks {
            fmt.println("INFO: Starting the Program.")
            os.change_directory("..")
            os.change_directory(data_dir)
            append(&cmd, debug_exe)
            run_command(&cmd, async = &procs)
        }
    }
    
    if len(cmd) != 0 {
        fmt.println("INFO: cmd was not cleared: ", strings.join(cmd[:], " "))
    }
}

usage :: proc () {
    fmt.printf(`Usage:
  %v [<options>]
Options:
`, os.args[0])
    infos := [Task] string {
        .help      = "Print this usage information.",
        .debugger  = "Start/Restart the debugger.",
        .run       = "Run the program.",
        .renderdoc = "Run the program with renderdoc attached and launch renderdoc with the capture after the program closes.",
    }
    // Ughh..
    width: int
    for task in Task do width = max(len(fmt.tprint(task)), width)
    format := fmt.tprintf("  %%-%vv - %%v\n", width)
    for text, task in infos do fmt.printf(format, task, text)
}

Procs :: [dynamic] os2.Process
Cmd   :: [dynamic] string



















Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Rename,
    Kill,
}

handle_running_exe_gracefully :: proc(exe_name: string, handling: Handle_Running_Exe) -> (ok: b32) {
    pid: u32
    ok, pid = is_running(exe_name)
    if ok {
        switch handling {
          case .Skip:
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Skipping build.", exe_name)
            return false
            
          case .Abort: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Aborting build!", exe_name)
            os.exit(0)
            
          case .Kill: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running.", exe_name)
            fmt.printfln("INFO: Killing running instance in order to build.")
            kill(pid)
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

odin_build :: proc(cmd: ^[dynamic]string, dir: string, out: string) {
    append(cmd, "odin")
    append(cmd, "build")
    append(cmd, dir)
    append(cmd, fmt.tprintf("-out:%v", out))
}









did_change :: proc (output_path: string, inputs: .. string, extension: string = ".odin") -> (result: bool) {
    output_info, err := os.stat(output_path)
    if err != nil {
        result = true
    } else {
        search: for input in inputs {
            files : [] os2.File_Info
            error: os2.Error
            if os.is_dir(input) {
                files, error = os2.read_all_directory_by_path(input, context.allocator)
                if error != nil {
                    fmt.printfln("ERROR: failed to read directory '%v' when checking for changes", input, error)
                    break search
                }
            } else {
                file, stat_error := os2.stat(input, context.allocator)
                files = { file }
                if stat_error != nil {
                    fmt.printfln("ERROR: failed to read file '%v' when checking for changes", input, error)
                    break search
                }
            }
            
            for file in files {
                if extension == "" || strings.ends_with(file.name, extension) {
                    if time.diff(file.modification_time, output_info.modification_time) < 0 {
                        result = true
                        break search
                    }
                }
            }
        }
    }
    
    return result
}

remove_if_exists :: proc(path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc(pattern: string) {
    for file in all_like(pattern) {
        os.remove(file)
    }
}

all_like :: proc(pattern: string, allocator := context.temp_allocator) -> (result: [] string) {
    files: [dynamic] string
    files.allocator = allocator
    
    find_data := win.WIN32_FIND_DATAW{}
    handle := win.FindFirstFileW(win.utf8_to_wstring(pattern), &find_data)
    if handle == win.INVALID_HANDLE_VALUE do return files[:]
    defer win.FindClose(handle)
    
    for {
        file_name, err := win.utf16_to_utf8(find_data.cFileName[:])
        assert(err == nil)
        file_path := fmt.tprintf(`.\%v`, file_name)
        append(&files, file_path)
        
        if !win.FindNextFileW(handle, &find_data){
            break 
        }
    }
    
    return files[:]
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

run_command :: proc (cmd: ^Cmd, or_exit := true, keep := false, stdout: ^string = nil, stderr: ^string = nil, async: ^Procs = nil) -> (success: bool) {
    fmt.printfln(`CMD: %v`, strings.join(cmd[:], ` `))
    
    process_description := os2.Process_Desc { command = cmd[:] }
    process: os2.Process
    state:   os2.Process_State
	output:  []byte
	error:   []byte
    err2:    os2.Error
    if async == nil {
        state, output, error, err2 = os2.process_exec(process_description, context.allocator)
    } else {
        process, err2 = os2.process_start(process_description)
        append(async, process)
    }
    
    if err2 != nil {
        fmt.printfln("ERROR: Failed to run command : %v", err2)
        return false
    }
    
    if async == nil {
        if output != nil {
            if stdout != nil do stdout ^= string(output)
            else do fmt.println(string(output))
        }
        
        if error != nil {
            if stderr != nil do stderr ^= string(error)
            else do fmt.println(string(error))
            
            if or_exit do os.exit(state.exit_code)
        }
        
        if or_exit && !state.success do os.exit(state.exit_code)
        
        success = state.success
    } else {
        success = true
    }
    
    if !keep do clear(cmd)
    
    return success
}

kill :: proc (pid: u32) {
    handle := win.OpenProcess(win.PROCESS_TERMINATE, false, pid)
    if handle != nil {
        win.TerminateProcess(handle, 0)
        win.CloseHandle(handle)
    }
}

make_directory_if_not_exists :: proc(path: string) -> (result: b32) {
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

random_number :: proc() -> (result: u8) {
    return cast(u8) intrinsics.read_cycle_counter()
}