class_name GodRays
extends RefCounted
## God rays as a signature motif, not as an effect.
##
## The brief for this is a piece of the user's own key art: a black-and-white
## noir frame carried entirely by ONE volumetric shaft, with a silhouette
## standing in it. Everything in this file exists to make that image
## reproducible in-engine, on demand, from a procgen room.
##
## THE LAW THIS FILE LIVES UNDER
## -----------------------------
## A shaft must light ITSELF and not the room. That is not a stylistic
## preference, it is the darkness law: the moment a shaft is bright enough to
## illuminate the wall behind it, the room is lit, the player can see without
## their beam, and pillar 2 ("light is decryption") is dead.
##
## Godot gives us exactly the control needed to enforce it, and it is the single
## most important number in this file:
##
##     light.light_energy                 -> how much the shaft lights SURFACES
##     light.light_volumetric_fog_energy  -> how much the shaft lights ITSELF
##
## Every hero shaft here runs a LOW light_energy and a very high fog energy. The
## shaft blazes; the floor under it gets a soft pool and nothing else in the room
## moves. Turn those two numbers toward each other and you get a nice-looking
## room that this game cannot use.
##
## The second half of the law is fog density. A shaft reads in proportion to the
## medium it crosses, and the only global control is the environment's fog
## density — raise that until the shafts look right and every distant surface
## greys out. So each shaft carries its own FogVolume, and the density lives
## inside a box the size of the shaft. See nv_shaft_fog.gdshader.

const SHAFT_FOG_SHADER: String = "res://src/shaders/nv_shaft_fog.gdshader"
const VOLUME_NOISE: String = "res://assets/textures/noise_volume.tres"

## Colour for the hero shafts. Cold and slightly desaturated relative to the
## teal practicals: a shaft is light from SOMEWHERE ELSE, and if it matches the
## room's own fixtures it stops reading as an opening and starts reading as
## another lamp.
const SHAFT_COLD: Color = Color(0.70, 0.80, 1.0)

## Ceiling cell size. The aperture plate fills exactly one cell, because that is
## the granularity procgen can punch a hole at.
const CELL: float = 4.0


# --------------------------------------------------------------- hero shaft --

## One hero shaft: aperture geometry, the light through it, the local fog, and
## the motes inside it.
##
## `pos` is the point on the FLOOR the shaft lands on. `ceiling` is the height
## of the opening. `tilt` moves the source sideways so the shaft rakes instead
## of dropping vertically — a vertical shaft is a spotlight, a raked one is a
## window, and only one of those has ever been on a film poster.
static func hero_shaft(geo: Node3D, lights: Node3D, fog: Node3D, pos: Vector3,
		ceiling: float, opening: Vector2 = Vector2(1.5, 3.2),
		tilt: Vector3 = Vector3(1.4, 0.0, 0.6), energy: float = 2.2,
		slats: int = 3, fog_energy: float = 9.0) -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "Shaft_%d_%d" % [int(pos.x), int(pos.z)]
	# So `--freecam god_shafts` can stand off to one side of a hero shaft and
	# photograph it in CROSS-SECTION. A volumetric shaft only reads as a shaft
	# when you look across it, and until this group existed there was no way to
	# ask the build where its shafts had ended up.
	root.add_to_group("god_shafts")
	# The shaft's own floor point, as metadata, because this node's TRANSFORM is
	# not it: every piece of the unit below is positioned at `pos + offset` in the
	# builder's space and the root itself never moves off the origin. A probe that
	# read `global_position` would aim at the middle of the layer.
	root.set_meta("anchor", pos)
	geo.add_child(root)

	# --- the aperture -------------------------------------------------------
	# A PLATE with a slot cut in it, filling the whole 4 m ceiling cell the
	# caller punched out, plus slats across the slot.
	#
	# The plate is the entire feature and the first three builds did not have
	# one. Without it the "aperture" was a decorative lip around a 4 x 4 m hole,
	# the light poured through the whole cell, and the result measured and read
	# as a soft blue wash filling a third of the room — the exact opposite of a
	# shaft. A shaft's edges are made of SHADOW. Something opaque has to be
	# casting them, and a thin frame around a big hole casts nothing.
	var trim: Material = KitLib.material("M_PanelTrim")
	var dark: Material = KitLib.material("M_PanelDark")
	var half: float = CELL * 0.5
	var ox: float = opening.x * 0.5
	var oz: float = opening.y * 0.5
	var t: float = 0.34                       # plate thickness
	var plate: Array = [
		# name, half-extent x, half-extent z, centre x, centre z
		["N", half, (half - oz) * 0.5, 0.0, (half + oz) * 0.5],
		["S", half, (half - oz) * 0.5, 0.0, -(half + oz) * 0.5],
		["E", (half - ox) * 0.5, oz, (half + ox) * 0.5, 0.0],
		["W", (half - ox) * 0.5, oz, -(half + ox) * 0.5, 0.0],
	]
	for q: Array in plate:
		if float(q[1]) <= 0.001 or float(q[2]) <= 0.001:
			continue
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(float(q[1]) * 2.0, t, float(q[2]) * 2.0)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "AperturePlate%s" % String(q[0])
		mi.mesh = box
		mi.material_override = dark
		mi.position = pos + Vector3(float(q[3]), ceiling + t * 0.5, float(q[4]))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi)

	# A proud reveal lip around the slot, on the room side: the slot edge is the
	# brightest silhouette in the room and it should be a machined edge, not a
	# hole in a sheet.
	var lip: float = 0.12
	for side: int in 4:
		var horiz: bool = side < 2
		var sgn: float = 1.0 if side % 2 == 0 else -1.0
		var box2: BoxMesh = BoxMesh.new()
		if horiz:
			box2.size = Vector3(opening.x + 0.28, lip, 0.14)
		else:
			box2.size = Vector3(0.14, lip, opening.y + 0.28)
		var mi2: MeshInstance3D = MeshInstance3D.new()
		mi2.name = "ApertureLip%d" % side
		mi2.mesh = box2
		mi2.material_override = trim
		mi2.position = pos + Vector3(
				0.0 if horiz else sgn * (ox + 0.07),
				ceiling - lip * 0.5,
				sgn * (oz + 0.07) if horiz else 0.0)
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi2)

	# Slats across the slot, sitting just ABOVE the plate so the blades appear to
	# originate inside the opening rather than at the room's ceiling. That short
	# throw before the first surface is what gives a shaft depth beyond the room.
	for i: int in slats:
		var f: float = (float(i) + 0.5) / float(slats)
		var box3: BoxMesh = BoxMesh.new()
				# 55% of the pitch, not 42%. The blades have to be WIDE to survive
		# Godot's volumetric fog, which is a 128 x 128 x 192 froxel grid over
		# 80 m: anything finer than a froxel is averaged away before it reaches
		# the screen. Six thin slats produced a uniform glow; three fat ones
		# produce three blades.
		box3.size = Vector3(opening.x, 0.09, opening.y / float(slats) * 0.55)
		var mi3: MeshInstance3D = MeshInstance3D.new()
		mi3.name = "ApertureSlat%d" % i
		mi3.mesh = box3
		mi3.material_override = dark
		mi3.position = pos + Vector3(0.0, ceiling + t + 0.22,
				(f - 0.5) * opening.y)
		mi3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		root.add_child(mi3)

	# --- the light ----------------------------------------------------------
	# The source sits in the VOID ABOVE the aperture — which only works because
	# the caller punches a hole in the ceiling field at this cell. The first
	# build placed it out at `tilt * ceiling` horizontally, which for the
	# two-storey room put it 7 m sideways and 12 m up: outside the room, behind
	# a sealed ceiling, contributing exactly nothing. A shaft is a hole with a
	# light behind it, and the hole is not optional.
	#
	# Directly above, with a small lateral offset for rake. The rake comes from
	# the AIM POINT rather than from moving the source, so the cone always
	# contains the opening no matter how hard the shaft is angled.
	# HOW FAR ABOVE — the number that decides whether this is a shaft or a
	# spotlight, and the one the first two builds got wrong.
	#
	# A shaft looks like a shaft because its edges are nearly PARALLEL, and a
	# point light only approximates that from a long way off. The spread of the
	# projected opening is (source height above floor) / (source height above
	# aperture). At 3.4 m above an 8 m ceiling that ratio is 3.35, so a 1.7 m
	# slot became a 5.7 m wash covering half the room — which measured as a
	# soft blue glow with no visible shaft in it at all. At 20 m above, the
	# ratio is 1.4 and the slot stays a slot all the way to the floor.
	var lateral: Vector3 = Vector3(tilt.x, 0.0, tilt.z).normalized()
	var above: float = ceiling * 1.8 + 6.0
	var src: Vector3 = pos + Vector3(0.0, ceiling + above, 0.0) + lateral * 1.2
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Key_shaft"
	l.position = src
	l.light_color = SHAFT_COLD
	# LOW on surfaces. This is the whole law: at 2.2 the pool on the floor is a
	# soft patch you can stand in, and the wall four metres away is untouched.
	l.light_energy = energy
	l.spot_range = (ceiling + above) * 1.35
	# Just wide enough to cover the opening from `above` metres up, plus 35%
	# margin so the cone edge falls outside the aperture and the frame reads as
	# a hard-edged silhouette rather than as a soft vignette.
	var half_diag: float = sqrt(pow(opening.x * 0.5, 2.0) + pow(opening.y * 0.5, 2.0))
	l.spot_angle = rad_to_deg(atan(half_diag / above)) * 1.35 + 2.0
	l.spot_angle_attenuation = 0.85
	# Gentle distance falloff. A source 20 m away with the default decay
	# delivers a quarter of its energy to the floor, and compensating with
	# energy alone blows out everything near the aperture.
	l.spot_attenuation = 0.40
	l.light_specular = 0.85
	l.shadow_enabled = true
	l.shadow_bias = 0.02
	l.shadow_normal_bias = 0.9
	l.shadow_blur = 1.0
	# HIGH in the medium. The shaft is bright because the air is bright, not
	# because the room is.
	l.light_volumetric_fog_energy = fog_energy
	lights.add_child(l)
	# Aim at a floor point offset DOWN-rake, so the shaft leans.
	LightRig._aim(l, pos + lateral * (ceiling * 0.30))

	# --- the local fog ------------------------------------------------------
	var fv: FogVolume = FogVolume.new()
	fv.name = "ShaftFog"
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	# Sized to the SHAFT, not to the room. The projected opening widens by
	# (ceiling + above) / above from the aperture to the floor; the box is that
	# footprint plus a margin for the edge fade and the rake. Getting this wrong
	# is not a subtle error — a fog box the size of the room IS a fogged room,
	# which is the exact failure the local-density approach exists to avoid.
	# Hug the SLOT's projection, not the cell and not the room. Every metre of
	# padding here is a metre of extra volume the shaft light also has to fill,
	# and the padding is what turned build 4 into a fog machine.
	var spread: float = (ceiling + above) / above
	var rake: float = ceiling * 0.30
	fv.size = Vector3(opening.x * spread + 0.6, ceiling + 1.2,
			opening.y * spread + rake * 0.6 + 0.6)
	fv.position = pos + Vector3(lateral.x * rake * 0.5,
			(ceiling + 1.2) * 0.5 - 0.1, lateral.z * rake * 0.5)
	var fmat: ShaderMaterial = ShaderMaterial.new()
	fmat.shader = load(SHAFT_FOG_SHADER) as Shader
	fmat.set_shader_parameter("base_density", 0.42)
	fmat.set_shader_parameter("noise_amount", 0.35)
	fmat.set_shader_parameter("noise_scale", 0.16)
	fmat.set_shader_parameter("drift_speed", 0.035)
	fmat.set_shader_parameter("edge_fade", 0.22)
	fmat.set_shader_parameter("height_gain", 0.9)
	fmat.set_shader_parameter("fog_albedo", Color(0.55, 0.66, 0.82))
	fmat.set_shader_parameter("fog_emission", Color(0.004, 0.006, 0.010))
	fmat.set_shader_parameter("volume_noise", load(VOLUME_NOISE))
	fv.material = fmat
	fog.add_child(fv)

	# --- the motes ----------------------------------------------------------
	add_motes(root, fv.position, fv.size * 0.62)
	return root


# ------------------------------------------------------------- grate stripes --

## A striped shaft array through a ceiling grate.
##
## `use_geometry` is the A/B this function exists for:
##
##   false  a light projector (gobo). One texture lookup per fog sample, no
##          shadow map, no extra draw calls. The stripes are perfectly regular
##          and perfectly soft, and they do not react to anything passing under
##          the grate.
##   true   a real FLOOR_2x2_GRATE module from the kit, in the ceiling, with the
##          light shadow-casting through it. The blades have real perspective
##          convergence, real penumbra that widens with distance, and anything
##          that walks through them breaks them.
##
## Both are captured and costed in INTEGRATION2.md. The cost difference is a
## shadow map and a couple of hundred triangles; the look difference is whether
## the stripes are a texture or a fact.
static func grate_stripes(geo: Node3D, lights: Node3D, fog: Node3D,
		pos: Vector3, ceiling: float, use_geometry: bool,
		energy: float = 3.4, fog_energy: float = 1.4) -> void:
	# Same parallelism argument as the hero shaft: a source 2.4 m above a grate
	# throws blades that fan out into a smear by the time they reach the floor.
	var above: float = ceiling * 2.2 + 8.0
	var src: Vector3 = pos + Vector3(1.1, ceiling + above, 1.1)
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Key_stripes"
	l.position = src
	l.light_color = SHAFT_COLD
	l.light_energy = energy
	l.spot_range = (ceiling + above) * 1.35
	# Wide enough to cover the 4 m ceiling cell from `above` metres up.
	l.spot_angle = rad_to_deg(atan(2.9 / above)) * 1.4 + 1.5
	l.spot_angle_attenuation = 0.9
	l.spot_attenuation = 0.40
	l.light_specular = 0.6
	l.light_volumetric_fog_energy = fog_energy
	if use_geometry:
		l.shadow_enabled = true
		l.shadow_bias = 0.018
		l.shadow_normal_bias = 0.8
		# Sharp: the whole reason to pay for geometry is blade definition.
		l.shadow_blur = 0.55
		# A COARSE VENT LOUVRE, not the walkway grate.
		#
		# The first build used four FLOOR_2x2_GRATE modules from the kit, which
		# is the obvious choice and produces nothing. The kit grate's bars sit
		# on a 30 mm pitch; projected onto the floor that is a ~190 mm shadow
		# pitch, and Godot's volumetric fog is a 128 x 128 x 192 froxel grid
		# covering 80 m. Structure finer than one froxel is averaged away before
		# it is ever shaded, so the entire stripe array resolved as a smooth
		# haze. Measured, captured, and unfixable by tuning.
		#
		# The occluder therefore has to be COARSE — 550 mm blades — and once it
		# is coarse it stops being a walkway grate and becomes what it should
		# have been from the start under the motivation law: an air-handling
		# vent louvre in the ceiling, which is a thing that belongs above a
		# corridor and a thing a player can look at and understand.
		var blade_mat: Material = KitLib.material("M_Grate")
		var pitch: float = 0.55
		var n: int = int(CELL / pitch)
		for i: int in n:
			var b: BoxMesh = BoxMesh.new()
			b.size = Vector3(CELL - 0.2, 0.07, pitch * 0.52)
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.name = "VentBlade%d" % i
			mi.mesh = b
			mi.material_override = blade_mat
			mi.position = pos + Vector3(0.0, ceiling + 0.10,
					(float(i) + 0.5) * pitch - CELL * 0.5)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
			geo.add_child(mi)
		# The louvre frame, so the opening is a fitting and not a rip.
		for k: int in 2:
			var fb: BoxMesh = BoxMesh.new()
			fb.size = Vector3(0.16, 0.22, CELL)
			var fmi: MeshInstance3D = MeshInstance3D.new()
			fmi.name = "VentFrame%d" % k
			fmi.mesh = fb
			fmi.material_override = KitLib.material("M_PanelTrim")
			fmi.position = pos + Vector3((float(k) * 2.0 - 1.0) * (CELL * 0.5 - 0.08),
					ceiling + 0.08, 0.0)
			fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			geo.add_child(fmi)
	else:
		l.shadow_enabled = false
		l.light_projector = load(LightRig.GOBO_SLATS) as Texture2D
	lights.add_child(l)
	LightRig._aim(l, pos)

	var fv: FogVolume = FogVolume.new()
	fv.name = "StripeFog"
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	fv.size = Vector3(4.6, ceiling + 0.6, 5.4)
	fv.position = pos + Vector3(0.0, (ceiling + 0.6) * 0.5, 0.0)
	var fmat: ShaderMaterial = ShaderMaterial.new()
	fmat.shader = load(SHAFT_FOG_SHADER) as Shader
	# Thinner than a hero shaft. Stripes are supposed to be a texture on the
	# air, not a wall of light; at hero density the individual blades merge.
	# Deliberately LOW. See the verdict in INTEGRATION2.md: stripes through a
	# ceiling vent do not survive as a volumetric effect at corridor scale, so
	# this volume only adds a whisper of body around the opening and the stripe
	# pattern itself is delivered as light landing on the FLOOR AND WALLS, which
	# is what a gobo has always been good at and costs nothing.
	fmat.set_shader_parameter("base_density", 0.055)
	fmat.set_shader_parameter("noise_amount", 0.30)
	fmat.set_shader_parameter("noise_scale", 0.22)
	fmat.set_shader_parameter("drift_speed", 0.03)
	fmat.set_shader_parameter("edge_fade", 0.30)
	fmat.set_shader_parameter("height_gain", 0.7)
	fmat.set_shader_parameter("fog_albedo", Color(0.55, 0.66, 0.82))
	fmat.set_shader_parameter("fog_emission", Color(0.003, 0.005, 0.008))
	fmat.set_shader_parameter("volume_noise", load(VOLUME_NOISE))
	fv.material = fmat
	fog.add_child(fv)


# --------------------------------------------------------------------- motes --

## Dust motes, confined to the shaft.
##
## This is the detail that separates a shaft from a gradient. Volumetric fog
## gives the shaft its body; the motes give it SCALE, because a mote is a thing
## of known size drifting at a known speed, and the eye uses them to work out
## how big the shaft is and how far away. Concentrating them inside the shaft
## rather than scattering them through the room is both cheaper and more
## correct: you only see dust where there is light to see it by.
static func add_motes(parent: Node3D, centre: Vector3, extents: Vector3,
		count: int = 220) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Motes"
	p.amount = count
	p.lifetime = 14.0
	p.preprocess = 14.0
	p.position = centre
	p.explosiveness = 0.0
	p.randomness = 1.0
	p.fixed_fps = 30
	p.interpolate = true
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	# The AABB has to be declared or the particles vanish the moment the emitter
	# origin leaves the frustum — which, for a volume the player walks through,
	# is most of the time.
	p.visibility_aabb = AABB(-extents, extents * 2.0)

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents
	# Barely moving. Dust in still air falls at centimetres per second, and any
	# faster reads as snow or as embers — both of which are somebody else's game.
	pm.direction = Vector3(0.12, -1.0, 0.05)
	pm.spread = 22.0
	pm.initial_velocity_min = 0.012
	pm.initial_velocity_max = 0.055
	pm.gravity = Vector3(0.0, -0.010, 0.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.14
	pm.turbulence_noise_scale = 2.2
	pm.turbulence_noise_speed = Vector3(0.03, 0.02, 0.03)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	# Fade in and out rather than popping at the ends of the lifetime.
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(0.18, 1.0))
	curve.add_point(Vector2(0.82, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var ct: CurveTexture = CurveTexture.new()
	ct.curve = curve
	pm.alpha_curve = ct
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.012, 0.012)
	p.draw_pass_1 = quad

	var mm: StandardMaterial3D = StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mm.vertex_color_use_as_albedo = true
	mm.albedo_color = Color(0.62, 0.74, 0.92, 0.30)
	mm.disable_receive_shadows = true
	# Motes must never bloom. They sit below the glow threshold on purpose: a
	# blooming mote is a lens flare, and there are two hundred of them.
	mm.emission_enabled = false
	p.material_override = mm
	parent.add_child(p)
	return p
