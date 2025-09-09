#+vet !unused-procedures
#+no-instrumentation
package main

import "core:prof/spall"
import "core:time"

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer
@(private="file", thread_local) backing_buffer: [] u8

////////////////////////////////////////////////

/*
@(instrumentation_enter)
spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc := #caller_location) {
	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
}

@(instrumentation_exit)
spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc := #caller_location) {
	spall._buffer_end(&spall_ctx, &spall_buffer)
}
*/

////////////////////////////////////////////////

@(deferred_none = delete_spall)
init_spall :: proc (location := #caller_location) {
    spall_ctx = spall.context_create("trace.spall", 10 * time.Millisecond)
    make(&backing_buffer, 10 * Megabyte)
    spall_buffer = spall.buffer_create(backing_buffer, auto_cast context.user_index)
}
@(deferred_none = delete_spall_thread)
init_spall_thread :: proc (location := #caller_location) {
    make(&backing_buffer, 10 * Megabyte)
    spall_buffer = spall.buffer_create(backing_buffer, auto_cast context.user_index)
    spall_begin(location.procedure)
}

delete_spall :: proc () {
    defer spall.context_destroy(&spall_ctx)
    defer delete(backing_buffer)
    defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
}
delete_spall_thread :: proc () {
    defer delete(backing_buffer)
    defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
    defer spall_end()
}

////////////////////////////////////////////////

@(deferred_none = spall_end)
spall_proc :: proc (name: string = "", location := #caller_location) {
    spall_begin(name == "" ? location.procedure : name, location)
}

@(deferred_none = spall_end)
spall_scope :: proc (name: string, location := #caller_location) {
    spall_begin(name, location)
}

spall_begin :: proc (name: string, location := #caller_location) {
	spall._buffer_begin(&spall_ctx, &spall_buffer, name, "", location)
}

spall_end :: proc () {
	spall._buffer_end(&spall_ctx, &spall_buffer)
}

spall_flush :: proc () {
    spall.buffer_flush(&spall_ctx, &spall_buffer)
}
