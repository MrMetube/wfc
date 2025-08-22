#+vet !unused-procedures
package main

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
    arena:  ^Arena,
    points: [] v2d,
    
    tree: Quad_Tree(Work_Triangle),
    
    // takes index -3 -2 -1
    super_tri_index: TriIndex,
    super_triangle:  Triangle,
    point_index:     i32,
    bad_triangles:   map[^Quad_Entry(Work_Triangle)] [3] Edge,
    polygon:         map[Edge] b32,
    all_bad_edges:   map[Edge] i32,
    
    triangle_count: i64,
}

////////////////////////////////////////////////

step_count: u32

begin_triangulation :: proc(dt: ^Delauney_Triangulation, arena: ^Arena, points: []v2d) {
    spall_proc()
    dt.arena  = arena
    dt.points = points

    max_vertex: v2d = 1
    extra :: 0
    dt.super_triangle[0] = 0 - extra
    dt.super_triangle[1] = {2*max_vertex.x, 0} + {extra*2, -extra}
    dt.super_triangle[2] = {0, 2*max_vertex.y} + {-extra, extra*2}
    
    dt.super_tri_index = {-3, -2, -1}
    
    { // I ~ O(n): Sort points into a hilbert curve for better locality in the main part
        spall_scope("Sort points into a hilbert curve")
        
        temp := begin_temporary_memory(arena)
        defer end_temporary_memory(temp)
        
        point_tree: Quad_Tree(v2d)
        init_quad_tree(&point_tree, temp.arena, rectangle_min_dimension(v2d{}, 2))
        
        for point in points {
            quad_insert(&point_tree, &point_tree.root, point, rectangle_min_dimension(point, 0))
        }
        
        buffer := Array(v2d) { data = points }
        collect_points(&point_tree.root, &buffer)
    }
    
    init_quad_tree(&dt.tree, dt.arena, rectangle_center_dimension(v2d{.5,.5}, v2d{400,400}))
    
    triangulation_append(dt, dt.super_tri_index, dt.super_triangle)
}

triangulation_append :: proc (dt: ^Delauney_Triangulation, index: TriIndex, triangle: Triangle) {
    spall_proc()
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
    spall_proc()
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
    step_count += 1
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
    
    spall_scope("collect nodes")
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
     
        append(dest, link.data)
    }
}

collect_triangles :: proc (node: ^Quad_Node(Work_Triangle), dest: ^Array(Triangle), points: []v2d, dt: ^Delauney_Triangulation) {
    if node.children != nil {
        for &child in node.children {
            collect_triangles(&child, dest, points, dt)
        }
    }
    
    spall_scope("collect nodes")
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

collect_work_triangles :: proc (node: ^Quad_Node(Work_Triangle), dest: ^Array(Work_Triangle), points: []v2d, dt: ^Delauney_Triangulation) {
    if node.children != nil {
        for &child in node.children {
            collect_work_triangles(&child, dest, points, dt)
        }
    }
    
    spall_scope("collect nodes")
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
        
        
        contains_vertex_of_super_triangle: i32
        check: for index in link.data.triangle {
            if index < 0 {
                contains_vertex_of_super_triangle += 1
            }
        }
        
        if contains_vertex_of_super_triangle == 0 {
            append(dest, link.data)
        }
    }
}

end_triangulation :: proc(dt: ^Delauney_Triangulation) -> (result: [] Triangle) {
    spall_proc()
    buffer := make_array(dt.arena, Triangle, dt.triangle_count)
    
    collect_triangles(&dt.tree.root, &buffer, dt.points, dt)
    
    result = slice(buffer)
    return result
}

Voronoi_Cell :: struct {
    center: v2d,
    points:            [dynamic] v2d,
    neighbour_indices: [dynamic] i32,
}
end_triangulation_voronoi_cells :: proc(dt: ^Delauney_Triangulation) -> (result: [] Voronoi_Cell) {
    spall_proc()
    buffer := make_array(dt.arena, Work_Triangle, dt.triangle_count)
    
    collect_work_triangles(&dt.tree.root, &buffer, dt.points, dt)
    
    triangles := slice(buffer)
    
    result = make([] Voronoi_Cell, len(dt.points))
    for &it, index in result {
        it.center = dt.points[index]
    }
    
    for wt in triangles {
        contains_super_triangles: b32
        for index in wt.triangle do if index < 0 {
            contains_super_triangles = true
            break
        }
        if contains_super_triangles do continue
        
        append_unique :: proc (array: ^[dynamic] $T, value: T) {
            spall_proc()
            for it in array do if it == value do return
            append(array, value)
        }
        
        for a in wt.triangle {
            voronoi := &result[a]
            append_unique(&voronoi.points, wt.circum_circle.center)
            
            for b in wt.triangle {
                if a != b {
                    append_unique(&voronoi.neighbour_indices, b)
                    pa := dt.points[a]
                    pb := dt.points[b]
                    edge_center := linear_blend(pa, pb, 0.5)
                    append_unique(&voronoi.points, edge_center)
                }
            }
        }
    }
    
    Foo :: struct { center, point: v2d}
    points := make([dynamic] Foo, context.temp_allocator)
    for &cell in result {
        clear(&points)
        for point in cell.points {
            append(&points, Foo { cell.center, point})
        }
        
        // Sort centers counterclockwise around `center`
        slices.sort_by(points[:], proc(a: Foo, b: Foo) -> (result: bool) {
            angle_a := atan2(a.point - a.center)
            angle_b := atan2(b.point - b.center)
            result = angle_a < angle_b
            return result
        })
        
        for it, index in points {
            cell.points[index] = it.point
        }
    }
    
    return result
}

circum_circle :: proc(t: Triangle) -> (result: Circle) {
    a := t[0]
    b := t[1]
    c := t[2]
    
    bc := b-c
    ca := c-a
    ab := a-b
    
    // @note(viktor): If the denominator is 0 or close enough the result will 
    // have an Infinity. This happens when the triangle is degenerate, i.e. the 
    // points are colinear. It is however fine as we only use the circum circles
    // to check if a point lies within, and a circle of infinite radius will 
    // behave correctly in that regard.
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
