//#version 420 // Keep it for text editor detection

// note lerp => mix

#define FMT_32 0
#define FMT_24 1
#define FMT_16 2
#define FMT_PAL 4 /* flag bit */

// APITRACE_DEBUG allows to force pixel output to easily detect
// the fragment computed by primitive
#define APITRACE_DEBUG 0
// TEX_COORD_DEBUG output the uv coordinate as color. It is useful
// to detect bad sampling due to upscaling
//#define TEX_COORD_DEBUG

// Not sure we have same issue on opengl. Doesn't work anyway on ATI card
// And I say this as an ATI user.
#define ATI_SUCKS 0

#ifdef FRAGMENT_SHADER

in SHADER
{
	vec4 t;
	vec4 c;
	flat vec4 fc;
} PSin;

#define PSin_t (PSin.t)
#define PSin_c (PSin.c)
#define PSin_fc (PSin.fc)

// Same buffer but 2 colors for dual source blending
layout(location = 0, index = 0) out vec4 SV_Target0;
layout(location = 0, index = 1) out vec4 SV_Target1;

#ifdef ENABLE_BINDLESS_TEX
layout(bindless_sampler, location = 0) uniform sampler2D TextureSampler;
layout(bindless_sampler, location = 1) uniform sampler2D PaletteSampler;
#else
layout(binding = 0) uniform sampler2D TextureSampler;
layout(binding = 1) uniform sampler2D PaletteSampler;
layout(binding = 3) uniform sampler2D RtSampler; // note 2 already use by the image below
#endif

#ifndef DISABLE_GL42_image
#if PS_DATE > 0
// FIXME how to declare memory access
layout(r32i, binding = 2) coherent uniform iimage2D img_prim_min;
// Don't enable it. Discard fragment can still write in the depth buffer
// it breaks shadow in Shin Megami Tensei Nocturne
//layout(early_fragment_tests) in;

// I don't remember why I set this parameter but it is surely useless
//layout(pixel_center_integer) in vec4 gl_FragCoord;
#endif
#else
// use basic stencil
#endif


layout(std140, binding = 21) uniform cb21
{
	vec3 FogColor;
	float AREF;
	vec4 WH;
	vec2 MinF;
	vec2 TA;
	uvec4 MskFix;
	ivec4 FbMask;
	vec3 _not_yet_used;
	float Af;
	vec4 HalfTexel;
	vec4 MinMax;
	vec2 TC_OffsetHack;
};

#ifdef SUBROUTINE_GL40
// Function pointer type + the functionn pointer variable
subroutine void AlphaTestType(vec4 c);
layout(location = 0) subroutine uniform AlphaTestType atst;

subroutine vec4 TfxType(vec4 t, vec4 c);
layout(location = 2) subroutine uniform TfxType tfx;

subroutine void ColClipType(inout vec4 c);
layout(location = 1) subroutine uniform ColClipType colclip;
#endif


vec4 sample_c(vec2 uv)
{
	// FIXME: check the issue on openGL
#if (ATI_SUCKS == 1) && (PS_POINT_SAMPLER == 1)
	// Weird issue with ATI cards (happens on at least HD 4xxx and 5xxx),
	// it looks like they add 127/128 of a texel to sampling coordinates
	// occasionally causing point sampling to erroneously round up.
	// I'm manually adjusting coordinates to the centre of texels here,
	// though the centre is just paranoia, the top left corner works fine.
	uv = (trunc(uv * WH.zw) + vec2(0.5, 0.5)) / WH.zw;
#endif

	return texture(TextureSampler, uv);
}

vec4 sample_p(uint idx)
{
	return texelFetch(PaletteSampler, ivec2(idx, 0u), 0);
}

vec4 wrapuv(vec4 uv)
{
	vec4 uv_out = uv;

#if PS_WMS == PS_WMT

#if PS_WMS == 2
	uv_out = clamp(uv, MinMax.xyxy, MinMax.zwzw);
#elif PS_WMS == 3
	uv_out = vec4((ivec4(uv * WH.xyxy) & ivec4(MskFix.xyxy)) | ivec4(MskFix.zwzw)) / WH.xyxy;
#endif

#else // PS_WMS != PS_WMT

#if PS_WMS == 2
	uv_out.xz = clamp(uv.xz, MinMax.xx, MinMax.zz);

#elif PS_WMS == 3
	uv_out.xz = vec2((ivec2(uv.xz * WH.xx) & ivec2(MskFix.xx)) | ivec2(MskFix.zz)) / WH.xx;

#endif

#if PS_WMT == 2
	uv_out.yw = clamp(uv.yw, MinMax.yy, MinMax.ww);

#elif PS_WMT == 3

	uv_out.yw = vec2((ivec2(uv.yw * WH.yy) & ivec2(MskFix.yy)) | ivec2(MskFix.ww)) / WH.yy;
#endif

#endif

	return uv_out;
}

vec2 clampuv(vec2 uv)
{
	vec2 uv_out = uv;

#if (PS_WMS == 2) && (PS_WMT == 2)
	uv_out = clamp(uv, MinF, MinMax.zw);
#elif PS_WMS == 2
	uv_out.x = clamp(uv.x, MinF.x, MinMax.z);
#elif PS_WMT == 2
	uv_out.y = clamp(uv.y, MinF.y, MinMax.w);
#endif

	return uv_out;
}

mat4 sample_4c(vec4 uv)
{
	mat4 c;

	// FIXME investigate texture gather (filtering impact?)
	c[0] = sample_c(uv.xy);
	c[1] = sample_c(uv.zy);
	c[2] = sample_c(uv.xw);
	c[3] = sample_c(uv.zw);

	return c;
}

uvec4 sample_4_index(vec4 uv)
{
	vec4 c;

	// Either GSdx will send a texture that contains a single channel
	// in this case the red channel is remapped as alpha channel
	//
	// Or we have an old RT (ie RGBA8) that contains index (4/8) in the alpha channel

	// FIXME investigate texture gather (filtering impact?)
	c.x = sample_c(uv.xy).a;
	c.y = sample_c(uv.zy).a;
	c.z = sample_c(uv.xw).a;
	c.w = sample_c(uv.zw).a;

	uvec4 i = uvec4(c * 255.0f + 0.1f); // Denormalize value

#if PS_IFMT == 1
	// 4HH
	return i >> 4u;
#elif PS_IFMT == 2
	// 4HL
	return i & 16u;
#else
	// 8 bits
	return i;
#endif

}

mat4 sample_4p(uvec4 u)
{
	mat4 c;

	c[0] = sample_p(u.x);
	c[1] = sample_p(u.y);
	c[2] = sample_p(u.z);
	c[3] = sample_p(u.w);

	return c;
}

ivec4 sample_color(vec2 st, float q)
{
#if (PS_FST == 0)
	st /= q;
#endif

#if (PS_TCOFFSETHACK == 1)
	st += TC_OffsetHack.xy;
#endif

	vec4 t;
	mat4 c;
	vec2 dd;

#if (PS_LTF == 0 && PS_FMT <= FMT_16 && PS_WMS < 3 && PS_WMT < 3)
	c[0] = sample_c(clampuv(st));
#ifdef TEX_COORD_DEBUG
	c[0].rg = clampuv(st).xy;
#endif

#else
	vec4 uv;

	if(PS_LTF != 0)
	{
		uv = st.xyxy + HalfTexel;
		dd = fract(uv.xy * WH.zw);
	}
	else
	{
		uv = st.xyxy;
	}

	uv = wrapuv(uv);

	if((PS_FMT & FMT_PAL) != 0)
	{
		c = sample_4p(sample_4_index(uv));
	}
	else
	{
		c = sample_4c(uv);
	}
#ifdef TEX_COORD_DEBUG
	c[0].rg = uv.xy;
	c[1].rg = uv.xy;
	c[2].rg = uv.xy;
	c[3].rg = uv.xy;
#endif

#endif

	// PERF: see the impact of the exansion before/after the interpolation
	for (int i = 0; i < 4; i++)
	{
#if ((PS_FMT & ~FMT_PAL) == FMT_24)
		c[i].a = ( (PS_AEM == 0) || any(bvec3(c[i].rgb))  ) ? TA.x : 0.0f;
#elif ((PS_FMT & ~FMT_PAL) == FMT_16)
		c[i].a = c[i].a >= 0.5 ? TA.y : ( (PS_AEM == 0) || any(bvec3(c[i].rgb)) ) ? TA.x : 0.0f;
#endif
	}

#if(PS_LTF != 0)
	t = mix(mix(c[0], c[1], dd.x), mix(c[2], c[3], dd.x), dd.y);
#else
	t = c[0];
#endif

	return ivec4(255.0f * t);
}

#ifndef SUBROUTINE_GL40
ivec4 tfx(ivec4 T, vec4 f)
{
	ivec4 C;
	ivec4 F = ivec4(f * 255.0f); // FIXME optimize the premult

    ivec4 FxT = (F * T) >> 7;

#if (PS_TFX == 0)
	C = FxT;
	C = min(C, 255);
#elif (PS_TFX == 1)
	C = T;
#elif (PS_TFX == 2)
	C.rgb = FxT.rgb + F.a;
	C.a = F.a + T.a;
	C = min(C, 255);
#elif (PS_TFX == 3)
	C.rgb = FxT.rgb + F.a;
	C.a = T.a;
	C = min(C, 255);
#else
    C = F;
#endif

#if (PS_TCC == 0)
    C.a = F.a;
#endif

	// PERF note: integer clamp is typically implemented as a min/max
	// Note1: in case of plain copy, it is useless, save 2 instructions
	// Note2: color can only be positive, so a min is enough, save 1 instruction
	// in bad case
	//
	//return clamp(C, 0, 255);
	return C;
}
#endif

#ifndef SUBROUTINE_GL40
void atst(ivec4 C)
{
	int A = C.a;

#if (PS_ATST == 0) // never
	discard;
#elif (PS_ATST == 1) // always
	// nothing to do
#elif (PS_ATST == 2) // l
	if (A >= AREF)
		discard;
#elif (PS_ATST == 3 ) // le
	if (A > AREF)
		discard;
#elif (PS_ATST == 4) // e
	if (A != AREF)
		discard;
#elif (PS_ATST == 5) // ge
	if (A < AREF)
		discard;
#elif (PS_ATST == 6) // g
	if (A <= AREF)
		discard;
#elif (PS_ATST == 7) // ne
	if (A == AREF)
		discard;
#endif
}
#endif

#ifndef SUBROUTINE_GL40
void colclip(inout ivec4 C)
{
#if (PS_COLCLIP == 2)
	C.rgb = 256 - C.rgb;
#endif
#if (PS_COLCLIP > 0)
	bvec3 factor = lessThan(C.rgb, ivec3(128));
	C.rgb *= ivec3(factor);
#endif
}
#endif

void fog(inout ivec4 C, float f)
{
#if PS_FOG != 0
	// FIXME: use premult fog color
	C.rgb = ivec3(mix(FogColor * 255.0f, vec3(C.rgb), f));
#endif
}

ivec4 ps_color()
{
	ivec4 t = sample_color(PSin_t.xy, PSin_t.w);

#ifdef TEX_COORD_DEBUG
	vec4 C = clamp(t, ivec4(0), ivec4(255));
#else
#if PS_IIP == 1
	ivec4 C = tfx(t, PSin_c);
#else
	ivec4 C = tfx(t, PSin_fc);
#endif
#endif

	atst(C);

	fog(C, PSin_t.z);

#if (PS_COLCLIP < 3)
	colclip(C);
#endif

#if (PS_CLR1 != 0) // needed for Cd * (As/Ad/F + 1) blending modes
	C.rgb = ivec3(255);
#endif

	return C;
}

void ps_fbmask(inout ivec4 C)
{
	// FIXME do I need special case for 16 bits
#if PS_FBMASK
	ivec4 RT = ivec4(texelFetch(RtSampler, ivec2(gl_FragCoord.xy), 0) * 255.0f + 0.1f);
	C = (C & ~FbMask) | (RT & FbMask);
#endif
}

void ps_blend(inout ivec4 Color)
{
#if PS_BLEND_A || PS_BLEND_B || PS_BLEND_D
	ivec4 RT = ivec4(texelFetch(RtSampler, ivec2(gl_FragCoord.xy), 0) * 255.0f + 0.1f);
	// FIXME FMT_16 case
	int Ad = RT.a;

	// Let the compiler do its jobs !
	ivec3 Cd = RT.rgb;
	ivec3 Cs = Color.rgb;

#if PS_BLEND_A == 0
    ivec3 A = Cs;
#elif PS_BLEND_A == 1
    ivec3 A = Cd;
#else
    ivec3 A = ivec3(0);
#endif

#if PS_BLEND_B == 0
    ivec3 B = Cs;
#elif PS_BLEND_B == 1
    ivec3 B = Cd;
#else
    ivec3 B = ivec3(0);
#endif

#if PS_BLEND_C == 0
    int C = Color.a;
#elif PS_BLEND_C == 1
    int C = Ad;
#else
	// FIXME: use integer value directly
    int C = int(Af * 128.0f + 0.1f);
#endif

#if PS_BLEND_D == 0
    ivec3 D = Cs;
#elif PS_BLEND_D == 1
    ivec3 D = Cd;
#else
    ivec3 D = ivec3(0);
#endif

#if PS_BLEND_A == PS_BLEND_B
    Color.rgb = D;
#elif PS_DFMT == FMT_24 && PS_BLEND_C == 1
    Color.rgb = A - B + D;
#else
    Color.rgb = (((A - B) * C) >> 7) + D;
#endif

	// FIXME dithering

	// FIXME do I really need this clamping?
#if PS_COLCLIP != 3
	// Standard Clamp
	Color.rgb = clamp(Color.rgb, ivec3(0), ivec3(255));
#endif


    // Warning: normally blending equation is mult(A, B) = A * B >> 7. GPU have the full accuracy
    // GS: Color = 1, Alpha = 255 => output 1
    // GPU: Color = 1/255, Alpha = 255/255 * 255/128 => output 1.9921875
#if PS_DFMT == FMT_16
	// In 16 bits format, only 5 bits of colors are used. It impacts shadows computation of Castlevania
	Color.rgb &= 0xF8;
#elif PS_COLCLIP == 3
	Color.rgb &= 0xFF;
#endif

#endif
}

void ps_main()
{
#if (PS_DATE & 3) == 1 && !defined(DISABLE_GL42_image)
	// DATM == 0
	// Pixel with alpha equal to 1 will failed
	float rt_a = texelFetch(RtSampler, ivec2(gl_FragCoord.xy), 0).a;
	if ((127.5f / 255.0f) < rt_a) { // < 0x80 pass (== 0x80 should not pass)
#if PS_DATE >= 5
		discard;
#else
		imageStore(img_prim_min, ivec2(gl_FragCoord.xy), ivec4(-1));
		return;
#endif
	}
#elif (PS_DATE & 3) == 2 && !defined(DISABLE_GL42_image)
	// DATM == 1
	// Pixel with alpha equal to 0 will failed
	float rt_a = texelFetch(RtSampler, ivec2(gl_FragCoord.xy), 0).a;
	if(rt_a < (127.5f / 255.0f)) { // >= 0x80 pass
#if PS_DATE >= 5
		discard;
#else
		imageStore(img_prim_min, ivec2(gl_FragCoord.xy), ivec4(-1));
		return;
#endif
	}
#endif

#if PS_DATE == 3 && !defined(DISABLE_GL42_image)
	int stencil_ceil = imageLoad(img_prim_min, ivec2(gl_FragCoord.xy)).r;
	// Note gl_PrimitiveID == stencil_ceil will be the primitive that will update
	// the bad alpha value so we must keep it.

	if (gl_PrimitiveID > stencil_ceil) {
		discard;
	}
#endif

	ivec4 C = ps_color();
#if (APITRACE_DEBUG & 1) == 1
	C.r = 255;
#endif
#if (APITRACE_DEBUG & 2) == 2
	C.g = 255;
#endif
#if (APITRACE_DEBUG & 4) == 4
	C.b = 255;
#endif
#if (APITRACE_DEBUG & 8) == 8
	C.a = 128;
#endif

#if PS_SHUFFLE
	// FIXME use integer TA in cb (save a MAD + a trunc)
	ivec2 denorm_TA = ivec2(vec2(TA.xy) * 255.0f + 0.5f);

	// Write RB part. Mask will take care of the correct destination
#if PS_READ_BA
	C.rb = C.bb;
#else
	C.rb = C.rr;
#endif

	// Write GA part. Mask will take care of the correct destination
#if PS_READ_BA
	if (bool(C.a & 0x80))
		C.ga = ivec2((C.a & 0x7F) | (denorm_TA.y & 0x80));
	else
		C.ga = ivec2((C.a & 0x7F) | (denorm_TA.x & 0x80));
#else
	if (bool(C.g & 0x80))
		C.ga = ivec2((C.g & 0x7F) | (denorm_TA.y & 0x80));
	else
		C.ga = ivec2((C.g & 0x7F) | (denorm_TA.x & 0x80));
#endif

#endif

	// Must be done before alpha correction
	// PERF note: doing vec4 here allow to save a Int2Float instruction
	// in basic case (i.e. not blend/mask/fba)
	vec4 alpha_blend = vec4(C) / 128.0f;

	// Correct the ALPHA value based on the output format
	// FIXME add support of alpha mask to replace properly PS_AOUT
#if (PS_DFMT == FMT_16) || (PS_AOUT)
	C.a = (PS_FBA != 0) ? 0x80 : C.a & 0x80;
#elif (PS_DFMT == FMT_32) && (PS_FBA != 0)
	C.a |= 0x80;
#endif

	// Get first primitive that will write a failling alpha value
#if PS_DATE == 1 && !defined(DISABLE_GL42_image)
	// DATM == 0
	// Pixel with alpha equal to 1 will failed (128-255)
	if (C.a > 127) {
		imageAtomicMin(img_prim_min, ivec2(gl_FragCoord.xy), gl_PrimitiveID);
		return;
	}
#elif PS_DATE == 2 && !defined(DISABLE_GL42_image)
	// DATM == 1
	// Pixel with alpha equal to 0 will failed (0-127)
	if (C.a < 128) {
		imageAtomicMin(img_prim_min, ivec2(gl_FragCoord.xy), gl_PrimitiveID);
		return;
	}
#endif

	ps_blend(C);

	ps_fbmask(C);

	SV_Target0 = vec4(C) / 255.0f;
	SV_Target1 = alpha_blend;
}

#endif
