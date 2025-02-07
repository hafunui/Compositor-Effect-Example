#[compute]
#version 450

//process 16 by 16 chunk per invocation
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, binding=0, set=0) restrict uniform image2D image1; 	//write
layout(binding=0, set=1) uniform sampler2D sampler1; 				//read

layout(push_constant, std430) uniform Params {
	vec2 screen_size;	//dimensions of buffer we're writing to
	float dither;		//[0.0 - 0.5] amount of dithering
	int is_gaussian;	//[0 - 1] 0 is box blur, 1 is gaussian weighting
	int kern_samples;	//number of samples per pass
	int kern_width;		//width of the blur
	int pass;			//[1,2,3] 1 horizontal blur, 2 vertical blur, 3 copy to screen
} p;

// Random number generator for dithering
float rng(vec2 seed) {
	return fract(sin(dot(seed.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

// Apply dithering to the kernel offset
float get_dither(float ks) {
	if (p.dither <= 0.0) return 0.0; //avoid some math if we don't need dithering
	return (rng(gl_GlobalInvocationID.xy / p.screen_size) * 2.0 - 1.0) * ks * p.dither;
}

// Compute Gaussian weight for a given distance and sigma
float gaussian(float x, float sigma) {
	return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159) * sigma);
}

// Precompute Gaussian weights for the kernel
void compute_gaussian_weights(int samples, float sigma, out float weights[161]) {
	float total_weight = 0.0;
	for (int i = 0; i <= samples; i++) {
		float x = float(i) - float(samples) / 2.0;
		weights[i] = gaussian(x, sigma);
		total_weight += weights[i];
	}
	// Normalize weights
	for (int i = 0; i <= samples; i++) {
		weights[i] /= total_weight;
	}
}

void main() {
	//coordinates
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv = vec2(pixel) / p.screen_size;

	// Early exit if the pixel is outside the screen bounds
	if (pixel.x >= p.screen_size.x || pixel.y >= p.screen_size.y) return;

	// Kernel parameters
	float kern_spacing = float(p.kern_width) / float(p.kern_samples);
	float kern_half = float(p.kern_width) * 0.5;
	
	// Gaussian weights
	float weights[161];
	float sigma = float(p.kern_width) / (6.0 * float(p.kern_width)/float(p.kern_samples)); // Adjust sigma based on kernel width
	if(p.is_gaussian == 1) {
		compute_gaussian_weights(p.kern_samples, sigma, weights);
	}
	
	vec4 col = vec4(0.0);
	vec2 coord;

	if (p.pass == 1) {
		// Horizontal pass
		for (int i = 0; i <= p.kern_samples; i++) {
			coord.x = pixel.x + (i * kern_spacing) - kern_half + get_dither(kern_spacing);
			coord.y = pixel.y;
			if(p.is_gaussian == 1) col += texture(sampler1, clamp(coord / p.screen_size, 0.0, 1.0)) * weights[i];
			else col += texture(sampler1, clamp(coord / p.screen_size, 0.0, 1.0));
		}
		if(p.is_gaussian == 0) col.rgb /= float(p.kern_samples + 1);
		imageStore(image1, pixel, col);
	} else if (p.pass == 2) {
		// Vertical pass
		for (int j = 0; j <= p.kern_samples; j++) {
			coord.x = pixel.x;
			coord.y = pixel.y + (j * kern_spacing) - kern_half + get_dither(kern_spacing);
			if(p.is_gaussian == 1) col += texture(sampler1, clamp(coord / p.screen_size, 0.0, 1.0)) * weights[j];
			else col += texture(sampler1, clamp(coord / p.screen_size, 0.0, 1.0));
		}
		if(p.is_gaussian == 0) col.rgb /= float(p.kern_samples + 1);
		imageStore(image1, pixel, col); 
	} else if (p.pass == 3) {
		//copy buffer to screen
		col = texture(sampler1, uv);
		imageStore(image1, pixel, col);
	}
}