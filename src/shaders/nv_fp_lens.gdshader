shader_type spatial;
// The StandardMaterial3D defaults, stated rather than inherited: the whole claim
// of this material is that it renders identically to the one it replaces, and a
// default that changes under us in some later engine version would break that
// quietly. Shadow RECEPTION is on here — this is the matte family.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley,
		specular_schlick_ggx;

#include "res://src/shaders/nv_fp_lens.gdshaderinc"
