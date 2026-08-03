shader_type spatial;
// As nv_fp_lens.gdshader, plus `shadows_disabled` — the render_mode that
// `StandardMaterial3D.disable_receive_shadows` compiles to. The emissive slots
// (the crew seams, the breaker's emitter) and the Bone interior all set it, and
// they set it for a reason: a seam that is its own light source should not have
// the room's shadows laid across it.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley,
		specular_schlick_ggx, shadows_disabled;

#include "res://src/shaders/nv_fp_lens.gdshaderinc"
