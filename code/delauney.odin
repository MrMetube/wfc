package main

import "core:fmt"
import "core:time"
import "core:math"

v2d :: [2] f64
v3d :: [3] f64

Triangle :: [3] v2d
TriIndex :: [3] i32
Edge     :: [2] i32
Circle :: struct {
    center:         v2d,
    radius_squared: f64,
}

WorkTriangle :: struct {
    triangle:      TriIndex,
    circum_circle: Circle,
}

DelauneyTriangulation :: struct {
    arena:  ^Arena,
    points: [] v2d,
    
    tree: QuadTree(WorkTriangle),
    
    // takes index -3 -2 -1
    super_tri_index: TriIndex,
    super_triangle:  Triangle,
    point_index:    i32,
    bad_triangles:  map[^QuadEntry(WorkTriangle)][3]Edge,
    polygon:        map[Edge]b32,
    all_bad_edges:  map[Edge]i32,
    
    triangle_count: i64,
}

////////////////////////////////////////////////

I:   time.Duration // ~ O(n)
II:  time.Duration // ~ O(n^2)
III: time.Duration // ~ O(n)
IV:  time.Duration // ~ O(n)
step_count: u32

begin_triangulation :: proc(dt: ^DelauneyTriangulation, arena: ^Arena, points: []v2d) {
    dt.arena  = arena
    dt.points = points

    max_vertex: v2d = 1
    extra :: 0
    dt.super_triangle[0] = 0 - extra
    dt.super_triangle[1] = {2*max_vertex.x, 0} + {extra*2, -extra}
    dt.super_triangle[2] = {0, 2*max_vertex.y} + {-extra, extra*2}
    
    dt.super_tri_index = {-3, -2, -1}
    
    {
        // @note(viktor): Sort points into a hilbert curve
        start := time.now()
        defer I = time.diff(start, time.now())
        
        temp := begin_temporary_memory(arena)
        defer end_temporary_memory(temp)
        
        point_tree: QuadTree(v2d)
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

triangulation_append :: proc (dt: ^DelauneyTriangulation, index: TriIndex, triangle: Triangle) {
    circle := circum_circle(triangle)
    
    wt := WorkTriangle{ index, circle }
    
    bounds := rectangle_center_half_dimension(circle.center, square_root(circle.radius_squared))
    into := quad_insert(&dt.tree, &dt.tree.root, wt, bounds)
    assert(into != nil)
    
    dt.triangle_count += 1
}

complete_triangulation :: proc (dt: ^DelauneyTriangulation) -> (triangles: [] Triangle) {
    for dt.point_index < auto_cast len(dt.points) {
        step_triangulation(dt)
    }
    triangles = end_triangulation(dt)
    return triangles
}

step_triangulation :: proc(dt: ^DelauneyTriangulation) {
    // @note(viktor): We use the Bowyer-Watson algorithm to create the delauney triangulation
    // See: https://en.wikipedia.org/wiki/Bowyer%E2%80%93Watson_algorithm
    
    point := dt.points[dt.point_index]
    defer dt.point_index += 1
    
    clear(&dt.bad_triangles)
    clear(&dt.all_bad_edges)
    clear(&dt.polygon)
    
    rect := rectangle_center_dimension(point, 0)
    
    // II find bad triangles :: lim -> 100%
    II_start := time.now()
    
    for node := quad_test(&dt.tree, rect); node != nil; node = node.parent {
        for link := node.sentinel.next; link != &node.sentinel; link = link.next {
            wt := &link.data
            circle   := wt.circum_circle
            if inside_circumcircle(circle, point) {
                triangle := wt.triangle
                a, b, c := triangle[0], triangle[1], triangle[2]
                
                dt.bad_triangles[link] = { {a, b}, {b, c}, {c, a} }
            }
        }
    }
    
    II += time.diff(II_start, time.now())
    // III collect polygon edges and remove bad triangles
    III_start := time.now()
    
    for link, edges in dt.bad_triangles {
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
    
    III += time.diff(III_start, time.now())
    //  IV add new egdes
    IV_start := time.now()
    
    for edge in dt.polygon {
        index := TriIndex { dt.point_index , edge[0], edge[1] }
        triangle := triangle_from_index(dt, index)
        // @todo(viktor): Should we filter degenerate triangles here?
        triangulation_append(dt, index, triangle)
    }
    
    IV += time.diff(IV_start, time.now())
    step_count += 1
}

triangle_from_index :: proc (dt: ^DelauneyTriangulation, index: TriIndex) -> (result: Triangle) {
    result[0] = index[0] >= 0 ? dt.points[index[0]] : dt.super_triangle[index[0]+3]
    result[1] = index[1] >= 0 ? dt.points[index[1]] : dt.super_triangle[index[1]+3]
    result[2] = index[2] >= 0 ? dt.points[index[2]] : dt.super_triangle[index[2]+3]
    return result
}

collect_points :: proc (node: ^QuadNode(v2d), dest: ^Array(v2d)) {
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

collect_triangles :: proc (node: ^QuadNode(WorkTriangle), dest: ^Array(Triangle), points: []v2d) {
    if node.children != nil {
        for &child in node.children {
            collect_triangles(&child, dest, points)
        }
    }
    
    for link := node.sentinel.next; link != &node.sentinel;  {
        assert(link.next != link)
        
        next := link.next
        defer link = next
        
        contains_vertex: b32
        check: for index in link.data.triangle {
            if index < 0 {
                contains_vertex = true
                break check
            }
        }
        
        if !contains_vertex {
            tri := Triangle {
                points[link.data.triangle[0]],
                points[link.data.triangle[1]],
                points[link.data.triangle[2]],
            }
            append(dest, tri)
        }
    }
}

end_triangulation :: proc(dt: ^DelauneyTriangulation) -> ([]Triangle) {
    buffer := make_array(dt.arena, Triangle, dt.triangle_count)
    
    collect_triangles(&dt.tree.root, &buffer, dt.points)
    
    return slice(buffer)
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
    denom := (2 * (a.x * bc.y + b.x * ca.y + c.x * ab.y))
    d := 1 / denom
    
    al := length_squared(a)
    bl := length_squared(b)
    cl := length_squared(c)
    
    ux := dot(v3d{al, bl, cl},  v3d{bc.y, ca.y, ab.y})
    uy := dot(v3d{al, bl, cl}, -v3d{bc.x, ca.x, ab.x})
    
    result.center  = {ux, uy} * d
    result.radius_squared = length_squared(result.center - a)
    
    return result
}

inside_circumcircle :: proc(circle: Circle, p: v2d) -> b32 {
    distance := length_squared(p - circle.center)
    return distance < circle.radius_squared
}
