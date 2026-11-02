extends CharacterBody3D
# 电动车骑手：街机物理（油门/刹车/转向），mesh 与相机各自平滑跟随 heading
# 机器人模式（QA）：bot_gas/bot_steer 由 main.gd 的自动驾驶写入

var heading: float = 0.0            # 弧度，0 = 朝 -Z（北）
var speed: float = 0.0              # m/s（手感速度）
var max_speed: float = 30.0
var accel: float = 17.0
var weather_mult: float = 1.0
var bot_mode: bool = false
var bot_gas: int = 0                # 1 油门 -1 刹车/倒车 0 无
var bot_steer: int = 0              # 1 左 -1 右

var mesh: Node3D
var wheel_f: Node3D
var wheel_r: Node3D
var cam_pivot: Node3D
var headlight: SpotLight3D

func _ready() -> void:
    mesh = Node3D.new()
    add_child(mesh)
    _build_bike()
    # 碰撞体
    var body := CollisionShape3D.new()
    var cap := CapsuleShape3D.new()
    cap.radius = 0.42
    cap.height = 1.5
    body.shape = cap
    body.position.y = 0.75
    add_child(body)
    # 相机枢轴（与本体同位，独立平滑转向）
    cam_pivot = Node3D.new()
    cam_pivot.name = "CamPivot"
    add_child(cam_pivot)
    var cam := Camera3D.new()
    cam.position = Vector3(0, 4.7, 11.2)
    cam_pivot.add_child(cam)
    cam.look_at_from_position(cam.position, Vector3(0, 1.1, -8), Vector3.UP)
    cam.fov = 62.0
    headlight = SpotLight3D.new()
    headlight.position = Vector3(0, 0.95, -1.0)
    headlight.spot_range = 34.0
    headlight.spot_angle = 26.0
    headlight.light_energy = 0.0
    headlight.light_color = Color(1.0, 0.93, 0.76)
    mesh.add_child(headlight)
    var hl_target := Node3D.new()
    hl_target.position = Vector3(0, 0, -12)
    mesh.add_child(hl_target)
    headlight.look_at_from_position(headlight.position, hl_target.position, Vector3.UP)

func _mat(c: Color) -> StandardMaterial3D:
    var m := StandardMaterial3D.new()
    m.albedo_color = c
    return m

func _box(parent: Node, size: Vector3, c: Color, pos: Vector3) -> MeshInstance3D:
    var mi := MeshInstance3D.new()
    var bm := BoxMesh.new()
    bm.size = size
    mi.mesh = bm
    mi.material_override = _mat(c)
    mi.position = pos
    mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    parent.add_child(mi)
    return mi

func _wheel(z: float) -> Node3D:
    var g := Node3D.new()
    g.position = Vector3(0, 0.3, z)
    var tire := MeshInstance3D.new()
    var cm := CylinderMesh.new()
    cm.top_radius = 0.3
    cm.bottom_radius = 0.3
    cm.height = 0.13
    cm.radial_segments = 16
    tire.mesh = cm
    tire.rotation.z = PI / 2.0
    tire.material_override = _mat(Color(0.12, 0.14, 0.18))
    tire.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    g.add_child(tire)
    var hub := MeshInstance3D.new()
    var hm := CylinderMesh.new()
    hm.top_radius = 0.13
    hm.bottom_radius = 0.13
    hm.height = 0.14
    hm.radial_segments = 10
    hub.mesh = hm
    hub.rotation.z = PI / 2.0
    hub.material_override = _mat(Color(0.84, 0.87, 0.9))
    g.add_child(hub)
    mesh.add_child(g)
    return g

func _build_bike() -> void:
    # 车体朝向 -Z 为车头
    _box(mesh, Vector3(0.5, 0.28, 1.9), Color(1.0, 0.83, 0.29), Vector3(0, 0.5, 0))
    _box(mesh, Vector3(0.52, 0.1, 0.6), Color(0.96, 0.72, 0.12), Vector3(0, 0.42, -0.72))
    _box(mesh, Vector3(0.46, 0.3, 0.7), Color(0.2, 0.25, 0.32), Vector3(0, 0.72, 0.55))
    wheel_f = _wheel(-0.95)
    wheel_r = _wheel(0.9)
    _box(mesh, Vector3(0.08, 0.6, 0.08), Color(0.6, 0.65, 0.72), Vector3(0, 0.85, -0.82))
    _box(mesh, Vector3(0.62, 0.07, 0.07), Color(0.6, 0.65, 0.72), Vector3(0, 1.16, -0.86))
    var shield := MeshInstance3D.new()
    var pm := QuadMesh.new()
    pm.size = Vector2(0.46, 0.42)
    shield.mesh = pm
    var sm := StandardMaterial3D.new()
    sm.albedo_color = Color(0.87, 0.95, 1.0, 0.4)
    sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    shield.material_override = sm
    shield.position = Vector3(0, 1.02, -0.94)
    shield.rotation.x = 0.28
    mesh.add_child(shield)
    _box(mesh, Vector3(0.13, 0.09, 0.03), Color(0.13, 0.17, 0.22), Vector3(-0.38, 1.36, -0.84))
    _box(mesh, Vector3(0.13, 0.09, 0.03), Color(0.13, 0.17, 0.22), Vector3(0.38, 1.36, -0.84))
    var lamp_f := MeshInstance3D.new()
    var lb := BoxMesh.new()
    lb.size = Vector3(0.2, 0.12, 0.05)
    lamp_f.mesh = lb
    var lm := StandardMaterial3D.new()
    lm.albedo_color = Color(1.0, 0.95, 0.75)
    lm.emission_enabled = true
    lm.emission = Color(1.0, 0.95, 0.75)
    lamp_f.material_override = lm
    lamp_f.position = Vector3(0, 0.88, -1.0)
    mesh.add_child(lamp_f)
    _box(mesh, Vector3(0.44, 0.62, 0.34), Color(0.15, 0.35, 0.92), Vector3(0, 1.12, 0.18))
    _box(mesh, Vector3(0.11, 0.11, 0.52), Color(0.15, 0.35, 0.92), Vector3(-0.25, 1.1, -0.32))
    _box(mesh, Vector3(0.11, 0.11, 0.52), Color(0.15, 0.35, 0.92), Vector3(0.25, 1.1, -0.32))
    _box(mesh, Vector3(0.16, 0.5, 0.16), Color(0.2, 0.25, 0.33), Vector3(-0.16, 0.72, -0.18))
    _box(mesh, Vector3(0.16, 0.5, 0.16), Color(0.2, 0.25, 0.33), Vector3(0.16, 0.72, -0.18))
    var head := MeshInstance3D.new()
    var hs := SphereMesh.new()
    hs.radius = 0.21
    hs.height = 0.42
    hs.radial_segments = 14
    hs.rings = 8
    head.mesh = hs
    head.material_override = _mat(Color(1.0, 0.85, 0.7))
    head.position = Vector3(0, 1.62, 0.18)
    head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    mesh.add_child(head)
    var helm := MeshInstance3D.new()
    var hm2 := SphereMesh.new()
    hm2.radius = 0.24
    hm2.height = 0.3
    hm2.radial_segments = 14
    hm2.rings = 6
    helm.mesh = hm2
    helm.material_override = _mat(Color(1.0, 0.83, 0.29))
    helm.position = Vector3(0, 1.7, 0.18)
    mesh.add_child(helm)
    _box(mesh, Vector3(0.56, 0.5, 0.42), Color(1.0, 0.54, 0.24), Vector3(0, 1.18, 0.62))
    _box(mesh, Vector3(0.58, 0.08, 0.44), Color(0.88, 0.44, 0.12), Vector3(0, 1.47, 0.62))

func forward_vec() -> Vector3:
    return Vector3(-sin(heading), 0, -cos(heading))

func _physics_process(delta: float) -> void:
    var gas := 0
    var steer := 0
    if bot_mode:
        gas = bot_gas
        steer = bot_steer
    else:
        if Input.is_action_pressed("ride_gas"):
            gas = 1
        elif Input.is_action_pressed("ride_brake"):
            gas = -1
        if Input.is_action_pressed("ride_left"):
            steer += 1
        if Input.is_action_pressed("ride_right"):
            steer -= 1
    var top := max_speed * weather_mult
    if gas > 0:
        speed = min(top, speed + accel * delta)
    elif gas < 0:
        speed = max(-6.0, speed - accel * 1.5 * delta)
    else:
        speed = move_toward(speed, 0.0, abs(speed) * 0.55 * delta + 0.02)
    if abs(speed) > 0.3:
        heading += steer * 1.7 * delta * min(1.0, abs(speed) / 8.0) * (1.0 if speed >= 0.0 else -1.0)
    var f := forward_vec()
    velocity.x = f.x * speed
    velocity.z = f.z * speed
    velocity.y -= 30.0 * delta
    if is_on_floor():
        velocity.y = -0.5
    move_and_slide()
    # 视觉：车体朝向 / 车轮转动 / 倾斜
    mesh.rotation.y = heading
    var wspin := speed * delta / 0.3
    wheel_f.rotation.x -= wspin
    wheel_r.rotation.x -= wspin
    mesh.rotation.z = -steer * 0.13 * min(1.0, abs(speed) / 16.0)
    cam_pivot.rotation.y = lerp_angle(cam_pivot.rotation.y, heading, min(1.0, delta * 4.2))

func set_dusk_light(on_energy: float) -> void:
    if headlight:
        headlight.light_energy = on_energy
