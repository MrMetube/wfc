package main

Rectangle2d :: Rectangle([2] f64)

QuadTree :: struct ($D: typeid) {
    root:      QuadNode(D),
    max_depth: i32,
    arena:     ^Arena,
    
    first_free_entry: ^QuadEntry(D),
}

QuadNode :: struct ($D: typeid) {
    parent:   ^QuadNode(D),
    children: ^[4]QuadNode(D),
    order:    QuadOrder,
    bounds:   Rectangle2d,
    sentinel: QuadEntry(D),
}

QuadOrder :: enum {
    ClockwiseFromBottom,
    CounterclockwiseFromBottom,
    ClockwiseFromTop,
    CounterclockwiseFromTop,
}

QuadEntry :: struct ($D: typeid) {
    data: D,
    prev: ^QuadEntry(D),
    next: ^QuadEntry(D),
}

init_quad_tree :: proc (tree: ^QuadTree($D), arena: ^Arena, bounds: Rectangle2d, max_depth: i32 = 16) {
    tree.arena = arena
    
    tree.root.bounds = bounds
    tree.root.order  = .CounterclockwiseFromBottom
    list_init_sentinel(&tree.root.sentinel)
    quad_init_children(tree, &tree.root)
    
    tree.max_depth = max_depth
}

quad_test :: proc(tree: ^QuadTree($D), bounds: Rectangle2d) -> (result: ^QuadNode(D)) { 
    result = quad_op(tree, &tree.root, D{}, bounds, tree.max_depth, .Test)
    if result == nil {
        result = &tree.root
    }
    return result
}
quad_insert :: proc(tree: ^QuadTree($D), node: ^QuadNode(D), data: D, bounds: Rectangle2d) -> (result: ^QuadNode(D)) { 
    result = quad_op(tree, node, data, bounds, tree.max_depth, .Insert)
    if result == nil {
        result = &tree.root
        link := list_pop_head(&tree.first_free_entry) or_else push(tree.arena, QuadEntry(D))
        link ^= { data = data }
        list_prepend(&result.sentinel, link)
    }
    return result
}

quad_op :: proc(tree: ^QuadTree($D), node: ^QuadNode(D), data: D, bounds: Rectangle2d, max_depth: i32, $op: enum { Test, Insert }) -> (result: ^QuadNode(D)) {
    if max_depth >= 0 && contains_rect(node.bounds, bounds) {
        b_dim := get_dimension(bounds)
        dim := get_dimension(node.bounds) * 0.5
        when op == .Insert do if (b_dim.x < dim.x && b_dim.y < dim.y) {
            if node.children == nil {
                quad_init_children(tree, node)
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
                link := list_pop_head(&tree.first_free_entry) or_else push(tree.arena, QuadEntry(D))
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
quad_init_children :: proc (tree: ^QuadTree($D), node: ^QuadNode(D)) {
    node.children = push_struct(tree.arena, type_of(node.children^))
    
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
    
    first_child, last_child: QuadOrder = ---, ---
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
