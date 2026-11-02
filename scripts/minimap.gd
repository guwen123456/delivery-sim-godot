extends Control
# 左下角小地图：路由 main.gd 每 0.15s 喂数据后 queue_redraw
var shops: Array = []
var player_pos: Vector2 = Vector2.ZERO
var target_pos: Vector2 = Vector2.ZERO
var has_target: bool = false
var target_is_deli: bool = false

func _ready() -> void:
    custom_minimum_size = Vector2(188, 132)
    size = custom_minimum_size

func world_to_map(p: Vector2) -> Vector2:
    # 世界米坐标 x[-300,300] z[-210,210] -> 地图
    return Vector2((p.x + 300.0) / 600.0 * size.x, (p.y + 210.0) / 420.0 * size.y)

func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.12, 0.2, 0.88))
    var road_c := Color(0.24, 0.33, 0.45)
    for k in range(10):
        var x := (k * 60.0 + 6.4) / 600.0 * size.x + size.x * 0.0
        var mx := ( (-293.6 + k * 60.0) + 300.0) / 600.0 * size.x
        draw_rect(Rect2(mx - 2, 0, 4, size.y), road_c)
    for m in range(7):
        var mz := ( (-203.6 + m * 60.0) + 210.0) / 420.0 * size.y
        draw_rect(Rect2(0, mz - 2, size.x, 4), road_c)
    for s in shops:
        var mp := world_to_map(s)
        draw_rect(Rect2(mp - Vector2(2, 2), Vector2(4, 4)), Color(1.0, 0.7, 0.18))
    if has_target:
        var tp := world_to_map(target_pos)
        draw_circle(tp, 4.5, Color(0.2, 0.85, 0.6) if target_is_deli else Color(0.22, 0.72, 0.97))
    draw_circle(world_to_map(player_pos), 4.2, Color(1.0, 0.83, 0.29))
    draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.08, 0.15), false, 1.5)
