#+vet !unused-procedures
// #+no-instrumentation
package main

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:fmt"

// @volatile This breaks if in the midst of a print we start another print on the same thread. we could use a cursor to know from where onwards we can use the buffer.
ConsoleBufferSize :: #config(ConsoleBufferSize, 128 * Megabyte)
@(thread_local) console_buffer: [ConsoleBufferSize] u8

////////////////////////////////////////////////

@(printlike)
print_to_console :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, console := os.stdout) {
    result := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    os.write(console, transmute([]u8) result)
}

@(printlike)
print_to_allocator :: proc (allocator: runtime.Allocator, format: string, args: ..any, flags: Format_Context_Flags = {}) -> (result: string) {
    s := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    buffer := make([]u8, len(s), allocator)
    copy(buffer, s)
    result = transmute(string) buffer
    return result
}

////////////////////////////////////////////////

              print :: proc { print_to_console, print_to_allocator }
@(printlike) tprint :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.temp_allocator) -> (result: string) { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }
@(printlike) sprint :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.allocator)      -> (result: string) { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }

////////////////////////////////////////////////

/* @todo(viktor): 
    - make ryu able to print fixed precision f32s
    - store defaults for floats, ints, structs, arrays and pointers explicitly
    - push context and defered pop context? to override defaults
*/

////////////////////////////////////////////////

Default_Views:      map[typeid] View_Proc
View_Proc        :: proc (value: pmm) -> View_Proc_Result
View_Proc_Result :: union{ View, Temp_Views, any }

////////////////////////////////////////////////

Temp_Views :: distinct [] View

View :: struct {
    value: struct #raw_union {
        byte:  u8,
        word:  u16,
        dword: u32,
        qword: u64,
        
        half_float:   f16,
        single_float: f32,
        double_float: f64,
        
        bytes: []u8,
    },
    size: u8,
    kind: View_Kind,
    
    settings: bit_set[ enum {Width, Basis, Precision}],
    // General
    // @todo(viktor): width only makes sense for single line values of fixed size, so maybe make it exclusive with multiline
    width:          u16,
    pad_right_side: b8,
    // @todo(viktor): string format, escaped, (as hex)
    
    // @todo(viktor): copy over flags from context and let a format element override the context for its data
    
    // Numbers
    flags:         Format_Number_Flags,
    positive_sign: Format_Number_Sign,
    
    // Integer
    basis: u8,
    
    // Float
    precision:  u8,
    float_kind: Format_Float_Kind,
    /*
    
    // Struct
    draw_type_name: b32,
    separator_between_name_and_value: string, // " = "
    
    use_long_form_if_more_than_this_many_members: u8, // 5
    short_form_separator_between_fields: string, // ", "
    long_form_separator_between_fields: string, // "; "
    
    struct_begin_string: string, // "{"
    struct_end_string:   string, // "}"
    
    indentation_width: i32, // 4
    use_newlines_if_long_form: b32,
    
    // Array
    array_begin_string: string, // "{"
    array_end_string:   string, // "}"
    array_separator:    string, // ", "
    
    printing_stopped_early_string: string, // "..."
    draw_separator_after_last_element: bool, // false;
    stop_printing_after_this_many_elements: i32, // 100;
    // @todo(viktor): multiline?
    
    // @todo(viktor): view_pointer is the only place where ctx.max_depth is relevant, so maybe just say, 
    // follow_pointers_until_depth_reaches 
    // or for i.e. double-linked-lists
    // follow_unique/unseen_pointers_until_depth_reached
    */
}

View_Kind :: enum u8 {
    Bytes,
    
    String, Character, 
    
    UnsignedInteger, SignedInteger, Float,
    
    Indent, Outdent, Linebreak,
}

Format_Number_Sign   :: enum u8 { Never, Plus, Space }
Format_Float_Kind    :: enum u8 { Shortest, MaximumPercision, Scientific }
Format_Number_Flags  :: bit_set[ enum u8 { LeadingZero, PrependBaseSpecifier, Uppercase }; u8 ]
Format_Context_Flags :: bit_set[ enum u8 { PrependTypes, Multiline, AppendZero }; u8 ]

////////////////////////////////////////////////
/*
{
    {
        default_format_int = {
            formatter = {(zero-initialized Any)};
            base = 10;
        
            minimum_digits = 1;
            padding = 48;
            digits_per_comma = 0;
            comma_string = "";
        };
        
        default_format_float = {
            {(zero-initialized Any)}, 
            -1, 
            -1, 
            YES, 
            DECIMAL
        };
        
        default_format_absolute_pointer = {
            formatter = {(zero-initialized Any)};
        
            base = 16;
            minimum_digits = 1;
            padding = 48;
            digits_per_comma = 4;
            comma_string = "_";
        };
        
        indentation_depth = 2;
        log_runtime_errors = true;
    }, 
}
*/
////////////////////////////////////////////////

// @todo(viktor): this could also take an enum which is then interpreted as a float
// @todo(viktor): this could also take complex numbers and quaternions
view_float :: proc (
    value: $F, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
    precision: Maybe(u8) = nil, kind: Format_Float_Kind = .Shortest
) -> (result: View) 
where intrinsics.type_is_float(F) {
         when F == f16 do result.value.half_float   = value
    else when F == f32 do result.value.single_float = value
    else when F == f64 do result.value.double_float = value
    else do #panic("not a supported float")
    
    result.kind  = .Float
    result.size = size_of(value)
    
    view_set_general(&result, width, pad_right_side)
    view_set_number(&result, flags, positive_sign)
    
    if precision, ok := precision.?; ok {
        result.settings += { .Precision }
        result.precision = precision
    }
    result.float_kind = kind
    
    return result
}

view_integer :: proc (
    value: $I, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
    basis: Maybe(u8) = nil,
) -> (result: View) 
where intrinsics.type_is_integer(I) {
    result.size = size_of(value)
    
           when I == u8  { result.kind = .UnsignedInteger; result.value.byte = value
    } else when I == u16 { result.kind = .UnsignedInteger; result.value.word = value
    } else when I == u32 { result.kind = .UnsignedInteger; result.value.dword = value
    } else when I == u64 { result.kind = .UnsignedInteger; result.value.qword = value
    } else when I == i8  { result.kind = .SignedInteger; result.value.byte  = transmute(u8) value
    } else when I == i16 { result.kind = .SignedInteger; result.value.word  = transmute(u16) value
    } else when I == i32 { result.kind = .SignedInteger; result.value.dword = transmute(u32) value
    } else when I == i64 { result.kind = .SignedInteger; result.value.qword = transmute(u64) value
    
    } else when I == int     && size_of(int)     == 4 { result.kind = .SignedInteger;   result.value.dword = transmute(u32) value
    } else when I == int     && size_of(int)     == 8 { result.kind = .SignedInteger;   result.value.qword = transmute(u64) value
    } else when I == uint    && size_of(uint)    == 4 { result.kind = .UnsignedInteger; result.value.dword = transmute(u32) value
    } else when I == uint    && size_of(uint)    == 8 { result.kind = .UnsignedInteger; result.value.qword = transmute(u64) value
    } else when I == uintptr && size_of(uintptr) == 4 { result.kind = .UnsignedInteger; result.value.dword = transmute(u32) value
    } else when I == uintptr && size_of(uintptr) == 8 { result.kind = .UnsignedInteger; result.value.qword = transmute(u64) value
    } else {
        core := runtime.type_info_core(type_info_of(I))
        switch core.id {
          case u8:  result = view_integer(cast(u8)  value, width, pad_right_side, flags, positive_sign, basis)
          case u16: result = view_integer(cast(u16) value, width, pad_right_side, flags, positive_sign, basis)
          case u32: result = view_integer(cast(u32) value, width, pad_right_side, flags, positive_sign, basis)
          case u64: result = view_integer(cast(u64) value, width, pad_right_side, flags, positive_sign, basis)
          case i8:  result = view_integer(cast(i8)  value, width, pad_right_side, flags, positive_sign, basis)
          case i16: result = view_integer(cast(i16) value, width, pad_right_side, flags, positive_sign, basis)
          case i32: result = view_integer(cast(i32) value, width, pad_right_side, flags, positive_sign, basis)
          case i64: result = view_integer(cast(i64) value, width, pad_right_side, flags, positive_sign, basis)
          case: unreachable()
        }
        return result
    }
    
    view_set_general(&result, width, pad_right_side)
    view_set_number(&result, flags, positive_sign)
    
    if basis, ok := basis.?; ok {
        result.settings += { .Basis }
        result.basis = basis
    }
    
    return result
}

view_bin :: proc (
    value: $I, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
) -> (result: View) {
    result = view_integer(value, width, pad_right_side, flags + { .PrependBaseSpecifier }, positive_sign, basis = 2)
    return result
}

view_oct :: proc (
    value: $I, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
) -> (result: View) {
    result = view_integer(value, width, pad_right_side, flags + { .PrependBaseSpecifier }, positive_sign, basis = 8)
    return result
}

view_dec :: proc (
    value: $I, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
) -> (result: View) {
    result = view_integer(value, width, pad_right_side, flags + { .PrependBaseSpecifier }, positive_sign, basis = 10)
    return result
}

view_hex :: proc (
    value: $I, 
    width: Maybe(u16) = nil, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
) -> (result: View) {
    result = view_integer(value, width, pad_right_side, flags + { .PrependBaseSpecifier }, positive_sign, basis = 16)
    return result
}

////////////////////////////////////////////////

view_character :: proc(value: u8) -> (result: View) {
    result = {
        kind  = .Character,
        value = { byte = value },
    }
    return result
}

// @todo(viktor): string view options
view_string :: proc(value: string) -> (result: View) {
    result = {
        kind  = .String, 
        value = { bytes = transmute([]u8) value },
    }
    return result
}

////////////////////////////////////////////////
// @todo(viktor): implement all cases
// @todo(viktor): use temp views here where needed

/* 
A list of currently-supported views are below:
 - list? for pointer graphs like linked lists

 - `raw(expr)`: Ignores all views used in `expr`, including those automatically applied by type views.
*/

view_raw :: proc (value: $T) -> (result: View) {}

// - `sequence(expr)`: Interprets `expr` as an integer, encoding how many sub-expressions `expr` should expand to produce. This can be used in combination with the `table` view to easily generate tables, indexing amongst many arrays.
view_sequence :: proc (value: $T) { unimplemented() }
// - `rows(expr, ...)`: Interpreting all post-`expr` arguments as member names, only expands to show those members of `expr`.
view_rows :: proc (value: $T) { unimplemented() }
// - `omit(expr, ...)`: Interpreting all post-`expr` arguments as member names, expands to show all members of `expr`, except those with matching names.
view_omit :: proc (value: $T) { unimplemented() }

view_array :: proc (value: ^$T, count: $N) -> (result: []T) {
    return (cast([^]T) value)[:count]
}

// - `table/columns(expr, ...)`: Expresses that `expr` should be expanded normally, but interprets all post-`expr` arguments as expressions which should be used to form cells for rows which are generated by this expression's expansions. This replaces the normal cells which are generated for an expansion in a Watch table.
view_table :: view_columns
view_columns :: proc (value: $T) { unimplemented() }

////////////////////////////////////////////////

view_set_data :: proc(view: ^View, value: $T, kind: View_Kind) {
    view.data = value
    view.kind = kind
}

view_set_number :: proc (view: ^View, flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never) {
    view.flags = flags
    view.positive_sign = positive_sign
}

view_set_general :: proc (view: ^View, width: Maybe(u16) = nil, pad_right_side: b8 = false) {
    if width, ok := width.?; ok {
        view.settings += { .Width }
        view.width = width
    }
    view.pad_right_side = pad_right_side
}

////////////////////////////////////////////////

Format_Context :: struct {
    dest:  String_Builder,
    
    max_depth: u32,
    indentation: string,
    indentation_depth: u32,
    flags: Format_Context_Flags,
}

////////////////////////////////////////////////

@(private="file") temp_buffer:            [1024] u8
@(private="file") temp_view_buffer:       [1024] View
@(private="file") temp_view_inside_block: b32
@(private="file") temp_view_start_index:  u32
@(private="file") temp_view_next_index:   u32


begin_temp_views :: proc (width: Maybe(u16) = nil) {
    assert(!temp_view_inside_block)
    temp_view_inside_block = true
    // @incomplete what about width for TempViews, handle in format_string
    temp_view_start_index = temp_view_next_index
}

append_temp_view :: proc (view: View) {
    assert(temp_view_inside_block)

    temp_view_buffer[temp_view_next_index] = view
    temp_view_next_index += 1
    assert(temp_view_next_index < len(temp_view_buffer))
}

end_temp_views :: proc () -> (result: Temp_Views) {
    assert(temp_view_inside_block)
    temp_view_inside_block = false
    
    result = cast(Temp_Views) temp_view_buffer[temp_view_start_index : temp_view_next_index]
    return result
}

////////////////////////////////////////////////

@(printlike)
format_cstring :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags {}) -> (result: cstring) {
    s := format_string(buffer, format, ..args, flags = flags + { .AppendZero })
    result = cast(cstring) raw_data(s)
    return result
}

@(printlike)
format_string :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags{}) -> (result: string) {
    ctx := Format_Context { 
        dest  = { data = buffer },
        flags = flags,
        
        indentation = "  ",
        max_depth = 8,
    }
    
    // :PrintlikeChecking @volatile 
    // the loop structure is copied in the metaprogram to check the arg count, any changes here need to be propagated to there
    arg_index: u32
    start_of_text: int
    for index: int; index < len(format); index += 1 {
        if format[index] == '%' {
            part := format[start_of_text:index]
            if part != "" {
                format_view(&ctx, view_string(part))
            }
            start_of_text = index+1
            
            if index+1 < len(format) && format[index+1] == '%' {
                index += 1
                // @note(viktor): start_of_text now points at the percent sign and will append it next time saving processing one view
            } else {
                arg := args[arg_index]
                arg_index += 1
                
                // @incomplete Would be ever want to display a raw View? if so put in a flag to make it use the normal path
                switch format in arg {
                  case Temp_Views: for view in format do format_view(&ctx, view)
                  case View:      format_view(&ctx, format)
                  case:           format_any(&ctx, arg)
                }
            }
        }
    }
    
    end := format[start_of_text:]
    format_view(&ctx, view_string(end))
    
    assert(arg_index == auto_cast len(args))
    
    if .AppendZero in flags {
        format_view(&ctx, view_character(0))
    }
    
    temp_view_next_index = 0
    return to_string(ctx.dest)
}

format_view :: proc (ctx: ^Format_Context, view: View) {
    view := view
    temp := String_Builder { data = temp_buffer[:] }
    
    switch view.kind {
      case .Indent:
        assert(.Multiline in ctx.flags)
        ctx.indentation_depth += 1
        
      case .Outdent:
        assert(.Multiline in ctx.flags)
        ctx.indentation_depth -= 1
        
      case .Linebreak:
        assert(.Multiline in ctx.flags)
        append(&ctx.dest, "\n")
        for _ in 0..<ctx.indentation_depth do append(&ctx.dest, ctx.indentation)
        
        
      case .Bytes:
        unimplemented()
        
      case .String:    append(&temp, view.value.bytes)
      case .Character: append(&temp, view.value.byte)
        
      case .UnsignedInteger:
        value: u64 = ---
        switch view.size {
          case 1: value = cast(u64) view.value.byte
          case 2: value = cast(u64) view.value.word
          case 4: value = cast(u64) view.value.dword
          case 8: value =           view.value.qword
          case: unreachable()
        }
        format_unsigned_integer(&temp, value, &view)
        
      case .SignedInteger:
        value: i64 = ---
        switch view.size {
          case 1: value = cast(i64) (cast(^i8)  &view.value.byte)^
          case 2: value = cast(i64) (cast(^i16) &view.value.word)^
          case 4: value = cast(i64) (cast(^i32) &view.value.dword)^
          case 8: value =           (cast(^i64) &view.value.qword)^
          case: unreachable()
        }
        format_signed_integer(&temp, value, &view)
        
      case .Float:
        // @todo(viktor): endianess relevant?
        // This is wrong when we use the format_integer subroutine view.flags += {.LeadingZero}
        switch view.size {
          case 2: format_float_with_ryu(&temp, view.value.half_float,   &view)
          case 4: format_float_with_ryu(&temp, view.value.single_float, &view)
          case 8: format_float_with_ryu(&temp, view.value.double_float, &view)
          case: unreachable()
        }
        // @todo(viktor): 
        // NaN Inf+- 
        // base specifier
        // scientific and max precision
        // as hexadecimal 0h
    }
    
    padding := max(0, cast(i32) view.width - cast(i32) temp.count)
    if       !view.pad_right_side && view.width != 0 do for _ in 0..<padding do append(&ctx.dest, ' ')
    defer if  view.pad_right_side && view.width != 0 do for _ in 0..<padding do append(&ctx.dest, ' ')
    
    append(&ctx.dest, to_string(temp))
}

////////////////////////////////////////////////

format_any :: proc (ctx: ^Format_Context, arg: any) {
    if ctx.max_depth <= 0 do return
    
    switch value in arg {
      case b8:   format_view(ctx, view_string(value ? "true" : "false"))
      case b16:  format_view(ctx, view_string(value ? "true" : "false"))
      case b32:  format_view(ctx, view_string(value ? "true" : "false"))
      case b64:  format_view(ctx, view_string(value ? "true" : "false"))
      case bool: format_view(ctx, view_string(value ? "true" : "false"))
      
      case string:  format_view(ctx, view_string(value))
      case cstring: format_view(ctx, view_string(string(value)))
      
      case f16: format_view(ctx, view_float(value))
      case f32: format_view(ctx, view_float(value))
      case f64: format_view(ctx, view_float(value))
      
      // @todo(viktor): rune
      case u8:      format_view(ctx, view_integer(value))
      case u16:     format_view(ctx, view_integer(value))
      case u32:     format_view(ctx, view_integer(value))
      case u64:     format_view(ctx, view_integer(value))
      case uint:    format_view(ctx, view_integer(value))
      case uintptr: format_view(ctx, view_integer(value))
      
      case i8:  format_view(ctx, view_integer(value))
      case i16: format_view(ctx, view_integer(value))
      case i32: format_view(ctx, view_integer(value))
      case i64: format_view(ctx, view_integer(value))
      case int: format_view(ctx, view_integer(value))
      
      case any:    format_any(ctx, value)
      case nil:    format_pointer(ctx, nil)
      case rawptr: format_pointer(ctx, value)
      
      case:
        raw := transmute(RawAny) value
        type_info := type_info_of(raw.id)
        
        switch variant in type_info.variant {
          case runtime.Type_Info_Any,
               runtime.Type_Info_Boolean, 
               runtime.Type_Info_Integer, 
               runtime.Type_Info_String,
               runtime.Type_Info_Float:
            unreachable()
            
          case runtime.Type_Info_Pointer:
            data := (cast(^pmm) raw.data)^
            format_pointer(ctx, data, variant.elem)
            
          case runtime.Type_Info_Multi_Pointer:
            data := (cast(^pmm) raw.data)^
            format_optional_type(ctx, raw.id)
            format_pointer(ctx, data, variant.elem)
          
          case runtime.Type_Info_Named:
            // @important @todo(viktor): If the struct is an alias like v4 :: [4]f32 we currently print both types. but we should only print the alias
            if default, ok := Default_Views[raw.id]; ok {
                // @copypasta from format_string loop
                switch format in default(value.data) {
                  case Temp_Views: for view in format do format_view(ctx, view)
                  case View:      format_view(ctx, format)
                  case any:       format_any(ctx, format)
                }
            } else {
                format_view(ctx, view_string(variant.name))
                format_view(ctx, view_character(' '))
                format_any(ctx, any{data = raw.data, id = variant.base.id})
            }
            
          case runtime.Type_Info_Struct:
            format_struct(ctx, raw, variant)
            
          case runtime.Type_Info_Union:
            format_union(ctx, raw.id, raw.data, variant)
            
          case runtime.Type_Info_Dynamic_Array:
            slice := cast(^RawSlice) raw.data
            raw_slice := RawAny{slice.data, raw.id}
            format_array(ctx, raw_slice, variant.elem, slice.len)
            
          case runtime.Type_Info_Slice:
            slice := cast(^RawSlice) raw.data
            raw_slice := RawAny{slice.data, raw.id}
            format_array(ctx, raw_slice, variant.elem, slice.len)
            
          case runtime.Type_Info_Array:
            format_array(ctx, raw, variant.elem, variant.count)
            
          case runtime.Type_Info_Complex:
            format_optional_type(ctx, raw.id)
            switch complex in value {
              case complex32: 
                format_view(ctx, view_float(real(complex)))
                format_view(ctx, view_float(imag(complex), positive_sign = .Plus))
                format_view(ctx, view_character('i')) 
              case complex64: 
                format_view(ctx, view_float(real(complex)))
                format_view(ctx, view_float(imag(complex), positive_sign = .Plus))
                format_view(ctx, view_character('i')) 
              case complex128:
                format_view(ctx, view_float(real(complex)))
                format_view(ctx, view_float(imag(complex), positive_sign = .Plus))
                format_view(ctx, view_character('i')) 
            }
            
          case runtime.Type_Info_Quaternion:
            format_optional_type(ctx, raw.id)
            switch quaternion in value {
                case quaternion64: 
                  format_view(ctx, view_float(real(quaternion)))
                  format_view(ctx, view_float(imag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('i')) 
                  format_view(ctx, view_float(jmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('j')) 
                  format_view(ctx, view_float(kmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('k')) 
                case quaternion128: 
                  format_view(ctx, view_float(real(quaternion)))
                  format_view(ctx, view_float(imag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('i')) 
                  format_view(ctx, view_float(jmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('j')) 
                  format_view(ctx, view_float(kmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('k')) 
                case quaternion256:
                  format_view(ctx, view_float(real(quaternion)))
                  format_view(ctx, view_float(imag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('i')) 
                  format_view(ctx, view_float(jmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('j')) 
                  format_view(ctx, view_float(kmag(quaternion), positive_sign = .Plus))
                  format_view(ctx, view_character('k')) 
              }
            
          case runtime.Type_Info_Matrix:
            format_matrix(ctx, raw.id, raw.data, variant.elem, variant.column_count, variant.row_count, variant.layout == .Row_Major)

          case runtime.Type_Info_Type_Id:
            format_type(ctx, type_info)
            
          case runtime.Type_Info_Rune:
            unimplemented("Unimplemented: rune")
            
          case runtime.Type_Info_Enum:
            format_view(ctx, view_string(fmt.tprint(value)))
          /* 
            . enumerated array   [key0 = elem0, key1 = elem1, key2 = elem2, ...]
            . maps:              map[key0 = value0, key1 = value1, ...]
            . bit sets           {key0 = elem0, key1 = elem1, ...}
           */  
          case runtime.Type_Info_Enumerated_Array:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Bit_Set:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Bit_Field:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Map:
            format_view(ctx, view_string(fmt.tprint(value)))
            
          case runtime.Type_Info_Parameters:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Procedure:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Simd_Vector:
            format_view(ctx, view_string(fmt.tprint(value)))
          case runtime.Type_Info_Soa_Pointer:
            format_view(ctx, view_string(fmt.tprint(value)))
          
          case: 
            format_view(ctx, view_string(fmt.tprint(value)))
            unimplemented("This value is not handled yet")
        }
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

format_multiline_formatting :: proc (ctx: ^Format_Context, kind: View_Kind) {
    if ctx.max_depth <= 0 do return
    
    if .Multiline in ctx.flags {
        format_view(ctx, View { kind = kind })
    }
}

format_optional_type :: proc (ctx: ^Format_Context, type: typeid) {
    if ctx.max_depth <= 0 do return
    
    if .PrependTypes in ctx.flags {
        format_type(ctx, type_info_of(type))
        format_view(ctx, view_character(' ') )
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

DigitsLowercase := "0123456789abcdefghijklmnopqrstuvwxyz"
DigitsUppercase := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

format_float_with_ryu :: proc (dest: ^String_Builder, float: $F, view: ^View) {
    precision: u32 = 6
    if .Precision in view.settings do precision = cast(u32) view.precision
    
    buffer := rest(dest^)
    when size_of(F) == 8 {
        result := d2fixed_buffered(float, precision, buffer)
        dest.count += auto_cast len(result)
    } else when size_of(F) == 4 {
        result := f2s_buffered(float, buffer)
        dest.count += auto_cast len(result)
    } else when size_of(F) == 2 {
        unimplemented()
    } else do #panic("convert the general algorithm from ryu you laze bum")
    
    if .Uppercase in view.flags {
        for r, i in string(buffer) {
            if r >= 'a' && r <= 'z' {
                buffer[i] = cast(u8) ('A' + (r-'a'))
            }
        }
    }
}

format_float_badly :: proc (dest: ^String_Builder, float: $F, view: ^View) {
    fraction, integer := fractional(float)
    
    format_signed_integer(dest, cast(i64) integer, view)
    
    precision: u8 = 6
    if .Precision in view.settings do precision = view.precision
    
    if fraction != 0 && precision != 0 {
        append(dest, '.')
        
        digits := .Uppercase in view.flags ? DigitsUppercase : DigitsLowercase
        
        val: i32
        for _ in 0..<precision {
            fraction, val = fractional(fraction * 10)
            if val >= 0 && val < auto_cast len(digits) {
                append(dest, digits[val])
            } else { /* ??? */ }
        }
    }
}

format_signed_integer :: proc (dest: ^String_Builder, integer: i64, view: ^View) {
    if integer < 0 {
        append(dest, '-')
    } else if view.positive_sign == .Plus {
        append(dest, '+')
    } else if view.positive_sign == .Space {
        append(dest, ' ')
    } else {
        // @note(viktor): nothing
    }
    
    format_unsigned_integer(dest, cast(u64) abs(integer), view)
}

// @todo(viktor): if we specify a width and .LeadingZero, we should limit those zeros to the width i guess
// example: integer = 2 width = 2 -> "02" and not "00000002"
format_unsigned_integer :: proc (dest: ^String_Builder, integer: u64, view: ^View) {
    digits := .Uppercase in view.flags ? DigitsUppercase : DigitsLowercase
    
    basis: u64 = 10
    if .Basis in view.settings do basis = cast(u64) view.basis
    assert(view.basis < auto_cast len(digits))
    
    integer := integer
    
    if .PrependBaseSpecifier in view.flags {
        switch basis {
          case 2:  append(dest, "0b")
          case 8:  append(dest, "0o")
          case 12: append(dest, "0z")
          case 16: append(dest, "0x")
          case: // @note(viktor): base 10 and any other basis are ignored
        }
    }
    
    show_leading_zeros := .LeadingZero in view.flags
    max_integer: u64
    if show_leading_zeros {
        for _ in 0..<view.size do max_integer = (max_integer<<8) | 0xFF
    } else {
        max_integer = integer
    }
    
    power: u64 = 1
    for power < max_integer {
        power *= basis
        if max_integer / power < basis do break
    }
    
    for ; power > 0; power /= basis {
        div := integer / power
        integer -= div * power
        
        if show_leading_zeros || div != 0 || integer == 0 {
            show_leading_zeros = true
            append(dest, digits[div])
        }
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

// @todo(viktor): make pointer into view_pointer
//  - `no_addr(expr)`: Disables explicit address visualization with pointer evaluations in `expr`.

format_pointer :: proc (ctx: ^Format_Context, data: pmm, target_type: ^runtime.Type_Info = nil) {
    if ctx.max_depth <= 0 do return
    
    if target_type != nil {
        format_view(ctx, view_character('&'))
    }
    
    if target_type == nil || data == nil {
        value := data
        if value == nil {
            format_view(ctx, view_string("nil") )
        } else {
            format_view(ctx, view_integer(cast(umm) value, basis = 16, flags = { .PrependBaseSpecifier, .Uppercase }))
        }
    } else {
        pointed_any := any { data, target_type.id }
        format_any(ctx, pointed_any)
    }
}

format_array :: proc (ctx: ^Format_Context, raw: RawAny, type: ^runtime.Type_Info, count: int) {
    if ctx.max_depth <= 0 do return
    
    format_optional_type(ctx, raw.id)
    
    format_view(ctx, view_character('{'))
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_view(ctx, view_character('}'))
    }
    
    for index in 0..< count {
        if index != 0 do format_view(ctx, view_string(", "))
        format_multiline_formatting(ctx, .Linebreak)
        
        offset := cast(umm) (index * type.size)
        
        index_ptr := cast(pmm) (cast(umm) raw.data + offset)
        field := any{ index_ptr, type.id }
        format_any(ctx, field)
    }
}

format_struct :: proc (ctx: ^Format_Context, value: RawAny, variant: runtime.Type_Info_Struct) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
        
    format_optional_type(ctx, value.id)
    
    format_view(ctx, view_character('{'))
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_view(ctx, view_character('}'))
    }
    
    for index in 0..< variant.field_count {
        if index != 0 do format_view(ctx, view_string(", "))
        format_multiline_formatting(ctx, .Linebreak)
        
        format_view(ctx, view_string(variant.names[index]))
        format_view(ctx, view_string(" = "))
        field_offset := variant.offsets[index]
        field_type   := variant.types[index]
        
        field_ptr := cast(pmm) (cast(umm) value.data + field_offset)
        field := any{field_ptr, field_type.id}
        format_any(ctx, field)
    }
}

format_union :: proc (ctx: ^Format_Context, union_type: typeid, data: pmm, variant: runtime.Type_Info_Union) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    tag_ptr := cast(pmm) (cast(umm) data + variant.tag_offset)
    tag: i64 = -1
    switch variant.tag_type.id {
      case u8:   tag = cast(i64) (cast(^u8)  tag_ptr)^
      case u16:  tag = cast(i64) (cast(^u16) tag_ptr)^
      case u32:  tag = cast(i64) (cast(^u32) tag_ptr)^
      case u64:  tag = cast(i64) (cast(^u64) tag_ptr)^
      case i8:   tag = cast(i64) (cast(^i8)  tag_ptr)^
      case i16:  tag = cast(i64) (cast(^i16) tag_ptr)^
      case i32:  tag = cast(i64) (cast(^i32) tag_ptr)^
      case i64:  tag =           (cast(^i64) tag_ptr)^
      case: panic("Invalid union tag type")
    }

    format_optional_type(ctx, union_type)
    
    if data == nil || !variant.no_nil && tag == 0 {
        format_view(ctx, view_string("nil"))
    } else {
        id := variant.variants[variant.no_nil ? tag : (tag-1)].id
        field := any{ data, id }
        format_any(ctx, field)
    }
}

format_matrix :: proc (ctx: ^Format_Context, matrix_type: typeid, data: pmm, type: ^runtime.Type_Info, #any_int column_count, row_count: umm, is_row_major: b32) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    format_optional_type(ctx, matrix_type)
    
    format_view(ctx, view_character('{'))
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_view(ctx, view_character('}'))
    }
    
    step   := cast(umm) type.size
    stride := step * (is_row_major ? column_count : row_count)
    major  := is_row_major ? row_count : column_count
    minor  := is_row_major ? column_count : row_count
    
    at   := cast(umm) data
    size := stride * major
    end  := at + size
    for _ in 0..<major {
        defer at += stride
        
        format_multiline_formatting(ctx, .Linebreak)
        
        elem_at := at
        for min in 0..<minor {
            defer elem_at += step
            
            if min != 0 do format_view(ctx, view_string(", "))
            format_any(ctx, any{cast(pmm) elem_at, type.id})
        }
        
        format_view(ctx, view_string(", "))
    }
    assert(at == end)
}


format_type :: proc (ctx: ^Format_Context, type_info: ^runtime.Type_Info) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    format_endianess :: proc (ctx: ^Format_Context, kind: runtime.Platform_Endianness) {
        switch kind {
          case .Platform: /* nothing */
          case .Little:   format_view(ctx, view_string("le"))
          case .Big:      format_view(ctx, view_string("be"))
        }
    }
    
    if type_info == nil {
        format_view(ctx, view_string("nil"))
    } else {
        switch info in type_info.variant {
          case runtime.Type_Info_Integer:
            if type_info.id == int {
                format_view(ctx, view_string("int"))
            } else if type_info.id == uint {
                format_view(ctx, view_string("uint"))
            } else if type_info.id == uintptr {
                format_view(ctx, view_string("uintptr"))
            } else {
                format_view(ctx, view_character(info.signed ? 'i' : 'u'))
                format_view(ctx, view_integer(type_info.size * 8))
                format_endianess(ctx, info.endianness)
            }
            
          case runtime.Type_Info_Float:
            format_view(ctx, view_character('f'))
            format_view(ctx, view_integer(type_info.size * 8))
            format_endianess(ctx, info.endianness)
            
          case runtime.Type_Info_Complex:
            format_view(ctx, view_string("complex"))
            format_view(ctx, view_integer(type_info.size * 8))
            
          case runtime.Type_Info_Quaternion:
            format_view(ctx, view_string("quaternion"))
            format_view(ctx, view_integer(type_info.size * 8))
            
          case runtime.Type_Info_Procedure:
            format_view(ctx, view_string("proc"))
            // @todo(viktor):  format_view(ctx, view_string(info.convention))
            if info.params == nil do format_view(ctx, view_string("()"))
            else {
                format_view(ctx, view_character('('))
                ps := info.params.variant.(runtime.Type_Info_Parameters)
                for param, i in ps.types {
                    if i != 0 do format_view(ctx, view_string(", "))
                    format_type(ctx, param)
                }
                format_view(ctx, view_character(')'))
            }
            if info.results != nil {
                format_view(ctx, view_string(" -> "))
                format_type(ctx, info.results)
            }
            
          case runtime.Type_Info_Parameters:
            count := len(info.types)
            if       count != 0 do format_view(ctx, view_character('('))
            defer if count != 0 do format_view(ctx, view_character(')'))
            
            for i in 0..<count {
                if i != 0 do format_view(ctx, view_string(", "))
                if i < len(info.names) {
                    format_view(ctx, view_string(info.names[i]))
                    format_view(ctx, view_string(": "))
                }
                format_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Boolean:
            if type_info.id == bool {
                format_view(ctx, view_string("bool"))
            } else {
                format_view(ctx, view_character('b'))
                format_view(ctx, view_integer(type_info.size * 8))
            }
              
          case runtime.Type_Info_Named:   format_view(ctx, view_string(info.name))
          case runtime.Type_Info_String:  format_view(ctx, view_string(info.is_cstring ? "cstring" : "string"))
          case runtime.Type_Info_Any:     format_view(ctx, view_string("any"))
          case runtime.Type_Info_Type_Id: format_view(ctx, view_string("typeid"))
          case runtime.Type_Info_Rune:    format_view(ctx, view_string("rune"))
          
          case runtime.Type_Info_Pointer: 
            if info.elem == nil {
                format_view(ctx, view_string("rawptr"))
            } else {
                format_view(ctx, view_character('^'))
                format_type(ctx, info.elem)
            }
            
          case runtime.Type_Info_Multi_Pointer:
            format_view(ctx, view_string("[^]"))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Soa_Pointer:
            format_view(ctx, view_string("#soa ^"))
            format_type(ctx, info.elem)
            
            
          case runtime.Type_Info_Simd_Vector:
            format_view(ctx, view_string("#simd["))
            format_view(ctx, view_integer(info.count))
            format_view(ctx, view_character(']'))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Matrix:
            if info.layout == .Row_Major do format_view(ctx, view_string("#row_major "))
            format_view(ctx, view_string("matrix["))
            format_view(ctx, view_integer(info.row_count))
            format_view(ctx, view_character(','))
            format_view(ctx, view_integer(info.column_count))
            format_view(ctx, view_character(']'))
            format_type(ctx, info.elem)
                
          case runtime.Type_Info_Array:
            format_view(ctx, view_character('['))
            format_view(ctx, view_integer(info.count))
            format_view(ctx, view_character(']'))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Enumerated_Array:
            if info.is_sparse do format_view(ctx, view_string("#sparse "))
            format_view(ctx, view_character('['))
            format_type(ctx, info.index)
            format_view(ctx, view_character(']'))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Dynamic_Array:
            format_view(ctx, view_string("[dynamic]"))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Slice:
            format_view(ctx, view_string("[]"))
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Struct:
            switch info.soa_kind {
              case .None:
              case .Fixed:
                format_view(ctx, view_string("#soa["))
                format_view(ctx, view_integer(info.soa_len))
                format_view(ctx, view_character(']'))
                format_type(ctx, info.soa_base_type)
              case .Slice:
                format_view(ctx, view_string("#soa[]"))
                format_type(ctx, info.soa_base_type)
              case .Dynamic:
                format_view(ctx, view_string("#soa[dynamic]"))
                format_type(ctx, info.soa_base_type)
            }
            
            format_view(ctx, view_string("struct "))
            if .packed    in info.flags  do format_view(ctx, view_string("#packed "))
            if .raw_union in info.flags  do format_view(ctx, view_string("#raw_union "))
            if .align     in info.flags {
                format_view(ctx, view_string("#align("))
                format_view(ctx, view_integer(type_info.align))
                format_view(ctx, view_character(')'))
            }
            
            format_view(ctx, view_character('{'))
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_view(ctx, view_character('}'))
            }
            
            for i in 0..<info.field_count {
                if i != 0 do format_view(ctx, view_string(", "))
                format_multiline_formatting(ctx, .Linebreak)
                
                if info.usings[i] do format_view(ctx, view_string("using "))
                format_view(ctx, view_string(info.names[i]))
                format_view(ctx, view_string(": "))
                format_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Union:
            format_view(ctx, view_string("union "))
            if info.no_nil      do format_view(ctx, view_string("#no_nil "))
            if info.shared_nil  do format_view(ctx, view_string("#shared_nil "))
            if info.custom_align {
                format_view(ctx, view_string("#align("))
                format_view(ctx, view_integer(type_info.align))
                format_view(ctx, view_character(')'))
            }
            
            format_view(ctx, view_character('{'))
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_view(ctx, view_character('}'))
            }
            
            for variant, i in info.variants {
                if i != 0 do format_view(ctx, view_string(", "))
                format_multiline_formatting(ctx, .Linebreak)
            
                format_type(ctx, variant)
            }
            
          case runtime.Type_Info_Enum:
            format_view(ctx, view_string("enum "))
            format_type(ctx, info.base)
            
            format_view(ctx, view_character('{'))
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_view(ctx, view_character('}'))
            }
            
            for name, i in info.names {
                if i != 0 do format_view(ctx, view_string(", "))
                format_multiline_formatting(ctx, .Linebreak)

                format_view(ctx, view_string(name))
            }
            
          case runtime.Type_Info_Map:
            format_view(ctx, view_string("map["))
            format_type(ctx, info.key)
            format_view(ctx, view_character(']'))
            format_type(ctx, info.value)
            
          case runtime.Type_Info_Bit_Set:
            is_type :: proc (info: ^runtime.Type_Info, $T: typeid) -> bool {
                if info == nil { return false }
                _, ok := runtime.type_info_base(info).variant.(T)
                return ok
            }
            
            format_view(ctx, view_string("bit_set["))
            switch {
              case is_type(info.elem, runtime.Type_Info_Enum):
                format_type(ctx, info.elem)
              case is_type(info.elem, runtime.Type_Info_Rune):
                // @todo(viktor): unicode
                // io.write_encoded_rune(w, rune(info.lower), true, &n) or_return
                format_view(ctx, view_string("..="))
                unimplemented("support unicode encoding/decoding")
                // io.write_encoded_rune(w, rune(info.upper), true, &n) or_return
              case:
                format_view(ctx, view_integer(info.lower))
                format_view(ctx, view_string("..="))
                format_view(ctx, view_integer(info.upper))
            }
            
            if info.underlying != nil {
                format_view(ctx, view_string("; "))
                format_type(ctx, info.underlying)
            }
            format_view(ctx, view_character(']'))
            
          case runtime.Type_Info_Bit_Field:
            format_view(ctx, view_string("bit_field "))
            format_type(ctx, info.backing_type)
            
            format_view(ctx, view_character('{'))
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_view(ctx, view_character('}'))
            }
         
            for i in 0..<info.field_count {
                if i != 0 do format_view(ctx, view_string(", "))
                format_multiline_formatting(ctx, .Linebreak)
                
                format_view(ctx, view_string(info.names[i]))
                format_view(ctx, view_character(':'))
                format_type(ctx, info.types[i])
                format_view(ctx, view_character('|'))
                format_view(ctx, view_integer(info.bit_sizes[i]))
            }
        }
    }
}

////////////////////////////////////////////////

@(private="file") 
RawSlice :: struct {
    data: rawptr,
    len:  int,
}
@(private="file") 
RawAny :: struct {
    data: rawptr,
	id:   typeid,
}