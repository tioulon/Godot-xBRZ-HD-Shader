shader_type canvas_item;

// ============================================================================
//  xBRZ "Sharp HD" pixel-art upscaler for Godot 4  (canvas_item, SubViewport)
// ----------------------------------------------------------------------------
//  CREDITS
//    - xBRZ scaling algorithm .......... Zenju  (https://sourceforge.net/projects/xbrz/)
//    - Single-pass "freescale" shader .. Hyllian & the libretro shader project
//    - Godot 4 port + Sharp/HD mods .... Ulon
//
//  WHAT THIS BUILD ADDS over plain xBRZ:
//    - "no_blend" snap: keeps xBRZ's reshaped diagonals but outputs solid
//      pixels (no anti-aliased in-between colors) for a crisp, Sokpop-style look.
//    - Bilinear grid reconstruction so the hard edges follow a smooth boundary
//      at output resolution instead of a coarse 4x staircase ("waves").
//    - sqrt-free equality tests + source-size moved to the vertex stage.
//
//  USAGE
//    Put your game world in a SubViewport at its NATIVE resolution, then display
//    that SubViewport on the node carrying THIS material (a TextureRect, Sprite2D
//    or SubViewportContainer). The shader reads the viewport via built-in TEXTURE.
//
//  --- TO LOOK SHARP / HD, NOT BLURRY (read this) ----------------------------
//  1. The display node's "Texture > Filter" MUST be Nearest. If it's Linear,
//     every source tap is pre-blurred and the whole image goes soft. Your
//     project default is already Nearest, so leave it on "Inherit" or force
//     Nearest explicitly.
//  2. Render the SubViewport at your NATIVE art resolution (e.g. 320x180),
//     NOT at window size. xBRZ does its own 4x upscale internally.
//  3. Prefer an integer final scale (e.g. 320x180 -> 1280x720 = 4x). Non-integer
//     output scaling of the result reads softer.
//  4. The remaining softness on edges is xBRZ's intended anti-aliasing. Use the
//     EQUAL_COLOR_TOLERANCE and SHARPEN_STRENGTH knobs below to bias toward crisp.
// ============================================================================

// Weight of luma vs chroma when comparing two pixels. ~1.0 is standard.
uniform float LUMINANCE_WEIGHT : hint_range(0.0, 2.0) = 1.0;

// How close two colors must be to count as "the same".
// >>> THIS IS THE MAIN SHARPNESS KNOB <<<
//   lower  (e.g. 0.02) = fewer pixels treated as edges -> sharper, more "pixel".
//   higher (e.g. 0.10) = more smoothing/blending -> softer, rounder.
uniform float EQUAL_COLOR_TOLERANCE : hint_range(0.0, 0.5) = 0.03;

// Edge-direction tuning. Defaults are the canonical xBRZ values; rarely changed.
uniform float STEEP_DIRECTION_THRESHOLD : hint_range(0.0, 8.0) = 2.0;
uniform float DOMINANT_DIRECTION_THRESHOLD : hint_range(0.0, 8.0) = 3.5;

// Optional output crispening (cheap, reuses samples we already have).
//   0.0 = off (pure xBRZ).  Try 0.2 - 0.6 for an "HD crunch" on edges.
uniform float SHARPEN_STRENGTH : hint_range(0.0, 2.0) = 0.0;

// Sharp "noblend" mode (the Sokpop look). Snaps every edge blend to a solid
// pixel, so you get the reshaped diagonals/curves but NO anti-aliased in-between
// colors -> crisp borders, visible pixels.
//   true  = sharp, you see the pixels (no AA between them).
//   false = smooth anti-aliased xBRZ.
uniform bool no_blend = true;

// 7 packed neighbour coordinate sets, computed once per vertex (cheap).
varying vec4 t[8];
// Source resolution in pixels, passed from vertex so fragment doesn't recompute it.
varying vec2 src_size;

void vertex() {
	// TEXTURE_PIXEL_SIZE = 1/source_resolution, so invert to get the size.
	vec2 source_wh = 1.0 / TEXTURE_PIXEL_SIZE;
	src_size = source_wh;

	float dx = TEXTURE_PIXEL_SIZE.x;
	float dy = TEXTURE_PIXEL_SIZE.y;

	// Precompute the 5x5 sampling neighbourhood (minus far corners) as UV offsets.
	// Each varying packs an x-triplet + a shared y (or vice-versa) to save fetches.
	t[1] = UV.xxxy + vec4(-dx, 0.0, dx, -2.0 * dy); // A1 B1 C1
	t[2] = UV.xxxy + vec4(-dx, 0.0, dx,       -dy); //  A  B  C
	t[3] = UV.xxxy + vec4(-dx, 0.0, dx,       0.0); //  D  E  F
	t[4] = UV.xxxy + vec4(-dx, 0.0, dx,        dy); //  G  H  I
	t[5] = UV.xxxy + vec4(-dx, 0.0, dx,  2.0 * dy); // G5 H5 I5
	t[6] = UV.xyyy + vec4(-2.0 * dx, -dy, 0.0, dy); // A0 D0 G0
	t[7] = UV.xyyy + vec4( 2.0 * dx, -dy, 0.0, dy); // C4 F4 I4
}

// Pack an RGB color into a single comparable scalar (exact-equality tests only).
float reduce(vec3 color) {
	return dot(color, vec3(65536.0, 256.0, 1.0));
}

// Perceptual distance in YCbCr, SQUARED (no sqrt). Used directly for equality
// tests; the sqrt version below wraps this for the magnitude-summing tests.
float DistYCbCrSq(vec3 pixA, vec3 pixB) {
	const vec3 w = vec3(0.2627, 0.6780, 0.0593);
	const float scaleB = 0.5 / (1.0 - w.b);
	const float scaleR = 0.5 / (1.0 - w.r);
	vec3 diff = pixA - pixB;
	float Y = dot(diff, w);
	float Cb = scaleB * (diff.b - Y);
	float Cr = scaleR * (diff.r - Y);
	float Yw = LUMINANCE_WEIGHT * Y;
	return (Yw * Yw) + (Cb * Cb) + (Cr * Cr);
}

float DistYCbCr(vec3 pixA, vec3 pixB) {
	return sqrt(DistYCbCrSq(pixA, pixB));
}

// Equality test avoids the sqrt by comparing squared distance to squared tolerance.
// This is called ~24x per pixel, so dropping the sqrt is a real saving.
bool IsPixEqual(vec3 pixA, vec3 pixB) {
	return (DistYCbCrSq(pixA, pixB) < (EQUAL_COLOR_TOLERANCE * EQUAL_COLOR_TOLERANCE));
}

const int BLEND_NONE = 0;
const int BLEND_NORMAL = 1;
const int BLEND_DOMINANT = 2;

bool IsBlendingNeeded(ivec4 blend) {
	return any(notEqual(blend, ivec4(BLEND_NONE)));
}

// Edge blend used while building the 4x4 sub-pixel grid. Always smooth here;
// the hard "noblend" decision is made once at the very end (see fragment()),
// which is what stops the diagonals from going wavy.
vec3 bmix(vec3 a, vec3 b, float w) {
	return mix(a, b, w);
}

void fragment() {
	// Sub-pixel position inside the current source texel (0..1 in x and y).
	vec2 f = fract(UV * src_size);

	// --- Gather the neighbourhood (21 taps). Indices follow the xBRZ layout. ---
	vec3 src[25];
	src[21] = texture(TEXTURE, t[1].xw).rgb;
	src[22] = texture(TEXTURE, t[1].yw).rgb;
	src[23] = texture(TEXTURE, t[1].zw).rgb;
	src[6]  = texture(TEXTURE, t[2].xw).rgb;
	src[7]  = texture(TEXTURE, t[2].yw).rgb;
	src[8]  = texture(TEXTURE, t[2].zw).rgb;
	src[5]  = texture(TEXTURE, t[3].xw).rgb;
	src[0]  = texture(TEXTURE, t[3].yw).rgb; // center texel
	src[1]  = texture(TEXTURE, t[3].zw).rgb;
	src[4]  = texture(TEXTURE, t[4].xw).rgb;
	src[3]  = texture(TEXTURE, t[4].yw).rgb;
	src[2]  = texture(TEXTURE, t[4].zw).rgb;
	src[15] = texture(TEXTURE, t[5].xw).rgb;
	src[14] = texture(TEXTURE, t[5].yw).rgb;
	src[13] = texture(TEXTURE, t[5].zw).rgb;
	src[19] = texture(TEXTURE, t[6].xy).rgb;
	src[18] = texture(TEXTURE, t[6].xz).rgb;
	src[17] = texture(TEXTURE, t[6].xw).rgb;
	src[9]  = texture(TEXTURE, t[7].xy).rgb;
	src[10] = texture(TEXTURE, t[7].xz).rgb;
	src[11] = texture(TEXTURE, t[7].xw).rgb;

	// Scalar-packed inner 3x3 for fast exact-equality comparisons.
	float v[9];
	v[0] = reduce(src[0]);
	v[1] = reduce(src[1]);
	v[2] = reduce(src[2]);
	v[3] = reduce(src[3]);
	v[4] = reduce(src[4]);
	v[5] = reduce(src[5]);
	v[6] = reduce(src[6]);
	v[7] = reduce(src[7]);
	v[8] = reduce(src[8]);

	// --- Decide, per corner, whether/how to blend (NONE / NORMAL / DOMINANT) ---
	ivec4 blendResult = ivec4(BLEND_NONE);

	if (((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) == false) {
		float dist_03_01 = DistYCbCr(src[4], src[0]) + DistYCbCr(src[0], src[8]) + DistYCbCr(src[14], src[2]) + DistYCbCr(src[2], src[10]) + (4.0 * DistYCbCr(src[3], src[1]));
		float dist_00_02 = DistYCbCr(src[5], src[3]) + DistYCbCr(src[3], src[13]) + DistYCbCr(src[7], src[1]) + DistYCbCr(src[1], src[11]) + (4.0 * DistYCbCr(src[0], src[2]));
		bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}

	if (((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) == false) {
		float dist_04_00 = DistYCbCr(src[17], src[5]) + DistYCbCr(src[5], src[7]) + DistYCbCr(src[15], src[3]) + DistYCbCr(src[3], src[1]) + (4.0 * DistYCbCr(src[4], src[0]));
		float dist_05_03 = DistYCbCr(src[18], src[4]) + DistYCbCr(src[4], src[14]) + DistYCbCr(src[6], src[0]) + DistYCbCr(src[0], src[2]) + (4.0 * DistYCbCr(src[5], src[3]));
		bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}

	if (((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) == false) {
		float dist_00_08 = DistYCbCr(src[5], src[7]) + DistYCbCr(src[7], src[23]) + DistYCbCr(src[3], src[1]) + DistYCbCr(src[1], src[9]) + (4.0 * DistYCbCr(src[0], src[8]));
		float dist_07_01 = DistYCbCr(src[6], src[0]) + DistYCbCr(src[0], src[2]) + DistYCbCr(src[22], src[8]) + DistYCbCr(src[8], src[10]) + (4.0 * DistYCbCr(src[7], src[1]));
		bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}

	if (((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) == false) {
		float dist_05_07 = DistYCbCr(src[18], src[6]) + DistYCbCr(src[6], src[22]) + DistYCbCr(src[4], src[0]) + DistYCbCr(src[0], src[8]) + (4.0 * DistYCbCr(src[5], src[7]));
		float dist_06_00 = DistYCbCr(src[19], src[5]) + DistYCbCr(src[5], src[3]) + DistYCbCr(src[21], src[7]) + DistYCbCr(src[7], src[1]) + (4.0 * DistYCbCr(src[6], src[0]));
		bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}

	// --- Build the 4x4 output sub-pixel grid (dst), starting from center color ---
	vec3 dst[16];
	for (int n = 0; n < 16; n++) {
		dst[n] = src[0];
	}

	if (IsBlendingNeeded(blendResult) == true) {
		// Corner 2 (bottom-right) ------------------------------------------------
		float dist_01_04 = DistYCbCr(src[1], src[4]);
		float dist_03_08 = DistYCbCr(src[3], src[8]);
		bool haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08) && (v[0] != v[4]) && (v[5] != v[4]);
		bool haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04) && (v[0] != v[8]) && (v[7] != v[8]);
		bool needBlend = (blendResult[2] != BLEND_NONE);
		bool doLineBlend = (blendResult[2] >= BLEND_DOMINANT ||
			((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
			(blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
				(IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[0], src[2]) == false)) == false);

		vec3 blendPix = (DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3])) ? src[1] : src[3];
		dst[2] = bmix(dst[2], blendPix, (needBlend && doLineBlend) ? ((haveShallowLine) ? ((haveSteepLine) ? 1.0 / 3.0 : 0.25) : ((haveSteepLine) ? 0.25 : 0.00)) : 0.00);
		dst[9] = bmix(dst[9], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.25 : 0.00);
		dst[10] = bmix(dst[10], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.75 : 0.00);
		dst[11] = bmix(dst[11], blendPix, (needBlend) ? ((doLineBlend) ? ((haveSteepLine) ? 1.00 : ((haveShallowLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[12] = bmix(dst[12], blendPix, (needBlend) ? ((doLineBlend) ? 1.00 : 0.6848532563) : 0.00);
		dst[13] = bmix(dst[13], blendPix, (needBlend) ? ((doLineBlend) ? ((haveShallowLine) ? 1.00 : ((haveSteepLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[14] = bmix(dst[14], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.75 : 0.00);
		dst[15] = bmix(dst[15], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.25 : 0.00);

		// Corner 1 (bottom-left) -------------------------------------------------
		dist_01_04 = DistYCbCr(src[7], src[2]);
		dist_03_08 = DistYCbCr(src[1], src[6]);
		haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08) && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04) && (v[0] != v[6]) && (v[5] != v[6]);
		needBlend = (blendResult[1] != BLEND_NONE);
		doLineBlend = (blendResult[1] >= BLEND_DOMINANT ||
			!((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
			(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
				(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8]))));

		blendPix = (DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1])) ? src[7] : src[1];
		dst[1] = bmix(dst[1], blendPix, (needBlend && doLineBlend) ? ((haveShallowLine) ? ((haveSteepLine) ? 1.0 / 3.0 : 0.25) : ((haveSteepLine) ? 0.25 : 0.00)) : 0.00);
		dst[6] = bmix(dst[6], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.25 : 0.00);
		dst[7] = bmix(dst[7], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.75 : 0.00);
		dst[8] = bmix(dst[8], blendPix, (needBlend) ? ((doLineBlend) ? ((haveSteepLine) ? 1.00 : ((haveShallowLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[9] = bmix(dst[9], blendPix, (needBlend) ? ((doLineBlend) ? 1.00 : 0.6848532563) : 0.00);
		dst[10] = bmix(dst[10], blendPix, (needBlend) ? ((doLineBlend) ? ((haveShallowLine) ? 1.00 : ((haveSteepLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[11] = bmix(dst[11], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.75 : 0.00);
		dst[12] = bmix(dst[12], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.25 : 0.00);

		// Corner 0 (top-left) ----------------------------------------------------
		dist_01_04 = DistYCbCr(src[5], src[8]);
		dist_03_08 = DistYCbCr(src[7], src[4]);
		haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08) && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04) && (v[0] != v[4]) && (v[3] != v[4]);
		needBlend = (blendResult[0] != BLEND_NONE);
		doLineBlend = (blendResult[0] >= BLEND_DOMINANT ||
			!((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
			(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
				(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6]))));

		blendPix = (DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7])) ? src[5] : src[7];
		dst[0] = bmix(dst[0], blendPix, (needBlend && doLineBlend) ? ((haveShallowLine) ? ((haveSteepLine) ? 1.0 / 3.0 : 0.25) : ((haveSteepLine) ? 0.25 : 0.00)) : 0.00);
		dst[15] = bmix(dst[15], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.25 : 0.00);
		dst[4] = bmix(dst[4], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.75 : 0.00);
		dst[5] = bmix(dst[5], blendPix, (needBlend) ? ((doLineBlend) ? ((haveSteepLine) ? 1.00 : ((haveShallowLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[6] = bmix(dst[6], blendPix, (needBlend) ? ((doLineBlend) ? 1.00 : 0.6848532563) : 0.00);
		dst[7] = bmix(dst[7], blendPix, (needBlend) ? ((doLineBlend) ? ((haveShallowLine) ? 1.00 : ((haveSteepLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[8] = bmix(dst[8], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.75 : 0.00);
		dst[9] = bmix(dst[9], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.25 : 0.00);

		// Corner 3 (top-right) ---------------------------------------------------
		dist_01_04 = DistYCbCr(src[3], src[6]);
		dist_03_08 = DistYCbCr(src[5], src[2]);
		haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08) && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04) && (v[0] != v[2]) && (v[1] != v[2]);
		needBlend = (blendResult[3] != BLEND_NONE);
		doLineBlend = (blendResult[3] >= BLEND_DOMINANT ||
			!((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
			(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
				(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4]))));

		blendPix = (DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5])) ? src[3] : src[5];
		dst[3] = bmix(dst[3], blendPix, (needBlend && doLineBlend) ? ((haveShallowLine) ? ((haveSteepLine) ? 1.0 / 3.0 : 0.25) : ((haveSteepLine) ? 0.25 : 0.00)) : 0.00);
		dst[12] = bmix(dst[12], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.25 : 0.00);
		dst[13] = bmix(dst[13], blendPix, (needBlend && doLineBlend && haveSteepLine) ? 0.75 : 0.00);
		dst[14] = bmix(dst[14], blendPix, (needBlend) ? ((doLineBlend) ? ((haveSteepLine) ? 1.00 : ((haveShallowLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[15] = bmix(dst[15], blendPix, (needBlend) ? ((doLineBlend) ? 1.00 : 0.6848532563) : 0.00);
		dst[4] = bmix(dst[4], blendPix, (needBlend) ? ((doLineBlend) ? ((haveShallowLine) ? 1.00 : ((haveSteepLine) ? 0.75 : 0.50)) : 0.08677704501) : 0.00);
		dst[5] = bmix(dst[5], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.75 : 0.00);
		dst[6] = bmix(dst[6], blendPix, (needBlend && doLineBlend && haveShallowLine) ? 0.25 : 0.00);
	}

	// --- Reconstruct this fragment from the 4x4 sub-pixel grid ------------------
	// Lay the 16 sub-pixels out as a real row-major 4x4 grid.
	vec3 grid[16];
	grid[0]  = dst[6];  grid[1]  = dst[7];  grid[2]  = dst[8];  grid[3]  = dst[9];
	grid[4]  = dst[5];  grid[5]  = dst[0];  grid[6]  = dst[1];  grid[7]  = dst[10];
	grid[8]  = dst[4];  grid[9]  = dst[3];  grid[10] = dst[2];  grid[11] = dst[11];
	grid[12] = dst[15]; grid[13] = dst[14]; grid[14] = dst[13]; grid[15] = dst[12];

	// Bilinearly sample the grid at the sub-pixel position. This makes the edge
	// transition continuous at OUTPUT resolution, so diagonals stop reading as
	// coarse 4x stair-steps ("waves").
	vec2 p = clamp(f * 4.0 - 0.5, 0.0, 3.0);
	vec2 i0 = floor(p);
	vec2 fr = p - i0;
	ivec2 a0 = ivec2(i0);
	ivec2 a1 = min(a0 + 1, 3);
	vec3 c00 = grid[a0.y * 4 + a0.x];
	vec3 c10 = grid[a0.y * 4 + a1.x];
	vec3 c01 = grid[a1.y * 4 + a0.x];
	vec3 c11 = grid[a1.y * 4 + a1.x];
	vec3 res = mix(mix(c00, c10, fr.x), mix(c01, c11, fr.x), fr.y);

	// Optional crisp pass: unsharp against the local source average (no extra taps).
	if (SHARPEN_STRENGTH > 0.0) {
		vec3 lo = (src[0] * 2.0 + src[1] + src[3] + src[5] + src[7]) * (1.0 / 6.0);
		res = clamp(res + (res - lo) * SHARPEN_STRENGTH, 0.0, 1.0);
	}

	// --- noblend: snap to the nearest REAL pixel color --------------------------
	// Output is always a true source color (hard edges, "you see the pixels"),
	// but the edge sits on the smooth bilinear boundary above, so no waviness.
	// xBRZ only ever introduces the center + its 4 cardinal neighbours, so those
	// are the only snap candidates we need.
	if (no_blend) {
		vec3 best = src[0];
		float bd = DistYCbCrSq(res, src[0]);
		float dd;
		dd = DistYCbCrSq(res, src[1]); if (dd < bd) { bd = dd; best = src[1]; }
		dd = DistYCbCrSq(res, src[3]); if (dd < bd) { bd = dd; best = src[3]; }
		dd = DistYCbCrSq(res, src[5]); if (dd < bd) { bd = dd; best = src[5]; }
		dd = DistYCbCrSq(res, src[7]); if (dd < bd) { bd = dd; best = src[7]; }
		res = best;
	}

	COLOR = vec4(res, 1.0);
}
