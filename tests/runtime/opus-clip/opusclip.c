// SPDX-License-Identifier: MIT
/* opusclip: encode s16le stereo 48 kHz PCM to Opus packets, or decode them
 * through opus_multistream_decode (int16), as Android's C2SoftOpusDec does,
 * and report samples at full scale and flat-topped runs.
 *   opusclip enc IN.pcm OUT.pkt BITRATE
 *   opusclip dec IN.pkt OUT.pcm
 *   opusclip gen OUT.pcm SECONDS   (deterministic loud test signal) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "opus.h"
#include "opus_multistream.h"

#define FRAME 960
int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "gen")) {
		/* Deterministic loud "master": tones and noise, driven into tanh
		 * saturation and scaled to peak at -0.1 dBFS, like limited music. */
		FILE *out = fopen(argv[2], "wb");
		long frames = 48000L * atoi(argv[3]);
		unsigned s = 12345; double lp = 0, hp = 0, ph = 0;
		for (long i = 0; i < frames; i++) {
			double t = i / 48000.0, v[2];
			for (int c = 0; c < 2; c++) {
				s = s * 1103515245u + 12345u;
				double n = ((s >> 9) & 0xffff) / 32768.0 - 1.0;
				lp += 0.05 * (n - lp); hp = n - lp;
				ph = 2 * M_PI * 55 * t * (1 + 0.01 * sin(2 * M_PI * 0.5 * t));
				double x = 0.9 * sin(ph) * (1 + 0.5 * sin(2 * M_PI * 2 * t)) +
					   0.4 * sin(2 * M_PI * 220 * t + c) + 0.3 * sin(2 * M_PI * 1760 * t) +
					   0.6 * lp + 0.3 * hp;
				v[c] = tanh(1.0 * x);
			}
			opus_int16 o[2] = { (opus_int16)lrint(v[0] * 32392), (opus_int16)lrint(v[1] * 32392) };
			fwrite(o, 2, 2, out);
		}
		return 0;
	}
	if (argc < 4) return 2;
	FILE *in = fopen(argv[2], "rb"), *out = fopen(argv[3], "wb");
	if (!in || !out) { perror("open"); return 2; }
	int err;
	if (!strcmp(argv[1], "enc")) {
		OpusEncoder *e = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
		opus_encoder_ctl(e, OPUS_SET_BITRATE(atoi(argv[4])));
		opus_int16 pcm[FRAME * 2]; unsigned char pkt[4000];
		while (fread(pcm, 4, FRAME, in) == FRAME) {
			opus_int32 n = opus_encode(e, pcm, FRAME, pkt, sizeof pkt);
			if (n < 0) return 3;
			fwrite(&n, 4, 1, out); fwrite(pkt, 1, n, out);
		}
		return 0;
	}
	unsigned char map[2] = { 0, 1 };
	OpusMSDecoder *d = opus_multistream_decoder_create(48000, 2, 1, 1, map, &err);
	opus_int16 pcm[5760 * 2], prev[2] = { 0, 0 };
	unsigned char pkt[4000]; opus_int32 n;
	long total = 0, full = 0, runs = 0, run[2] = { 0, 0 }, longest = 0;
	while (fread(&n, 4, 1, in) == 1 && fread(pkt, 1, n, in) == (size_t)n) {
		int s = opus_multistream_decode(d, pkt, n, pcm, 5760, 0);
		if (s < 0) return 4;
		fwrite(pcm, 4, s, out);
		for (int i = 0; i < s * 2; i++) {
			int c = i & 1, v = pcm[i];
			total++;
			if (v >= 32767 || v <= -32768) {
				full++;
				if (v == prev[c]) { if (++run[c] == 2) runs++; if (run[c] + 1 > longest) longest = run[c] + 1; }
				else run[c] = 0;
			} else run[c] = 0;
			prev[c] = v;
		}
	}
	printf("samples=%ld at_full_scale=%ld (%.0f per million) flat_runs>=3=%ld longest=%ld\n",
	       total, full, 1e6 * full / total, runs, longest);
	return 0;
}
