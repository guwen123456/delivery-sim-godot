extends Node3D
# 送外卖模拟器 · Godot 版主逻辑：建城 / 订单 / 车流 / 行人 / 红绿灯 / 昼夜 / HUD / QA 自动驾驶
# 世界单位 = 米。地图 600x420，路网每 60 米，街区内 2x2 栋楼（与网页版同一套布局数据）

const PlayerScene := preload("res://scripts/player.gd")
const MinimapScript := preload("res://scripts/minimap.gd")

const DAY_GOAL := 260.0
var DAY_SECONDS := 270.0

# ---------------- 基础数据（米） ----------------
var DISTRICTS := [
    {"name": "大学城", "x": -216.0, "z": -126.0, "r": 86.0, "demand": 1.35},
    {"name": "商务区", "x": 12.0, "z": -132.0, "r": 94.0, "demand": 1.2},
    {"name": "老街", "x": 204.0, "z": -114.0, "r": 80.0, "demand": 1.0},
    {"name": "居民区", "x": -148.0, "z": 102.0, "r": 104.0, "demand": 0.95},
    {"name": "滨江新区", "x": 96.0, "z": 90.0, "r": 104.0, "demand": 1.05},
    {"name": "公园", "x": 224.0, "z": 102.0, "r": 66.0, "demand": 0.55},
]
var SHOP_NAMES := ["南炉烤肉饭", "桂雨茶饮", "长街米粉", "槐花饺子馆", "夜市烧烤摊", "学府食堂", "白领便当", "河畔咖啡"]
var SHOP_POS := [
    Vector2(-224.8, -143.6), Vector2(15.2, -143.6), Vector2(195.2, -143.6), Vector2(-164.8, 96.4),
    Vector2(195.2, 96.4), Vector2(-164.8, -83.6), Vector2(15.2, -83.6), Vector2(135.2, 96.4),
]
var WXLIST := [
    {"n": "晴", "i": "☀️", "sp": 1.0, "bonus": 0.0},
    {"n": "多云", "i": "⛅", "sp": 0.97, "bonus": 0.05},
    {"n": "小雨", "i": "🌧️", "sp": 0.9, "bonus": 0.2},
    {"n": "大风", "i": "💨", "sp": 0.94, "bonus": 0.1},
]
var ROAD_X: Array = []   # 纵向路中心 x
var ROAD_Z: Array = []   # 横向路中心 z

# ---------------- 状态 ----------------
var running := false
var over := false
var day := 1
var t := 0.0
var money := 0.0
var rating := 5.0
var done_c := 0
var ontime_c := 0
var late_c := 0
var combo := 0
var best_combo := 0
var online := true
var fines := 0
var crash_cd := 0.0
var in_light_zone := false
var spawn_t := 1.0
var weather: Dictionary = WXLIST[0]
var orders: Array = []
var oid := 1
var buildings: Array = []   # {min_x,max_x,min_z,max_z,cx,cz}
var rng := RandomNumberGenerator.new()

# ---------------- 节点 ----------------
var player  # scripts/player.gd（不标注原生类型，以便访问脚本成员）
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var lamp_head_mat: StandardMaterial3D
var lamp_ns: MultiMeshInstance3D
var lamp_ew: MultiMeshInstance3D
var last_light_key := ""
var pick_pillar: Node3D
var deli_pillar: Node3D
var rain_fx: GPUParticles3D
var cars: Array = []
var peds: Array = []
var eng_player: AudioStreamPlayer
var sfx_players := {}
var cam: Camera3D

# HUD
var ui_day: Label
var ui_wx: Label
var ui_money: Label
var ui_rating: Label
var ui_goal: Label
var panel_box: VBoxContainer
var toast_box: VBoxContainer
var nav_box: VBoxContainer
var nav_arrow: Label
var nav_text: Label
var speed_label: Label
var minimap  # scripts/minimap.gd（不标注类型）
var start_overlay: CenterContainer
var day_overlay: CenterContainer
var day_title: Label
var day_stats: Label
var day_comment: Label
var panel_sig := ""
var hud_tick := 0.0

# QA
var qa_mode := false
var qa_wps: Array = []
var qa_wp_i := 0
var qa_target_key := ""
var qa_best_d := 1e9
var qa_best_t := 0.0
var qa_escape := 0.0
var qa_shot_street := false
var qa_shot_deli := false
var qa_print_t := 0.0
var qa_waited := 0.0

func _ready() -> void:
    rng.randomize()
    for k in range(10):
        ROAD_X.append(-293.6 + k * 60.0)
    for m in range(7):
        ROAD_Z.append(-203.6 + m * 60.0)
    _setup_input()
    _parse_args()
    _build_environment()
    _build_world()
    _build_player()
    _build_traffic()
    _build_peds()
    _build_fx()
    _build_audio()
    _build_hud()
    _build_overlays()
    new_day()
    if qa_mode:
        start_overlay.visible = false
        running = true
        player.bot_mode = true
        print("QA MODE ON, day_seconds=", DAY_SECONDS)

func _parse_args() -> void:
    var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
    for a in args:
        if a == "--qa":
            qa_mode = true
        elif a.begins_with("--day="):
            var v := a.trim_prefix("--day=").to_int()
            if v >= 60 and v <= 900:
                DAY_SECONDS = float(v)

func _setup_input() -> void:
    _add_key_action("ride_gas", [KEY_W, KEY_UP])
    _add_key_action("ride_brake", [KEY_S, KEY_DOWN])
    _add_key_action("ride_left", [KEY_A, KEY_LEFT])
    _add_key_action("ride_right", [KEY_D, KEY_RIGHT])

func _add_key_action(action: StringName, keys: Array) -> void:
    if not InputMap.has_action(action):
        InputMap.add_action(action)
    for k in keys:
        var ev := InputEventKey.new()
        ev.physical_keycode = k
        InputMap.action_add_event(action, ev)

# ---------------- 环境 ----------------
func _build_environment() -> void:
    var we := WorldEnvironment.new()
    env = Environment.new()
    env.background_mode = Environment.BG_SKY
    sky_mat = ProceduralSkyMaterial.new()
    sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
    sky_mat.sky_horizon_color = Color(0.78, 0.87, 0.96)
    sky_mat.ground_bottom_color = Color(0.25, 0.3, 0.35)
    sky_mat.ground_horizon_color = Color(0.78, 0.87, 0.96)
    var sky := Sky.new()
    sky.sky_material = sky_mat
    env.sky = sky
    env.tonemap_mode = Environment.TONE_MAPPER_ACES
    env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    env.ambient_light_color = Color(0.75, 0.83, 0.95)
    env.ambient_light_energy = 0.85
    env.fog_enabled = true
    env.fog_light_color = Color(0.72, 0.82, 0.93)
    env.fog_density = 0.0009
    env.fog_sky_affect = 0.6
    we.environment = env
    add_child(we)
    sun = DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-52, -38, 0)
    sun.light_energy = 1.25
    sun.light_color = Color(1.0, 0.95, 0.85)
    sun.shadow_enabled = true
    sun.directional_shadow_max_distance = 260.0
    sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
    add_child(sun)

# ---------------- 世界 ----------------
func _tex(path: String) -> Texture2D:
    return load(path) as Texture2D

func _std(c: Color, tex: Texture2D = null) -> StandardMaterial3D:
    var m := StandardMaterial3D.new()
    m.albedo_color = c
    if tex:
        m.albedo_texture = tex
    return m

func _build_world() -> void:
    # 地面
    var ground_mi := MeshInstance3D.new()
    var plane := PlaneMesh.new()
    plane.size = Vector2(600, 420)
    ground_mi.mesh = plane
    ground_mi.material_override = _std(Color.WHITE, _tex("res://assets/ground.png"))
    add_child(ground_mi)
    var gbody := StaticBody3D.new()
    var gshape := CollisionShape3D.new()
    gshape.shape = WorldBoundaryShape3D.new()
    gbody.add_child(gshape)
    add_child(gbody)
    # 世界围墙（4 面隐形墙）
    var wall_body := StaticBody3D.new()
    for spec in [[Vector3(0, 4, -212), Vector3(620, 8, 2)], [Vector3(0, 4, 212), Vector3(620, 8, 2)], [Vector3(-302, 4, 0), Vector3(2, 8, 440)], [Vector3(302, 4, 0), Vector3(2, 8, 440)]]:
        var cs := CollisionShape3D.new()
        var bs := BoxShape3D.new()
        bs.size = spec[1]
        cs.shape = bs
        cs.position = spec[0]
        wall_body.add_child(cs)
    add_child(wall_body)
    # 建筑
    var facades := {
        "glass": _std(Color.WHITE, _tex("res://assets/facade_glass.png")),
        "tower": _std(Color.WHITE, _tex("res://assets/facade_tower.png")),
        "brick": _std(Color.WHITE, _tex("res://assets/facade_brick.png")),
        "home": _std(Color.WHITE, _tex("res://assets/facade_home.png")),
        "office": _std(Color.WHITE, _tex("res://assets/facade_office.png")),
    }
    var roof_mat := _std(Color(0.22, 0.26, 0.31))
    var tank_mat := _std(Color(0.44, 0.48, 0.53))
    var kinds := ["brick", "home", "office", "home"]
    for bx in range(10):
        for by in range(7):
            for i in range(2):
                for j in range(2):
                    var cpx := bx * 300 + 108 + i * 78
                    var cpy := by * 300 + 108 + j * 78
                    var wx := cpx / 5.0 - 300.0
                    var wz := cpy / 5.0 - 210.0
                    var w := 14.4 + rng.randf() * 1.6
                    var d := 14.4 + rng.randf() * 1.6
                    var dc := district_at(Vector2(cpx, cpy))
                    var h := 10.0 + rng.randf() * 24.0
                    if dc["name"] == "商务区":
                        h = 24.0 + rng.randf() * 20.0
                    elif dc["name"] == "大学城":
                        h = 12.0 + rng.randf() * 16.0
                    var kind: String = kinds[rng.randi_range(0, 3)]
                    if h > 27.0:
                        kind = "glass" if rng.randf() < 0.5 else "tower"
                    var mi := MeshInstance3D.new()
                    var bm := BoxMesh.new()
                    bm.size = Vector3(w, h, d)
                    mi.mesh = bm
                    mi.material_override = facades[kind]
                    mi.position = Vector3(wx, h / 2.0, wz)
                    mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
                    add_child(mi)
                    var slab := MeshInstance3D.new()
                    var sb := BoxMesh.new()
                    sb.size = Vector3(w + 0.35, 0.28, d + 0.35)
                    slab.mesh = sb
                    slab.material_override = roof_mat
                    slab.position = Vector3(wx, h + 0.1, wz)
                    slab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
                    add_child(slab)
                    if rng.randf() < 0.35:
                        var shed := MeshInstance3D.new()
                        var shb := BoxMesh.new()
                        shb.size = Vector3(2.4, 1.3, 2.4)
                        shed.mesh = shb
                        shed.material_override = tank_mat
                        shed.position = Vector3(wx + rng.randf_range(-3, 3), h + 0.85, wz + rng.randf_range(-3, 3))
                        shed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
                        add_child(shed)
                    var body := StaticBody3D.new()
                    var cs := CollisionShape3D.new()
                    var bs := BoxShape3D.new()
                    bs.size = Vector3(w, h, d)
                    cs.shape = bs
                    cs.position = Vector3(0, h / 2.0, 0)
                    body.add_child(cs)
                    body.position = Vector3(wx, 0, wz)
                    add_child(body)
                    buildings.append({"min_x": wx - w / 2.0, "max_x": wx + w / 2.0, "min_z": wz - d / 2.0, "max_z": wz + d / 2.0, "cx": wx, "cz": wz})
    _build_shops()
    _build_props()
    _build_light_poles()

func district_at(px: Vector2) -> Dictionary:
    # 入参为 px 空间坐标（3000x2100），内部换算到米再比最近片区
    var pm := Vector2(px.x / 5.0 - 300.0, px.y / 5.0 - 210.0)
    var best: Dictionary = DISTRICTS[0]
    var bd := 1e18
    for dc in DISTRICTS:
        var dd := Vector2(dc["x"], dc["z"]).distance_to(pm)
        if dd < bd:
            bd = dd
            best = dc
    return best

func _build_shops() -> void:
    var hut_mat := _std(Color(1.0, 0.71, 0.18))
    var roof_mat := _std(Color(0.85, 0.28, 0.23))
    for si in range(SHOP_POS.size()):
        var p: Vector2 = SHOP_POS[si]
        var hut := MeshInstance3D.new()
        var hb := BoxMesh.new()
        hb.size = Vector3(7, 3.4, 6)
        hut.mesh = hb
        hut.material_override = hut_mat
        hut.position = Vector3(p.x, 1.7, p.y)
        hut.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
        add_child(hut)
        var roof := MeshInstance3D.new()
        var cone := CylinderMesh.new()
        cone.top_radius = 0.0
        cone.bottom_radius = 5.6
        cone.height = 2.2
        cone.radial_segments = 4
        roof.mesh = cone
        roof.material_override = roof_mat
        roof.position = Vector3(p.x, 4.5, p.y)
        roof.rotation.y = PI / 4.0
        roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
        add_child(roof)
        var sign := MeshInstance3D.new()
        var q := QuadMesh.new()
        q.size = Vector2(6.4, 1.6)
        sign.mesh = q
        var smat := StandardMaterial3D.new()
        smat.albedo_texture = _tex("res://assets/sign_%d.png" % si)
        smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        smat.cull_mode = BaseMaterial3D.CULL_DISABLED
        sign.material_override = smat
        sign.position = Vector3(p.x - 3.9, 4.4, p.y)
        sign.rotation.y = -PI / 2.0
        add_child(sign)

func _build_props() -> void:
    # 行道树（MultiMesh）
    var spots: Array = []
    for bx in range(10):
        for by in range(7):
            for o in [[58, 58], [58, 242], [242, 58], [242, 242]]:
                if rng.randf() < 0.62:
                    spots.append(Vector2(bx * 300 + o[0] + rng.randf_range(-7, 7), by * 300 + o[1] + rng.randf_range(-7, 7)))
    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = 0.09
    trunk_mesh.bottom_radius = 0.14
    trunk_mesh.height = 1.2
    trunk_mesh.radial_segments = 6
    var leaf_mesh := SphereMesh.new()
    leaf_mesh.radius = 1.05
    leaf_mesh.height = 2.1
    leaf_mesh.radial_segments = 6
    leaf_mesh.rings = 3
    var trunk_mm := MultiMesh.new()
    trunk_mm.transform_format = MultiMesh.TRANSFORM_3D
    trunk_mm.mesh = trunk_mesh
    trunk_mm.instance_count = spots.size()
    var leaf_mm := MultiMesh.new()
    leaf_mm.transform_format = MultiMesh.TRANSFORM_3D
    leaf_mm.mesh = leaf_mesh
    leaf_mm.instance_count = spots.size()
    for i in range(spots.size()):
        var pm := Vector3(spots[i].x / 5.0 - 300.0, 0, spots[i].y / 5.0 - 210.0)
        var sc := 0.8 + rng.randf() * 0.6
        var basis := Basis(Vector3.UP, rng.randf() * 3.0).scaled(Vector3(sc, sc, sc))
        trunk_mm.set_instance_transform(i, Transform3D(basis, pm + Vector3(0, 0.6 * sc, 0)))
        leaf_mm.set_instance_transform(i, Transform3D(basis, pm + Vector3(0, 1.95 * sc, 0)))
    var tmi := MultiMeshInstance3D.new()
    tmi.multimesh = trunk_mm
    tmi.material_override = _std(Color(0.43, 0.3, 0.2))
    tmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    add_child(tmi)
    var lmi := MultiMeshInstance3D.new()
    lmi.multimesh = leaf_mm
    lmi.material_override = _std(Color(0.31, 0.49, 0.23))
    lmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    add_child(lmi)
    # 路灯（MultiMesh，黄昏发光材质）
    lamp_head_mat = StandardMaterial3D.new()
    lamp_head_mat.albedo_color = Color(0.6, 0.62, 0.55)
    lamp_head_mat.emission_enabled = true
    lamp_head_mat.emission = Color(1.0, 0.9, 0.65)
    lamp_head_mat.emission_energy_multiplier = 0.15
    var lamp_spots: Array = []
    for i in range(10):
        for j in range(7):
            if (i + j) % 2 == 0:
                lamp_spots.append(Vector2(i * 300 + 74, j * 300 - 8))
    var pole_mesh := CylinderMesh.new()
    pole_mesh.top_radius = 0.07
    pole_mesh.bottom_radius = 0.07
    pole_mesh.height = 4.8
    pole_mesh.radial_segments = 6
    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.17
    head_mesh.height = 0.34
    head_mesh.radial_segments = 8
    head_mesh.rings = 4
    var pole_mm := MultiMesh.new()
    pole_mm.transform_format = MultiMesh.TRANSFORM_3D
    pole_mm.mesh = pole_mesh
    pole_mm.instance_count = lamp_spots.size()
    var head_mm := MultiMesh.new()
    head_mm.transform_format = MultiMesh.TRANSFORM_3D
    head_mm.mesh = head_mesh
    head_mm.instance_count = lamp_spots.size()
    for i in range(lamp_spots.size()):
        var pm2 := Vector3(lamp_spots[i].x / 5.0 - 300.0, 0, lamp_spots[i].y / 5.0 - 210.0)
        pole_mm.set_instance_transform(i, Transform3D(Basis(), pm2 + Vector3(0, 2.4, 0)))
        head_mm.set_instance_transform(i, Transform3D(Basis(), pm2 + Vector3(0, 4.85, 0)))
    var pmi := MultiMeshInstance3D.new()
    pmi.multimesh = pole_mm
    pmi.material_override = _std(Color(0.24, 0.27, 0.31))
    add_child(pmi)
    var hmi := MultiMeshInstance3D.new()
    hmi.multimesh = head_mm
    hmi.material_override = lamp_head_mat
    add_child(hmi)

func _build_light_poles() -> void:
    var pole_mesh := CylinderMesh.new()
    pole_mesh.top_radius = 0.06
    pole_mesh.bottom_radius = 0.06
    pole_mesh.height = 4.4
    pole_mesh.radial_segments = 6
    var head_mesh := BoxMesh.new()
    head_mesh.size = Vector3(0.62, 0.3, 0.3)
    var sphere := SphereMesh.new()
    sphere.radius = 0.13
    sphere.height = 0.26
    sphere.radial_segments = 8
    sphere.rings = 4
    var n := 70
    var pole_mm := MultiMesh.new()
    pole_mm.transform_format = MultiMesh.TRANSFORM_3D
    pole_mm.mesh = pole_mesh
    pole_mm.instance_count = n
    var head_mm := MultiMesh.new()
    head_mm.transform_format = MultiMesh.TRANSFORM_3D
    head_mm.mesh = head_mesh
    head_mm.instance_count = n
    var ns_mm := MultiMesh.new()
    ns_mm.transform_format = MultiMesh.TRANSFORM_3D
    ns_mm.use_colors = true
    ns_mm.mesh = sphere
    ns_mm.instance_count = n
    var ew_mm := MultiMesh.new()
    ew_mm.transform_format = MultiMesh.TRANSFORM_3D
    ew_mm.use_colors = true
    ew_mm.mesh = sphere
    ew_mm.instance_count = n
    var idx := 0
    for k in range(10):
        for m in range(7):
            var cx: float = ROAD_X[k] + 8.4
            var cz: float = ROAD_Z[m] - 8.4
            pole_mm.set_instance_transform(idx, Transform3D(Basis(), Vector3(cx, 2.2, cz)))
            head_mm.set_instance_transform(idx, Transform3D(Basis(), Vector3(cx, 4.45, cz)))
            ns_mm.set_instance_transform(idx, Transform3D(Basis(), Vector3(cx - 0.17, 4.45, cz)))
            ew_mm.set_instance_transform(idx, Transform3D(Basis(), Vector3(cx + 0.17, 4.45, cz)))
            ns_mm.set_instance_color(idx, Color(1, 1, 1))
            ew_mm.set_instance_color(idx, Color(1, 1, 1))
            idx += 1
    var pmi := MultiMeshInstance3D.new()
    pmi.multimesh = pole_mm
    pmi.material_override = _std(Color(0.18, 0.22, 0.26))
    add_child(pmi)
    var hmi := MultiMeshInstance3D.new()
    hmi.multimesh = head_mm
    hmi.material_override = _std(Color(0.09, 0.11, 0.14))
    add_child(hmi)
    var lamp_mat := StandardMaterial3D.new()
    lamp_mat.albedo_color = Color.WHITE
    lamp_mat.vertex_color_use_as_albedo = true
    lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    lamp_ns = MultiMeshInstance3D.new()
    lamp_ns.multimesh = ns_mm
    lamp_ns.material_override = lamp_mat
    add_child(lamp_ns)
    lamp_ew = MultiMeshInstance3D.new()
    lamp_ew.multimesh = ew_mm
    lamp_ew.material_override = lamp_mat
    add_child(lamp_ew)

func light_for(axis: String) -> String:
    var ph := fmod(t, 22.0)
    if axis == "NS":
        return "g" if ph < 9.0 else ("y" if ph < 11.0 else "r")
    return "r" if ph < 11.0 else ("g" if ph < 20.0 else "y")

func refresh_lights() -> void:
    var key := light_for("NS") + light_for("EW")
    if key == last_light_key:
        return
    last_light_key = key
    var cns := Color(0.18, 0.88, 0.48) if light_for("NS") == "g" else (Color(1.0, 0.79, 0.24) if light_for("NS") == "y" else Color(1.0, 0.27, 0.27))
    var cew := Color(0.18, 0.88, 0.48) if light_for("EW") == "g" else (Color(1.0, 0.79, 0.24) if light_for("EW") == "y" else Color(1.0, 0.27, 0.27))
    for i in range(70):
        lamp_ns.multimesh.set_instance_color(i, cns)
        lamp_ew.multimesh.set_instance_color(i, cew)

# ---------------- 玩家 ----------------
func _build_player() -> void:
    player = PlayerScene.new()
    player.position = Vector3(0, 0.3, 0)
    add_child(player)
    cam = player.get_node("CamPivot").get_child(0) as Camera3D

# ---------------- AI 车流 ----------------
func make_car(c: Color) -> Node3D:
    var g := Node3D.new()
    var body_mi := MeshInstance3D.new()
    var bm := BoxMesh.new()
    bm.size = Vector3(1.8, 0.62, 4.3)
    body_mi.mesh = bm
    body_mi.material_override = _std(c)
    body_mi.position = Vector3(0, 0.55, 0)
    body_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    g.add_child(body_mi)
    var cab := MeshInstance3D.new()
    var cm := BoxMesh.new()
    cm.size = Vector3(1.55, 0.55, 2.1)
    cab.mesh = cm
    cab.material_override = _std(Color(0.13, 0.18, 0.25))
    cab.position = Vector3(0, 1.1, 0.2)
    cab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    g.add_child(cab)
    for off in [Vector2(-0.82, -1.45), Vector2(0.82, -1.45), Vector2(-0.82, 1.45), Vector2(0.82, 1.45)]:
        var w := MeshInstance3D.new()
        var wm := CylinderMesh.new()
        wm.top_radius = 0.34
        wm.bottom_radius = 0.34
        wm.height = 0.22
        wm.radial_segments = 12
        w.mesh = wm
        w.rotation.z = PI / 2.0
        w.material_override = _std(Color(0.1, 0.1, 0.12))
        w.position = Vector3(off.x, 0.34, off.y)
        g.add_child(w)
    var hl := MeshInstance3D.new()
    var hlb := BoxMesh.new()
    hlb.size = Vector3(1.4, 0.14, 0.06)
    hl.mesh = hlb
    var hlm := StandardMaterial3D.new()
    hlm.albedo_color = Color(1, 0.95, 0.7)
    hlm.emission_enabled = true
    hlm.emission = Color(1, 0.95, 0.7)
    hlm.emission_energy_multiplier = 0.7
    hl.material_override = hlm
    hl.position = Vector3(0, 0.6, -2.16)
    g.add_child(hl)
    add_child(g)
    return g

func car_lane(c: Dictionary) -> float:
    if c["vert"]:
        return c["line"] - 3.2 if c["dir"] > 0 else c["line"] + 3.2
    return c["line"] + 3.2 if c["dir"] > 0 else c["line"] - 3.2

func _build_traffic() -> void:
    var colors := [Color(0.91, 0.35, 0.33), Color(0.25, 0.5, 0.95), Color(0.94, 0.96, 0.97), Color(0.16, 0.18, 0.22), Color(0.98, 0.72, 0.19), Color(0.24, 0.72, 0.5), Color(0.8, 0.83, 0.88), Color(0.6, 0.36, 0.95)]
    for i in range(12):
        var vert := i % 2 == 0
        var line: float = (ROAD_X[rng.randi_range(1, 8)] if vert else ROAD_Z[rng.randi_range(1, 5)])
        var car := {
            "node": make_car(colors[i % colors.size()]),
            "vert": vert, "line": line,
            "dir": 1 if rng.randf() < 0.5 else -1,
            "pos": rng.randf_range(-180, 180), "spd": 0.0,
            "cruise": rng.randf_range(23.0, 33.0),
        }
        cars.append(car)
        _place_car(car)

func _place_car(c: Dictionary) -> void:
    var lane := car_lane(c)
    var n: Node3D = c["node"]
    if c["vert"]:
        n.position = Vector3(lane, 0, c["pos"])
        # 车头朝 -Z 建模：dir=+1 沿 +z 行驶需转 PI
        n.rotation.y = 0.0 if c["dir"] < 0 else PI
    else:
        n.position = Vector3(c["pos"], 0, lane)
        n.rotation.y = -PI / 2.0 if c["dir"] > 0 else PI / 2.0

func update_cars(delta: float) -> void:
    var pp := Vector2(player.global_position.x, player.global_position.z)
    for c in cars:
        var want: float = c["cruise"]
        var light_axis := "NS" if c["vert"] else "EW"
        var stop_line := 11.0
        var dist_stop := 1e9
        var centers: Array = ROAD_Z if c["vert"] else ROAD_X
        for cen in centers:
            var dd: float = (cen - c["pos"]) * c["dir"]
            if dd > 0.0 and dd < dist_stop:
                dist_stop = dd
        var st := light_for(light_axis)
        if dist_stop < stop_line + 26.0 and st != "g":
            want = 0.0 if dist_stop < stop_line + 13.0 else min(want, 10.0)
        var axis_pos := pp.y if c["vert"] else pp.x
        var side_pos := pp.x if c["vert"] else pp.y
        var ahead: float = (axis_pos - c["pos"]) * c["dir"] if abs(side_pos - car_lane(c)) < 2.6 else -1.0
        if ahead > 0.0 and ahead < 12.0:
            want = 0.0
        for o in cars:
            if o == c:
                continue
            if o["vert"] == c["vert"] and abs(o["line"] - c["line"]) < 0.5 and o["dir"] == c["dir"]:
                var gap: float = (o["pos"] - c["pos"]) * c["dir"]
                if gap > 0.0 and gap < 13.0:
                    want = min(want, max(0.0, o["spd"] - 2.0))
        c["spd"] = move_toward(c["spd"], want, (30.0 if want < c["spd"] else 13.0) * delta)
        c["pos"] += c["dir"] * c["spd"] * delta
        if c["pos"] > 216.0:
            c["pos"] = -216.0
        if c["pos"] < -216.0:
            c["pos"] = 216.0
        _place_car(c)
    # 碰撞（按朝向窄盒，会车不触发）
    if crash_cd > 0:
        crash_cd -= delta
    for c in cars:
        var n: Node3D = c["node"]
        var d := Vector2(pp.x - n.global_position.x, pp.y - n.global_position.z)
        var hit := false
        # 纵向车的长边在 z 轴：vert 车沿 z 排布，取 |dz| 为长边
        if c["vert"]:
            hit = abs(d.x) < 2.6 and abs(d.y) < 4.8
        else:
            hit = abs(d.x) < 4.8 and abs(d.y) < 2.6
        if hit and crash_cd <= 0.0 and abs(player.speed) > 3.0:
            crash_cd = 1.2
            player.speed *= -0.22
            rating = max(1.0, rating - 0.03)
            toast("撞上汽车了！评分 -0.03", "bad")
            burst(pp, Color(0.58, 0.64, 0.71))

# ---------------- 行人 ----------------
func make_ped(c: Color) -> Node3D:
    var g := Node3D.new()
    var body := MeshInstance3D.new()
    var bm := CylinderMesh.new()
    bm.top_radius = 0.17
    bm.bottom_radius = 0.21
    bm.height = 0.78
    bm.radial_segments = 8
    body.mesh = bm
    body.material_override = _std(c)
    body.position = Vector3(0, 0.72, 0)
    body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    g.add_child(body)
    var head := MeshInstance3D.new()
    var hs := SphereMesh.new()
    hs.radius = 0.16
    hs.height = 0.32
    hs.radial_segments = 10
    hs.rings = 5
    head.mesh = hs
    head.material_override = _std(Color(1.0, 0.84, 0.68))
    head.position = Vector3(0, 1.32, 0)
    head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    g.add_child(head)
    add_child(g)
    return g

func _build_peds() -> void:
    var cols := [Color(0.55, 0.76, 0.98), Color(0.98, 0.6, 0.74), Color(1.0, 1.0, 1.0), Color(0.55, 0.9, 0.7), Color(0.85, 0.72, 0.98), Color(0.24, 0.27, 0.33), Color(0.98, 0.85, 0.55)]
    for i in range(14):
        var bx := rng.randi_range(0, 9)
        var by := rng.randi_range(0, 6)
        peds.append({
            "node": make_ped(cols[i % cols.size()]),
            "ox": bx * 60.0 - 287.2, "oz": by * 60.0 - 197.2,  # 街区内环左上角（米）
            "s": rng.randf() * 156.0, "spd": rng.randf_range(2.4, 4.0),
            "dir": 1 if rng.randf() < 0.5 else -1,
            "off": Vector2.ZERO, "dodge_t": 0.0, "dodge_v": Vector2.ZERO,
            "phase": rng.randf() * 6.28,
        })

func ped_walk_pos(p: Dictionary) -> Vector2:
    # 沿街区人行道矩形内环行走：边长 39.2，总周长 156.8（s 已按 156 取模使用）
    var side := 39.2
    var ss: float = fmod(p["s"], side * 4.0)
    var lx := 0.0
    var lz := 0.0
    var hd := Vector2.RIGHT
    if ss < side:
        lx = ss
        hd = Vector2.RIGHT
    elif ss < side * 2.0:
        lx = side
        lz = ss - side
        hd = Vector2.DOWN
    elif ss < side * 3.0:
        lx = side - (ss - side * 2.0)
        lz = side
        hd = Vector2.LEFT
    else:
        lz = side - (ss - side * 3.0)
        hd = Vector2.UP
    return Vector2(p["ox"] + lx, p["oz"] + lz)

func update_peds(delta: float) -> void:
    var pp := Vector2(player.global_position.x, player.global_position.z)
    for p in peds:
        p["s"] += p["spd"] * p["dir"] * delta
        if p["s"] > 156.8:
            p["s"] -= 156.8
        if p["s"] < 0.0:
            p["s"] += 156.8
        var base := ped_walk_pos(p)
        var n: Node3D = p["node"]
        var cur := Vector2(n.global_position.x, n.global_position.z)
        var to_bike := cur - pp
        var dist := to_bike.length()
        if dist < 7.5 and dist > 0.01 and p["dodge_t"] <= 0.0:
            p["dodge_t"] = 0.8
            p["dodge_v"] = to_bike.normalized() * 2.4
        if p["dodge_t"] > 0.0:
            p["dodge_t"] -= delta
            p["off"] += p["dodge_v"] * delta
            p["dodge_v"] = p["dodge_v"].move_toward(Vector2.ZERO, 4.0 * delta)
        else:
            p["off"] = p["off"].move_toward(Vector2.ZERO, 2.2 * delta)
        var target: Vector2 = base + p["off"]
        n.position = Vector3(target.x, 0, target.y)
        n.position.y = abs(sin(t * 6.0 + p["phase"])) * 0.05
        # 撞人判定
        var d2 := Vector2(n.global_position.x, n.global_position.z) - pp
        if d2.length() < 2.6 and abs(player.speed) > 3.4 and crash_cd <= 0.0:
            crash_cd = 2.0
            for o in orders:
                if o["st"] == "picked" or o["st"] == "carry":
                    o["st"] = "gone"
            rating = max(1.0, rating - 0.3)
            player.speed = 0.0
            toast("撞到行人！手上的单全洒了", "bad")
            panel_sig = ""

# ---------------- 特效：光柱 / 雨 / 粒子 ----------------
func make_pillar(c: Color) -> Node3D:
    var g := Node3D.new()
    var beam := MeshInstance3D.new()
    var cm := CylinderMesh.new()
    cm.top_radius = 1.1
    cm.bottom_radius = 1.5
    cm.height = 42.0
    cm.radial_segments = 12
    beam.mesh = cm
    var bm := StandardMaterial3D.new()
    bm.albedo_color = Color(c.r, c.g, c.b, 0.3)
    bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    bm.no_depth_test = false
    beam.material_override = bm
    beam.position = Vector3(0, 21, 0)
    beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    g.add_child(beam)
    var ring := MeshInstance3D.new()
    var rm := CylinderMesh.new()
    rm.top_radius = 2.2
    rm.bottom_radius = 2.2
    rm.height = 0.08
    rm.radial_segments = 20
    ring.mesh = rm
    var rmat := StandardMaterial3D.new()
    rmat.albedo_color = c
    rmat.emission_enabled = true
    rmat.emission = c
    rmat.emission_energy_multiplier = 1.6
    ring.material_override = rmat
    ring.position = Vector3(0, 0.15, 0)
    ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    g.add_child(ring)
    g.visible = false
    add_child(g)
    return g

func burst(pos2: Vector2, c: Color) -> void:
    var p := GPUParticles3D.new()
    p.amount = 18
    p.one_shot = true
    p.explosiveness = 0.9
    p.lifetime = 0.7
    var pm := ParticleProcessMaterial.new()
    pm.direction = Vector3(0, 1, 0)
    pm.spread = 55.0
    pm.gravity = Vector3(0, -9, 0)
    pm.initial_velocity_min = 3.0
    pm.initial_velocity_max = 6.5
    var quad := QuadMesh.new()
    quad.size = Vector2(0.16, 0.16)
    var qm := StandardMaterial3D.new()
    qm.albedo_color = c
    qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    quad.material = qm
    p.draw_pass_1 = quad
    p.position = Vector3(pos2.x, 1.0, pos2.y)
    add_child(p)
    p.emitting = true
    get_tree().create_timer(1.2).timeout.connect(p.queue_free)

func _build_fx() -> void:
    pick_pillar = make_pillar(Color(0.22, 0.72, 0.97))
    deli_pillar = make_pillar(Color(0.2, 0.85, 0.6))
    rain_fx = GPUParticles3D.new()
    rain_fx.amount = 700
    rain_fx.lifetime = 0.85
    rain_fx.local_coords = false
    var pm := ParticleProcessMaterial.new()
    pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
    pm.emission_box_extents = Vector3(55, 16, 55)
    pm.direction = Vector3(0.12, -1, 0.08)
    pm.spread = 4.0
    pm.gravity = Vector3(0, -24, 0)
    pm.initial_velocity_min = 15.0
    pm.initial_velocity_max = 19.0
    rain_fx.process_material = pm
    var quad := QuadMesh.new()
    quad.size = Vector2(0.05, 0.75)
    var qm := StandardMaterial3D.new()
    qm.albedo_color = Color(0.68, 0.8, 0.94, 0.45)
    qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    quad.material = qm
    rain_fx.draw_pass_1 = quad
    rain_fx.emitting = false
    add_child(rain_fx)

# ---------------- 音频（程序合成） ----------------
func make_wav(samples: PackedByteArray, rate := 22050, loop := false) -> AudioStreamWAV:
    var w := AudioStreamWAV.new()
    w.format = AudioStreamWAV.FORMAT_16_BITS
    w.mix_rate = rate
    w.stereo = false
    w.data = samples
    if loop:
        w.loop_mode = AudioStreamWAV.LOOP_FORWARD
        w.loop_begin = 0
        w.loop_end = samples.size() / 2
    return w

func tone_seq(notes: Array, note_dur := 0.09, vol := 0.4) -> AudioStreamWAV:
    var rate := 22050
    var data := PackedByteArray()
    for f in notes:
        var n := int(rate * note_dur)
        for i in range(n):
            var v := sin(TAU * f * i / rate) * vol * (1.0 - float(i) / n * 0.4)
            var s := int(clamp(v, -1.0, 1.0) * 32767.0)
            data.append(s & 0xff)
            data.append((s >> 8) & 0xff)
    return make_wav(data)

func _build_audio() -> void:
    sfx_players["new"] = _mk_player(tone_seq([880.0, 1174.0], 0.08))
    sfx_players["pick"] = _mk_player(tone_seq([660.0, 990.0], 0.07))
    sfx_players["done"] = _mk_player(tone_seq([523.0, 659.0, 784.0, 1046.0], 0.09))
    sfx_players["late"] = _mk_player(tone_seq([392.0, 330.0], 0.12))
    sfx_players["day"] = _mk_player(tone_seq([523.0, 659.0, 784.0, 1046.0, 1318.0], 0.11))
    # 引擎循环：0.6s 锯齿
    var rate := 22050
    var data := PackedByteArray()
    var n := int(rate * 0.6)
    for i in range(n):
        var ph := fmod(55.0 * i / rate, 1.0)
        var v := (ph * 2.0 - 1.0) * 0.3 + sin(TAU * 110.0 * i / rate) * 0.12
        var s := int(clamp(v, -1.0, 1.0) * 32767.0)
        data.append(s & 0xff)
        data.append((s >> 8) & 0xff)
    eng_player = _mk_player(make_wav(data, rate, true))
    eng_player.volume_db = -60.0

func _mk_player(stream: AudioStream) -> AudioStreamPlayer:
    var p := AudioStreamPlayer.new()
    p.stream = stream
    add_child(p)
    return p

func sfx(sname: String) -> void:
    if muted:
        return
    if sfx_players.has(sname):
        (sfx_players[sname] as AudioStreamPlayer).play()

# ---------------- HUD ----------------
func pill_style(bg: Color) -> StyleBoxFlat:
    var s := StyleBoxFlat.new()
    s.bg_color = bg
    s.corner_radius_top_left = 10
    s.corner_radius_top_right = 10
    s.corner_radius_bottom_left = 10
    s.corner_radius_bottom_right = 10
    s.content_margin_left = 12
    s.content_margin_right = 12
    s.content_margin_top = 6
    s.content_margin_bottom = 6
    return s

func mk_label(text: String, size := 15, color := Color(0.92, 0.95, 1.0)) -> Label:
    var l := Label.new()
    l.text = text
    l.add_theme_font_size_override("font_size", size)
    l.add_theme_color_override("font_color", color)
    return l

var muted := false
var ui_theme: Theme

func _build_hud() -> void:
    var layer := CanvasLayer.new()
    add_child(layer)
    var font_res = load("res://assets/font.ttc")
    ui_theme = Theme.new()
    if font_res:
        ui_theme.default_font = font_res
    ui_theme.default_font_size = 15
    layer.add_child(_mk_ui_root(ui_theme))

func _mk_ui_root(theme: Theme) -> Control:
    var root := Control.new()
    root.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.theme = theme
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    # 顶栏
    var top := PanelContainer.new()
    top.set_anchors_preset(Control.PRESET_TOP_WIDE)
    top.add_theme_stylebox_override("panel", pill_style(Color(0.05, 0.09, 0.16, 0.72)))
    var hb := HBoxContainer.new()
    hb.add_theme_constant_override("separation", 22)
    ui_day = mk_label("第 1 天 · 08:00", 15)
    ui_wx = mk_label("☀️ 晴", 15)
    ui_money = mk_label("收益 ¥0.0", 15, Color(1.0, 0.83, 0.29))
    ui_rating = mk_label("评分 ★5.0", 15, Color(1.0, 0.83, 0.29))
    ui_goal = mk_label("目标 ¥260", 15)
    var snd := mk_label("声音：开（M 静音）", 14, Color(0.7, 0.78, 0.9))
    for l in [ui_day, ui_wx, ui_money, ui_rating, ui_goal, snd]:
        hb.add_child(l)
    top.add_child(hb)
    root.add_child(top)
    # 订单面板
    var panel := PanelContainer.new()
    panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    panel.position = Vector2(-322, 52)
    panel.custom_minimum_size = Vector2(312, 0)
    panel.add_theme_stylebox_override("panel", pill_style(Color(0.05, 0.09, 0.16, 0.78)))
    panel_box = VBoxContainer.new()
    panel_box.add_theme_constant_override("separation", 8)
    panel.add_child(panel_box)
    root.add_child(panel)
    # toast
    toast_box = VBoxContainer.new()
    toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
    toast_box.position = Vector2(-200, 64)
    toast_box.custom_minimum_size = Vector2(400, 0)
    toast_box.alignment = BoxContainer.ALIGNMENT_CENTER
    root.add_child(toast_box)
    # 导航
    nav_box = VBoxContainer.new()
    nav_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
    nav_box.position = Vector2(-120, -128)
    nav_box.custom_minimum_size = Vector2(240, 0)
    nav_box.alignment = BoxContainer.ALIGNMENT_CENTER
    nav_arrow = mk_label("⬆", 40, Color(1.0, 0.83, 0.29))
    nav_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    nav_arrow.pivot_offset = Vector2(120, 28)
    nav_text = mk_label("", 16, Color(1.0, 0.95, 0.85))
    nav_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    nav_box.add_child(nav_arrow)
    nav_box.add_child(nav_text)
    root.add_child(nav_box)
    # 速度
    speed_label = mk_label("0", 34, Color(1.0, 0.83, 0.29))
    speed_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    speed_label.position = Vector2(-90, -86)
    root.add_child(speed_label)
    var kmh := mk_label("km/h", 12, Color(0.75, 0.82, 0.95))
    kmh.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    kmh.position = Vector2(-86, -42)
    root.add_child(kmh)
    # 小地图
    minimap = MinimapScript.new()
    minimap.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
    minimap.position = Vector2(12, -144)
    minimap.shops = SHOP_POS.duplicate()
    root.add_child(minimap)
    return root

func toast(msg: String, kind := "") -> void:
    var l := mk_label(msg, 15)
    var bg := Color(0.1, 0.14, 0.22, 0.92)
    if kind == "bad":
        bg = Color(0.45, 0.12, 0.12, 0.94)
    elif kind == "good":
        bg = Color(0.08, 0.35, 0.2, 0.94)
    var pc := PanelContainer.new()
    pc.add_theme_stylebox_override("panel", pill_style(bg))
    pc.add_child(l)
    toast_box.add_child(pc)
    var tw := create_tween()
    tw.tween_interval(2.3)
    tw.tween_property(pc, "modulate:a", 0.0, 0.6)
    tw.tween_callback(pc.queue_free)

func _build_overlays() -> void:
    var layer := CanvasLayer.new()
    layer.layer = 5
    add_child(layer)
    start_overlay = _mk_overlay(layer, "送外卖模拟器 · Godot 版", "临江市 · 3D 全景街区，骑手的一天从 8:00 开始。\n抢单 → 到店取餐（等出餐）→ 送到顾客楼下。\n准时全额，超时 7 折；红灯别闯——黄昏后罚款照扣，撞车撞人更贵。\n\n操作：W 油门 · S 刹车/倒车 · A/D 转向 · 跟着金色箭头和光柱走\n小地图左下角，黄点是你，金点是餐馆。", "上线开跑")
    (start_overlay.get_meta("btn") as Button).pressed.connect(start_game)
    day_overlay = _mk_overlay(layer, "", "", "开始新一天")
    day_title = day_overlay.get_meta("title")
    day_stats = day_overlay.get_meta("desc")
    day_comment = day_overlay.get_meta("comment")
    (day_overlay.get_meta("btn") as Button).pressed.connect(func() -> void:
        day += 1
        day_overlay.visible = false
        (day_overlay.get_meta("dim") as ColorRect).visible = false
        new_day()
        running = true
        over = false
    )
    day_overlay.visible = false
    (day_overlay.get_meta("dim") as ColorRect).visible = false

func _mk_overlay(layer: CanvasLayer, title: String, desc: String, btn_text: String) -> CenterContainer:
    var cc := CenterContainer.new()
    cc.set_anchors_preset(Control.PRESET_FULL_RECT)
    if ui_theme:
        cc.theme = ui_theme
    var dim := ColorRect.new()
    dim.color = Color(0.04, 0.07, 0.12, 0.66)
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    layer.add_child(dim)
    cc.set_meta("dim", dim)
    var pc := PanelContainer.new()
    pc.add_theme_stylebox_override("panel", pill_style(Color(0.07, 0.11, 0.19, 0.97)))
    var vb := VBoxContainer.new()
    vb.add_theme_constant_override("separation", 12)
    var tl := mk_label(title, 26, Color(1.0, 0.95, 0.85))
    vb.add_child(tl)
    var dl := mk_label(desc, 15, Color(0.85, 0.9, 1.0))
    vb.add_child(dl)
    var cm := mk_label("", 15, Color(1.0, 0.83, 0.29))
    vb.add_child(cm)
    var btn := Button.new()
    btn.text = btn_text
    btn.add_theme_font_size_override("font_size", 18)
    vb.add_child(btn)
    pc.add_child(vb)
    cc.add_child(pc)
    layer.add_child(cc)
    cc.set_meta("title", tl)
    cc.set_meta("desc", dl)
    cc.set_meta("comment", cm)
    cc.set_meta("btn", btn)
    return cc

func start_game() -> void:
    start_overlay.visible = false
    (start_overlay.get_meta("dim") as ColorRect).visible = false
    (day_overlay.get_meta("dim") as ColorRect).visible = false
    running = true
    eng_player.play()

# ---------------- 游戏流程 ----------------
func new_day() -> void:
    t = 0.0
    money = 0.0
    rating = 5.0
    done_c = 0
    ontime_c = 0
    late_c = 0
    combo = 0
    best_combo = 0
    fines = 0
    orders.clear()
    spawn_t = 1.2
    in_light_zone = false
    crash_cd = 0.0
    weather = WXLIST[rng.randi_range(0, WXLIST.size() - 1)] if day > 1 or rng.randf() < 0.9 else WXLIST[0]
    if rng.randf() < 0.35:
        weather = WXLIST[0]
    player.position = Vector3(0, 0.3, 0)
    player.heading = 0.0
    player.speed = 0.0
    player.weather_mult = weather["sp"]
    rain_fx.emitting = weather["n"] == "小雨"
    panel_sig = ""
    refresh_panel()

func end_day() -> void:
    over = true
    running = false
    var gross := money
    money -= fines
    player.bot_gas = 0
    sfx("day")
    eng_player.stop()
    var reach := money >= DAY_GOAL
    day_title.text = ("第 %d 天完成！达成 ¥260 目标" % day) if reach else ("第 %d 天收工，差目标还差一点" % day)
    day_stats.text = "总单 %d · 准时 %d · 超时 %d · 最高连单 %d\n毛收入 ¥%.1f · 违章罚款 -¥%d · 实收 ¥%.1f · 评分 ★%.1f" % [done_c, ontime_c, late_c, best_combo, gross, fines, money, rating]
    day_comment.text = "手速和路线都不错，明天可以试试连抢两单。" if reach else "优先接近单、出餐空档先规划下一单，罚款最伤。"
    day_overlay.visible = true
    (day_overlay.get_meta("dim") as ColorRect).visible = true
    if qa_mode:
        print("QA DAY END done=", done_c, " money=", snappedf(money, 0.1))

func spawn_order() -> void:
    var si := rng.randi_range(0, SHOP_POS.size() - 1)
    var shop: Vector2 = SHOP_POS[si]
    var b: Dictionary = buildings[rng.randi_range(0, buildings.size() - 1)]
    var cust := Vector2(b["cx"] + rng.randf_range(-3.2, 3.2), b["max_z"] + 5.2)
    var pp := Vector2(player.global_position.x, player.global_position.z)
    var d1 := pp.distance_to(shop)
    var d2 := shop.distance_to(cust)
    var price := 6.0 + d2 / 17.0 + rng.randf() * 3.0
    var bonus := 0.0
    var tag := ""
    var roll := rng.randf()
    if roll < 0.16:
        tag = "奖励单"
        bonus = rng.randf_range(3.0, 7.0)
    elif roll < 0.32:
        tag = "转单"
        price *= 1.15
    elif roll < 0.42:
        tag = "跑腿单"
        price *= 1.3
    price *= 1.0 + weather["bonus"]
    var tag_txt := tag if tag != "" else "普通单"
    if bonus > 0.0:
        tag_txt += " · 奖励¥%.0f" % bonus
    orders.append({
        "id": oid, "shop": si, "cust": cust, "d1": d1, "d2": d2,
        "price": price, "bonus": bonus, "tag": tag_txt, "st": "pool",
        "born": t, "prep": 0.0, "picked_at": 0.0, "limit": (d1 + d2) / 53.0 * 2.1 + 32.0,
    })
    oid += 1
    sfx("new")

func grab(id: int) -> void:
    for o in orders:
        if o["id"] == id and o["st"] == "pool":
            o["st"] = "carry"
            o["prep"] = rng.randf_range(5.0, 12.0)
            toast("已接单：%s，先去取餐" % SHOP_NAMES[o["shop"]])
            panel_sig = ""
            return

func primary_order() -> Dictionary:
    for o in orders:
        if o["st"] == "picked":
            return o
    for o in orders:
        if o["st"] == "carry":
            return o
    return {}

func interactions() -> void:
    var pp := Vector2(player.global_position.x, player.global_position.z)
    for o in orders:
        if o["st"] == "carry":
            var sp: Vector2 = SHOP_POS[o["shop"]]
            if pp.distance_to(sp) < 14.0:
                if o["prep"] > 0.0:
                    o["prep"] -= get_physics_process_delta_time()
                    if o["prep"] <= 0.0:
                        o["st"] = "picked"
                        o["picked_at"] = t
                        sfx("pick")
                        toast("出餐了！送往顾客处，别超时", "good")
                        burst(sp, Color(0.22, 0.72, 0.97))
                        panel_sig = ""
                else:
                    o["prep"] = 0.01
        elif o["st"] == "picked":
            if pp.distance_to(o["cust"]) < 14.0:
                var used: float = t - o["picked_at"]
                var late: bool = used > o["limit"]
                var earn: float = o["price"] * (0.7 if late else 1.0) + (0.0 if late else o["bonus"])
                money += earn
                done_c += 1
                var cpos: Vector2 = o["cust"]
                if late:
                    late_c += 1
                    combo = 0
                    rating = max(1.0, rating - 0.08)
                    sfx("late")
                    toast("超时送达，实得 ¥%.1f（7 折）" % earn, "bad")
                    burst(cpos, Color(0.97, 0.44, 0.44))
                else:
                    ontime_c += 1
                    combo += 1
                    best_combo = max(best_combo, combo)
                    rating = min(5.0, rating + 0.02)
                    sfx("done")
                    toast("准时送达 +¥%.1f%s" % [earn, "（连单 x%d）" % combo if combo >= 2 else ""], "good")
                    burst(cpos, Color(1.0, 0.83, 0.29))
                o["st"] = "gone"
                panel_sig = ""

func check_traffic() -> void:
    var pp := Vector2(player.global_position.x, player.global_position.z)
    var inside := false
    var axis := ""
    for rx in ROAD_X:
        for rz in ROAD_Z:
            if abs(pp.x - rx) < 9.2 and abs(pp.y - rz) < 9.2:
                inside = true
                var f: Vector3 = player.forward_vec()
                axis = "NS" if abs(f.x) < abs(f.z) else "EW"
    if inside and not in_light_zone:
        in_light_zone = true
        if axis != "" and light_for(axis) == "r" and abs(player.speed) > 1.0:
            fines += 10
            rating = max(1.0, rating - 0.04)
            toast("闯红灯！日结罚款 ¥10", "bad")
    elif not inside:
        in_light_zone = false

# ---------------- 主循环 ----------------
func _physics_process(delta: float) -> void:
    if qa_mode:
        qa_tick(delta)
    if not running or over:
        return
    t += delta
    if t >= DAY_SECONDS:
        end_day()
        return
    spawn_t -= delta
    var pool_n := 0
    var active_n := 0
    for o in orders:
        if o["st"] == "pool":
            pool_n += 1
        elif o["st"] == "carry" or o["st"] == "picked":
            active_n += 1
    if spawn_t <= 0.0:
        spawn_t = rng.randf_range(3.5, 6.5)
        if online and pool_n < 6:
            spawn_order()
            panel_sig = ""
    orders = orders.filter(func(o: Dictionary) -> bool:
        if o["st"] == "gone":
            return false
        if o["st"] == "pool" and t - o["born"] > 45.0:
            return false
        return true
    )
    if panel_sig == "":
        pass
    update_cars(delta)
    update_peds(delta)
    check_traffic()
    interactions()

func _process(delta: float) -> void:
    refresh_lights()
    _update_sky()
    _update_fx()
    hud_tick -= delta
    if hud_tick <= 0.0:
        hud_tick = 0.15
        _refresh_topbar()
        refresh_panel()
        _feed_minimap()
    _update_nav()
    _update_engine_audio()
    if qa_mode:
        qa_process()

func _update_sky() -> void:
    var frac: float = clamp(t / DAY_SECONDS, 0.0, 1.0)
    var dusk: float = clamp((frac - 0.45) / 0.25, 0.0, 1.0)
    var night: float = clamp((frac - 0.78) / 0.2, 0.0, 1.0)
    sky_mat.sky_top_color = Color(0.35, 0.55, 0.85).lerp(Color(0.13, 0.16, 0.31), night).lerp(Color(0.45, 0.4, 0.6), dusk * 0.5)
    sky_mat.sky_horizon_color = Color(0.78, 0.87, 0.96).lerp(Color(0.98, 0.6, 0.36), dusk).lerp(Color(0.25, 0.27, 0.42), night)
    sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
    sun.light_energy = lerpf(1.12, 0.2, night) - dusk * 0.25
    sun.light_color = Color(1.0, 0.95, 0.85).lerp(Color(1.0, 0.6, 0.4), dusk).lerp(Color(0.65, 0.72, 0.95), night)
    sun.rotation_degrees.x = lerpf(-52.0, -18.0, frac)
    env.ambient_light_energy = lerpf(0.85, 0.35, night)
    env.fog_light_color = sky_mat.sky_horizon_color
    lamp_head_mat.emission_energy_multiplier = lerpf(0.15, 2.4, max(dusk, night))
    player.set_dusk_light(lerpf(0.0, 2.6, max(dusk, night)))

func _update_fx() -> void:
    var po := primary_order()
    var pp: Vector3 = player.global_position
    rain_fx.position = Vector3(pp.x, 16.0, pp.z)
    if po.is_empty():
        pick_pillar.visible = false
        deli_pillar.visible = false
        return
    if po["st"] == "carry":
        var sp: Vector2 = SHOP_POS[po["shop"]]
        pick_pillar.visible = true
        pick_pillar.position = Vector3(sp.x, 0, sp.y)
        deli_pillar.visible = false
    elif po["st"] == "picked":
        pick_pillar.visible = false
        deli_pillar.visible = true
        var cp: Vector2 = po["cust"]
        deli_pillar.position = Vector3(cp.x, 0, cp.y)

func _refresh_topbar() -> void:
    var clock_min := 8.0 * 60.0 + (t / DAY_SECONDS) * 14.0 * 60.0
    var hh := int(clock_min) / 60
    var mm := int(clock_min) % 60
    ui_day.text = "第 %d 天 · %02d:%02d" % [day, hh, mm]
    ui_wx.text = "%s · 激励+%d%%" % [weather["n"], int(weather["bonus"] * 100.0)]
    ui_money.text = "收益 ¥%.1f" % money
    ui_rating.text = "评分 ★%.1f" % rating
    ui_goal.text = "目标 ¥260"
    speed_label.text = str(int(abs(player.speed) * 2.0))

func refresh_panel() -> void:
    if not running and not over:
        pass
    var sig := ""
    for o in orders:
        sig += "%d:%s:%.0f;" % [o["id"], o["st"], (o["prep"] if o["st"] == "carry" else (o["picked_at"] + o["limit"] - t if o["st"] == "picked" else 45.0 - (t - o["born"])))]
    if sig == panel_sig and panel_box.get_child_count() > 0:
        return
    panel_sig = sig
    for ch in panel_box.get_children():
        ch.queue_free()
    var act := orders.filter(func(o: Dictionary) -> bool: return o["st"] == "carry" or o["st"] == "picked")
    var pool := orders.filter(func(o: Dictionary) -> bool: return o["st"] == "pool")
    var title := mk_label("进行中 %d/3" % act.size(), 14, Color(0.7, 0.78, 0.9))
    panel_box.add_child(title)
    for o in act:
        panel_box.add_child(_order_card(o, false))
    var t2 := mk_label("新任务 %d" % pool.size(), 14, Color(0.7, 0.78, 0.9))
    panel_box.add_child(t2)
    var shown := 0
    for o in pool:
        if shown >= 3:
            break
        shown += 1
        panel_box.add_child(_order_card(o, act.size() < 3))

func _order_card(o: Dictionary, can_grab: bool) -> PanelContainer:
    var pc := PanelContainer.new()
    pc.add_theme_stylebox_override("panel", pill_style(Color(1, 1, 1, 0.06)))
    var vb := VBoxContainer.new()
    vb.add_theme_constant_override("separation", 3)
    var head := HBoxContainer.new()
    var nm := mk_label(SHOP_NAMES[o["shop"]], 15)
    nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    head.add_child(nm)
    head.add_child(mk_label("¥%.1f" % o["price"], 16, Color(1.0, 0.45, 0.4)))
    vb.add_child(head)
    var meta := ""
    if o["st"] == "pool":
        meta = "%s · 取餐 %.1fkm · 送餐 %.1fkm" % [o["tag"], o["d1"] / 200.0, o["d2"] / 200.0]
    elif o["st"] == "carry":
        meta = "等出餐 %.0fs · 送餐 %.1fkm" % [max(0.0, o["prep"]), o["d2"] / 200.0] if o["prep"] > 0.0 else "已出餐，去取！"
    elif o["st"] == "picked":
        var left: float = o["picked_at"] + o["limit"] - t
        meta = "剩余 %.0fs · 距顾客 %.1fkm" % [left, Vector2(player.global_position.x, player.global_position.z).distance_to(o["cust"]) / 200.0]
    vb.add_child(mk_label(meta, 13, Color(0.78, 0.84, 0.95)))
    if o["st"] == "pool":
        var btn := Button.new()
        btn.text = "抢 单" if can_grab else "进行中已满 3 单"
        btn.disabled = not can_grab
        var oid_copy: int = o["id"]
        btn.pressed.connect(func() -> void: grab(oid_copy))
        vb.add_child(btn)
    pc.add_child(vb)
    return pc

func _feed_minimap() -> void:
    if minimap == null:
        return
    minimap.player_pos = Vector2(player.global_position.x, player.global_position.z)
    var po := primary_order()
    if po.is_empty():
        minimap.has_target = false
    else:
        minimap.has_target = true
        minimap.target_is_deli = po["st"] == "picked"
        minimap.target_pos = po["cust"] if po["st"] == "picked" else SHOP_POS[po["shop"]]
    minimap.queue_redraw()

func _update_nav() -> void:
    var po := primary_order()
    if po.is_empty() or not running:
        nav_box.visible = false
        return
    nav_box.visible = true
    var tp: Vector2 = po["cust"] if po["st"] == "picked" else SHOP_POS[po["shop"]]
    var pp := Vector2(player.global_position.x, player.global_position.z)
    var d := tp - pp
    var dist := d.length()
    var label := "送餐" if po["st"] == "picked" else "取餐"
    if po["st"] == "carry" and o_prep_left(po) > 0.0:
        label = "等出餐"
    nav_text.text = "%s · %s · %.2f km" % [label, SHOP_NAMES[po["shop"]] if po["st"] != "picked" else "顾客", dist / 200.0]
    var desired := atan2(-d.x, -d.y)
    var rel := wrapf(desired - player.heading, -PI, PI)
    nav_arrow.rotation = -rel

func o_prep_left(o: Dictionary) -> float:
    return o["prep"] if o["st"] == "carry" else 0.0

func _update_engine_audio() -> void:
    if muted:
        eng_player.volume_db = -60.0
        return
    if running and not over:
        if not eng_player.playing:
            eng_player.play()
        var sp: float = abs(player.speed)
        eng_player.pitch_scale = 0.85 + sp * 0.03
        eng_player.volume_db = -30.0 + min(9.0, sp * 0.32)
    else:
        eng_player.volume_db = -60.0

func _input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo:
        if (event as InputEventKey).keycode == KEY_M:
            muted = not muted
            toast("已静音" if muted else "声音开")

func sfx_muted_guard() -> bool:
    return muted

# ---------------- QA 自动驾驶（--qa） ----------------
var qa_escape_dir := 1
var qa_need_shot := ""
var qa_busy := false
var qa_finish := ""
var qa_wall0 := 0

func near_road(v: float, centers: Array) -> float:
    var best: float = centers[0]
    var bd := 1e18
    for c in centers:
        if abs(v - c) < bd:
            bd = abs(v - c)
            best = c
    return best

func qa_plan(target: Vector2, is_door: bool) -> void:
    qa_wps.clear()
    var pp := Vector2(player.global_position.x, player.global_position.z)
    var rx := near_road(pp.x, ROAD_X)
    if not is_door:
        qa_wps.append(Vector2(rx, pp.y))
        qa_wps.append(Vector2(rx, target.y))
    else:
        var ry_s := 1e9
        for c in ROAD_Z:
            if c >= target.y - 1.0:
                ry_s = c
                break
        if ry_s > 9000.0:
            qa_wps.append(Vector2(rx, pp.y))
            qa_wps.append(Vector2(rx, 204.0))
            qa_wps.append(Vector2(target.x, 204.0))
        else:
            qa_wps.append(Vector2(rx, pp.y))
            qa_wps.append(Vector2(rx, ry_s))
            qa_wps.append(Vector2(target.x, ry_s))
    qa_wp_i = 0
    qa_best_d = 1e9
    qa_best_t = t

func qa_current_target() -> Array:
    var po := primary_order()
    if po.is_empty():
        return []
    if po["st"] == "carry":
        return ["shop:%d" % po["id"], SHOP_POS[po["shop"]], false]
    return ["cust:%d" % po["id"], po["cust"], true]

func qa_tick(delta: float) -> void:
    if over or not running:
        player.bot_gas = 0
        return
    var act := qa_current_target()
    if act.is_empty():
        player.bot_gas = 0
        player.bot_steer = 0
        qa_target_key = ""
        qa_waited += delta
        var pool := orders.filter(func(o: Dictionary) -> bool: return o["st"] == "pool")
        if not pool.is_empty():
            var best_o: Dictionary = pool[0]
            var bd := 1e18
            for o in pool:
                var dd: float = o["d1"] + o["d2"]
                if dd < bd:
                    bd = dd
                    best_o = o
            if bd < 260.0 or qa_waited > 45.0:
                print("QA grab order ", best_o["id"], " shop ", SHOP_NAMES[best_o["shop"]])
                grab(best_o["id"])
                qa_waited = 0.0
        return
    var key: String = act[0]
    var target: Vector2 = act[1]
    var is_door: bool = act[2]
    if key != qa_target_key:
        qa_target_key = key
        qa_plan(target, is_door)
        print("QA plan -> ", key, " target ", target, " wps ", qa_wps.size())
    var pp := Vector2(player.global_position.x, player.global_position.z)
    # 逃逸（卡住时倒车打方向）
    if qa_escape > 0.0:
        qa_escape -= delta
        player.bot_gas = -1
        player.bot_steer = qa_escape_dir
        return
    var goal := target
    if qa_wp_i < qa_wps.size():
        goal = qa_wps[qa_wp_i]
        if pp.distance_to(goal) < 6.0:
            qa_wp_i += 1
            goal = qa_wps[qa_wp_i] if qa_wp_i < qa_wps.size() else target
    var d := goal - pp
    var desired := atan2(-d.x, -d.y)
    var diff := wrapf(desired - player.heading, -PI, PI)
    var steer := 0
    if diff > 0.06:
        steer = 1
    elif diff < -0.06:
        steer = -1
    player.bot_steer = steer
    player.bot_gas = 1 if abs(diff) < 2.1 else -1
    if qa_wp_i >= qa_wps.size() and pp.distance_to(target) < 22.0 and abs(player.speed) > 13.0:
        player.bot_gas = 0
    # 进展检测
    var fd := pp.distance_to(target)
    if fd < qa_best_d - 4.0:
        qa_best_d = fd
        qa_best_t = t
    elif t - qa_best_t > 6.0 and fd > 18.0:
        qa_best_t = t
        qa_escape = 1.4
        qa_escape_dir = -steer if steer != 0 else 1
        qa_plan(target, is_door)

func snap(path: String) -> void:
    await RenderingServer.frame_post_draw
    var img := get_viewport().get_texture().get_image()
    var err := img.save_png(ProjectSettings.globalize_path(path))
    print("SHOT ", path, " err=", err)

func qa_process() -> void:
    if qa_wall0 == 0:
        qa_wall0 = Time.get_ticks_msec()
    if t - qa_print_t >= 5.0:
        qa_print_t = t
        var po := primary_order()
        print("QA t=%.0f done=%d money=%.1f phase=%s pos=(%.0f,%.0f) fines=%d" % [t, done_c, money, (po["st"] if not po.is_empty() else "-"), player.global_position.x, player.global_position.z, fines])
    if not qa_shot_street and t > 3.5:
        qa_shot_street = true
        snap("res://qa/shot-street.png")
    var po2 := primary_order()
    if not qa_shot_deli and not po2.is_empty() and po2["st"] == "picked":
        qa_shot_deli = true
        snap("res://qa/shot-deliver.png")
    if qa_finish == "" and done_c >= 1:
        qa_finish = "pass"
    if qa_finish == "" and (over or t > DAY_SECONDS - 25.0 or Time.get_ticks_msec() - qa_wall0 > 500000):
        qa_finish = "fail"
    if qa_finish != "" and not qa_busy:
        qa_busy = true
        _qa_finalize()

func _qa_finalize() -> void:
    await snap("res://qa/shot-after.png")
    if qa_finish == "pass":
        print("QA PASS done=%d money=%.1f" % [done_c, money])
        get_tree().quit(0)
    else:
        print("QA FAIL done=%d money=%.1f" % [done_c, money])
        get_tree().quit(2)
