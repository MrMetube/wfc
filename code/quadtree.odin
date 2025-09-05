package main

import "core:mem"

Rectangle2d :: Rectangle([2] f64)

Quad_Tree :: struct ($D: typeid) {
    root:      Quad_Node(D),
    max_depth: i32,
    allocator: mem.Allocator,
    
    first_free_entry: ^Quad_Entry(D),
}

Quad_Node :: struct ($D: typeid) {
    parent:   ^Quad_Node(D),
    children: ^[4]Quad_Node(D),
    order:    Quad_Order,
    bounds:   Rectangle2d,
    sentinel: Quad_Entry(D),
}

Quad_Order :: enum {
    ClockwiseFromBottom,
    CounterclockwiseFromBottom,
    ClockwiseFromTop,
    CounterclockwiseFromTop,
}

Quad_Entry :: struct ($D: typeid) {
    data: D,
    prev: ^Quad_Entry(D),
    next: ^Quad_Entry(D),
}

init_quad_tree :: proc (tree: ^Quad_Tree($D), bounds: Rectangle2d, max_depth: i32 = 16, allocator := context.allocator) {
    tree.allocator = allocator
    
    tree.root.bounds = bounds
    tree.root.order  = .CounterclockwiseFromBottom
    list_init_sentinel(&tree.root.sentinel)
    quad_init_children(tree, &tree.root)
    
    tree.max_depth = max_depth
}

quad_test :: proc(tree: ^Quad_Tree($D), bounds: Rectangle2d) -> (result: ^Quad_Node(D)) { 
    result = quad_op(tree, &tree.root, D{}, bounds, tree.max_depth, .Test)
    if result == nil {
        result = &tree.root
    }
    return result
}
quad_insert :: proc(tree: ^Quad_Tree($D), node: ^Quad_Node(D), data: D, bounds: Rectangle2d) -> (result: ^Quad_Node(D)) { 
    result = quad_op(tree, node, data, bounds, tree.max_depth, .Insert)
    if result == nil {
        result = &tree.root
        link := list_pop_head(&tree.first_free_entry) or_else new(Quad_Entry(D), tree.allocator)
        link ^= { data = data }
        list_prepend(&result.sentinel, link)
    }
    return result
}

quad_op :: proc(tree: ^Quad_Tree($D), node: ^Quad_Node(D), data: D, bounds: Rectangle2d, max_depth: i32, $op: enum { Test, Insert }) -> (result: ^Quad_Node(D)) {
    if max_depth >= 0 && contains_rect(node.bounds, bounds) {
        when op == .Insert {
            b_dim := get_dimension(bounds)
            dim := get_dimension(node.bounds) * 0.5
            if (b_dim.x < dim.x && b_dim.y < dim.y) {
                if node.children == nil {
                    quad_init_children(tree, node)
                }
            }
        }
        
        if node.children != nil {
            for &child in node.children {
                result = quad_op(tree, &child, data, bounds, max_depth-1, op)
                if result != nil do break
            }
        }
        
        if result == nil {
            result = node
            when op == .Insert {
                link := list_pop_head(&tree.first_free_entry) or_else new(Quad_Entry(D), tree.allocator)
                link ^= { data = data }
                list_prepend(&result.sentinel, link)
            }
        }
    }
    
    return result
}

/* 
    The order of the children and their children will form a hilbert curve when iterated.
    The root is clockwise-bottom-left.
    The 2nd and 3rd child always keep their parents order.
    The 1st and 4th child change the order based on their parents order.
 */
quad_init_children :: proc (tree: ^Quad_Tree($D), node: ^Quad_Node(D)) {
    node.children = new(type_of(node.children^), tree.allocator)
    
    dim := get_dimension(node.bounds) * 0.5
    bl := rectangle_min_dimension(node.bounds.min + dim * {0,0}, dim)
    br := rectangle_min_dimension(node.bounds.min + dim * {1,0}, dim)
    tl := rectangle_min_dimension(node.bounds.min + dim * {0,1}, dim)
    tr := rectangle_min_dimension(node.bounds.min + dim * {1,1}, dim)
    
    sub_rects: [4]Rectangle2d = ---
    switch node.order {
        case .ClockwiseFromBottom:        sub_rects = {bl, tl, tr, br}
        case .CounterclockwiseFromBottom: sub_rects = {bl, br, tr, tl}
        case .ClockwiseFromTop:           sub_rects = {tr, br, bl, tl}
        case .CounterclockwiseFromTop:    sub_rects = {tr, tl, bl, br}
    }
    
    first_child, last_child: Quad_Order = ---, ---
    switch node.order {
        case .ClockwiseFromBottom:        first_child, last_child = .CounterclockwiseFromBottom, .CounterclockwiseFromTop
        case .CounterclockwiseFromBottom: first_child, last_child = .ClockwiseFromBottom, .ClockwiseFromTop
        case .ClockwiseFromTop:           first_child, last_child = .CounterclockwiseFromTop, .CounterclockwiseFromBottom
        case .CounterclockwiseFromTop:    first_child, last_child = .ClockwiseFromTop, .ClockwiseFromBottom
    }
    
    for &child, index in node.children {
        child = { parent = node }
        list_init_sentinel(&child.sentinel)
        child.bounds = sub_rects[index]
    }
    
    node.children[0].order = first_child
    node.children[1].order = node.order
    node.children[2].order = node.order
    node.children[3].order = last_child
}
