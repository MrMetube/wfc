#+vet !unused-procedures
package main

import "core:mem"
import slices "core:slice"

v2d :: [2] f64
v3d :: [3] f64

Triangle :: [3] v2d
TriIndex :: [3] i32
Edge     :: [2] i32
Circle :: struct {
    center:         v2d,
    radius_squared: f64,
}

Work_Triangle :: struct {
    triangle:      TriIndex,
    circum_circle: Circle,
}

Delauney_Triangulation :: struct {
    allocator: mem.Allocator,
    points:    [] v2d,
    
    tree: Quad_Tree(Work_Triangle),
    
    // defined as index -3 -2 -1
    super_tri_index: TriIndex,
    super_triangle:  Triangle,
    point_index:     i32,
    bad_triangles:   map[^Quad_Entry(Work_Triangle)] [3] Edge,
    polygon:         map[Edge] b32,
    all_bad_edges:   map[Edge] i32,
    
    triangle_count: i64,
}

////////////////////////////////////////////////

Voronoi_Cell :: struct {
    is_edge: bool,
    center:  v2d,
    points:            [dynamic] v2d,
    neighbour_indices: [dynamic] i32,
}

////////////////////////////////////////////////

begin_triangulation :: proc(dt: ^Delauney_Triangulation, points: []v2d, allocator := context.allocator) {
    spall_proc()
    dt.allocator = allocator
    dt.points = points
    
    dt.all_bad_edges.allocator = allocator
    dt.polygon.allocator       = allocator
    dt.bad_triangles.allocator = allocator

    max_vertex: v2d = 1
    extra :: 1
    dt.super_triangle[0] = 0 - extra
    dt.super_triangle[1] = {2*max_vertex.x, 0} + {extra*2, -extra}
    dt.super_triangle[2] = {0, 2*max_vertex.y} + {-extra, extra*2}
    
    dt.super_tri_index = {-3, -2, -1}
    
    { // I ~ O(n): Sort points into a hilbert curve for better locality in the main part
        spall_scope("Sort points into a hilbert curve")
        
        point_tree: Quad_Tree(v2d)
        init_quad_tree(&point_tree, rectangle_min_dimension(v2d{}, 2), allocator = context.temp_allocator)
        
        for point in points {
            quad_insert(&point_tree, &point_tree.root, point, rectangle_min_dimension(point, 0))
        }
        
        buffer := Array(v2d) { data = points }
        collect_points(&point_tree.root, &buffer)
    }
    
    init_quad_tree(&dt.tree, rectangle_center_dimension(v2d{.5,.5}, v2d{400,400}), allocator = dt.allocator)
    
    triangulation_append(dt, dt.super_tri_index, dt.super_triangle)
}

triangulation_append :: proc (dt: ^Delauney_Triangulation, index: TriIndex, triangle: Triangle) {
    circle := circum_circle(triangle)
    
    wt := Work_Triangle{ index, circle }
    
    bounds := rectangle_center_half_dimension(circle.center, square_root(circle.radius_squared))
    into := quad_insert(&dt.tree, &dt.tree.root, wt, bounds)
    assert(into != nil)
    
    dt.triangle_count += 1
}

complete_triangulation :: proc (dt: ^Delauney_Triangulation) {
    spall_proc()
    for dt.point_index < auto_cast len(dt.points) {
        step_triangulation(dt)
    }
}

step_triangulation :: proc(dt: ^Delauney_Triangulation) {
    // @note(viktor): We use the Bowyer-Watson algorithm to create the delauney triangulation
    // See: https://en.wikipedia.org/wiki/Bowyer%E2%80%93Watson_algorithm
    
    point := dt.points[dt.point_index]
    defer dt.point_index += 1
    
    clear(&dt.bad_triangles)
    clear(&dt.all_bad_edges)
    clear(&dt.polygon)
    
    rect := rectangle_center_dimension(point, 0)
    
    // II ~ O(n^2): find bad triangles :: lim -> 100%   
    spall_begin("find bad triangles")
    
    for node := quad_test(&dt.tree, rect); node != nil; node = node.parent {
        for link := node.sentinel.next; link != &node.sentinel; link = link.next {
            wt     := &link.data
            circle := wt.circum_circle
            if inside_circumcircle(circle, point) {
                a, b, c := wt.triangle[0], wt.triangle[1], wt.triangle[2]
                
                dt.bad_triangles[link] = { {a, b}, {b, c}, {c, a} }
            }
        }
    }
    
    spall_end()
    // III ~ O(n): collect polygon edges and remove bad triangles   
    spall_begin("collect polygon edges and remove bad triangles")
    
    for _, edges in dt.bad_triangles {
        for edge in edges do dt.all_bad_edges[edge]    += 1
        for edge in edges do dt.all_bad_edges[edge.yx] += 1
    }
    
    for link, edges in dt.bad_triangles {
        for edge in edges {
            count, ok := dt.all_bad_edges[edge]
            if ok && count == 1 {
                dt.polygon[edge] = true
            }
        }
        
        list_remove(link)
        list_push(&dt.tree.first_free_entry, link)
    }
    
    spall_end()
    // IV ~ O(n): add new egdes    
    spall_begin("add new egdes")
    
    for edge in dt.polygon {
        index := TriIndex { dt.point_index , edge[0], edge[1] }
        triangle := triangle_from_index(dt, index)
        // @todo(viktor): Should we filter degenerate triangles here?
        triangulation_append(dt, index, triangle)
    }
    
    spall_end()
}

triangle_from_index :: proc (dt: ^Delauney_Triangulation, index: TriIndex) -> (result: Triangle) {
    result[0] = index[0] >= 0 ? dt.points[index[0]] : dt.super_triangle[index[0]+3]
    result[1] = index[1] >= 0 ? dt.points[index[1]] : dt.super_triangle[index[1]+3]
    result[2] = index[2] >= 0 ? dt.points[index[2]] : dt.super_triangle[index[2]+3]
    return result
}

collect_points :: proc (node: ^Quad_Node(v2d), dest: ^Array(v2d)) {
    if node.children != nil {
        for &child in node.children {
            collect_points(&child, dest)
        }
    }
    
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
     
        append(dest, link.data)
    }
}

collect_triangles :: proc (node: ^Quad_Node(Work_Triangle), dest: ^[dynamic] Triangle, points: []v2d, dt: ^Delauney_Triangulation) {
    if node.children != nil {
        for &child in node.children {
            collect_triangles(&child, dest, points, dt)
        }
    }
    
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
        
        contains_vertex_of_super_triangle: b32
        check: for index in link.data.triangle {
            if index < 0 {
                contains_vertex_of_super_triangle = true
                break check
            }
        }
        
        if !contains_vertex_of_super_triangle {
            index := link.data.triangle
            tri := Triangle {
                points[index[0]],
                points[index[1]],
                points[index[2]],
            }
            append(dest, tri)
        }
    }
}

collect_work_triangles :: proc (node: ^Quad_Node(Work_Triangle), dest: ^[dynamic] Work_Triangle, points: []v2d, dt: ^Delauney_Triangulation) {
    if node.children != nil {
        for &child in node.children {
            collect_work_triangles(&child, dest, points, dt)
        }
    }
    
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
        
        append(dest, link.data)
    }
}

end_triangulation :: proc(dt: ^Delauney_Triangulation) -> (result: [] Triangle) {
    spall_proc()
    buffer := make([dynamic] Triangle, 0, dt.triangle_count, dt.allocator)
    
    collect_triangles(&dt.tree.root, &buffer, dt.points, dt)
    
    result = buffer[:]
    return result
}

// @todo(viktor): what is this called? its an intersection between a vector and a side of a aabb
foo :: proc (a, b: $V/[2]$E, is_x: bool, side: E) -> (result: V) {
    ab := b - a
    assert( is_x || ab.y != 0)
    assert(!is_x || ab.x != 0)
    
    result.x =  is_x ? side : (a.x + ab.x * (side-a.y) / ab.y)
    result.y = !is_x ? side : (a.y + ab.y * (side-a.x) / ab.x)
    
    return result
}

foo_all :: proc (a, b: $V, bounds: Rectangle(V)) -> (ok: b32, result: V) {
    if b.x < bounds.min.x && !(a.x < bounds.min.x) { ok = true; result = foo(a, b,  true, bounds.min.x) }
    if b.x > bounds.max.x && !(a.x > bounds.max.x) { ok = true; result = foo(a, b,  true, bounds.max.x) }
    if b.y < bounds.min.y && !(a.y < bounds.min.y) { ok = true; result = foo(a, b, false, bounds.min.y) }
    if b.y > bounds.max.y && !(a.y > bounds.max.y) { ok = true; result = foo(a, b, false, bounds.max.y) }
    
    return ok, result
}

end_triangulation_voronoi_cells :: proc(dt: ^Delauney_Triangulation) -> (result: [] Voronoi_Cell) {
    spall_proc()
    buffer := make([dynamic] Work_Triangle, 0, dt.triangle_count, context.temp_allocator)
    
    collect_work_triangles(&dt.tree.root, &buffer, dt.points, dt)
    
    triangles := buffer[:]
    
    result = make([] Voronoi_Cell, len(dt.points), dt.allocator)
    
    for &voronoi in result {
        voronoi.neighbour_indices.allocator = dt.allocator
        voronoi.points.allocator            = dt.allocator
    }
    
    bounds := rectangle_min_dimension(v2d {0,0}, 1)
    
    append_unique :: proc (array: ^[dynamic] $T, value: T) {
        for it in array do if it == value do return
        append(array, value)
    }
    
    append_unique_v2 :: proc (array: ^[dynamic] v2d, value: v2d) {
        for it in array do if length(it - value) < 0.0001 do return
        append(array, value)
    }
    
    for wt in triangles {
        for index_a, it_index in wt.triangle {
            if index_a < 0 do continue
            voronoi := &result[index_a]
            
            index_b := wt.triangle[(it_index + 1)%3]
            index_c := wt.triangle[(it_index + 2)%3]
            
            if index_b >= 0 do append_unique(&voronoi.neighbour_indices, index_b)
            if index_c >= 0 do append_unique(&voronoi.neighbour_indices, index_c)
            
            append_unique_v2(&voronoi.points, wt.circum_circle.center)
        }
    }
    
    foos := make([dynamic] Foo(f64, v2d), context.temp_allocator)
    for &voronoi in result {
        sort_points_counterclockwise_around_center(&voronoi.center, voronoi.points[:], &foos)
    }
    
    for &voronoi in result {
        for point_index := 0; point_index < len(voronoi.points); {
            
            point := voronoi.points[point_index]
            if contains_inclusive(bounds, point) {
                point_index += 1
            } else {
                prev := voronoi.points[(point_index + len(voronoi.points) - 1) % len(voronoi.points)]
                next := voronoi.points[(point_index + len(voronoi.points) + 1) % len(voronoi.points)]
                
                unordered_remove(&voronoi.points, point_index)
                
                p_ok, p := foo_all(prev, point, bounds)
                n_ok, n := foo_all(next, point, bounds)
                for it in voronoi.points do if length(it - p) < 0.01 { p_ok = false; break }
                for it in voronoi.points do if length(it - n) < 0.01 { n_ok = false; break }
                
                if p_ok do append(&voronoi.points, p)
                if n_ok do append(&voronoi.points, n)
                point_index = 0
                
                sort_points_counterclockwise_around_center(&voronoi.center, voronoi.points[:], &foos)
            }
        }
    }
    
    for &voronoi in result {
        sort_points_counterclockwise_around_center(&voronoi.center, voronoi.points[:], &foos)
    }
    
    return result
}

Foo :: struct ($E: typeid, $V: typeid) { angle: E, point: V}
sort_points_counterclockwise_around_center :: proc (center: ^$V/[2]$E, points: [] V, foos: ^[dynamic] Foo(E, V)) {
    clear(foos)
    center ^= 0
    for point in points {
        center^ += point
    }
    center^ /= auto_cast len(points)
    
    for point in points {
        append(foos, Foo(E,V) { angle = atan2(point - center^), point = point })
    }
    
    slices.sort_by(foos[:], proc(a: Foo(E,V), b: Foo(E,V)) -> (result: bool) { return a.angle < b.angle })
    
    for it, it_index in foos {
        points[it_index] = it.point
    }
}

circum_circle :: proc(t: Triangle) -> (result: Circle) {
    a := t[0]
    b := t[1]
    c := t[2]
    
    bc := b-c
    ca := c-a
    ab := a-b
    
    // @note(viktor): If the denominator is 0 or close enough the result will have an Infinity. This happens when the triangle is degenerate, i.e. the points are colinear. It is however fine as we only use the circum circles to check if a point lies within, and a circle of infinite radius will behave correctly in that regard.
    abc := v3d { a.x, b.x, c.x }
    bca := v3d { bc.y, ca.y, ab.y }
    d :=  0.5 / dot(abc, bca)
    
    al := length_squared(a)
    bl := length_squared(b)
    cl := length_squared(c)
    abcl := v3d { al, bl, cl}
    
    ux := dot(abcl,  bca)
    uy := dot(abcl, -v3d{bc.x, ca.x, ab.x})
    
    result.center         = {ux, uy} * d
    result.radius_squared = length_squared(result.center - a)
    
    return result
}

inside_circumcircle :: proc(circle: Circle, p: v2d) -> b32 {
    distance_squared := length_squared(p - circle.center)
    return distance_squared < circle.radius_squared
}
