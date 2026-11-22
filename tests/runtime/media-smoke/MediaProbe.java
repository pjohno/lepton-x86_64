package org.lepton.smoke;

import android.app.Activity;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaDrm;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaPlayer;
import android.util.Log;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.VideoView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.util.UUID;

/** Offline, original test assets; no Google account or network required. */
public final class MediaProbe {
    private static final String TAG = "LeptonMediaSmoke";

    public static void start(Activity activity) {
        // am start ... --ez lepton.throughput true: the throughput phase only
        // (comparing service settings in a running instance).
        if (activity.getIntent().getBooleanExtra("lepton.throughput", false)) {
            new Thread(() -> {
                throughput(activity);
                Log.i(TAG, "LEPTON_MEDIA_THROUGHPUT_DONE");
            }, "LeptonMediaThroughput").start();
            return;
        }
        new Thread(() -> {
            try {
                int count = 0, hardware = 0;
                for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
                    if (!info.isEncoder()) {
                        count++;
                        if (info.isHardwareAccelerated()) hardware++;
                        Log.i(TAG, "decoder=" + info.getName() + " " + describe(info) +
                            " types=" + String.join(",", info.getSupportedTypes()));
                        // Android's logging drops bursts from one app; pace the list.
                        android.os.SystemClock.sleep(20);
                    }
                }
                Log.i(TAG, "LEPTON_MEDIA_DECODERS count=" + count + " hardware=" + hardware);
                reportAvcCandidates();
                reportHevcMain10();
                reportDrm();
                // Separate Android's audio output from decoding: raw PCM through
                // AudioTrack needs no codec (the path games' own mixers use);
                // a PCM WAV through MediaPlayer still needs Codec2's raw decoder.
                pcmTrack();
                playAsset(activity, "probe.wav", "WAV");
                // Audio first: games' SoundPool/MediaPlayer/WebView audio needs
                // these decoders even when video output is unavailable.
                int audio = decode(activity, "probe.ogg", "audio/vorbis");
                Log.i(TAG, "LEPTON_MEDIA_AUDIO_PASS vorbis_buffers=" + audio);
                playAudio(activity);
                int video = decode(activity, "probe.mp4", "video/avc");
                final String result = "LEPTON_MEDIA_SMOKE_PASS decoders=" + count +
                    " avc_frames=" + video + " vorbis_buffers=" + audio;
                Log.i(TAG, result);
                // Diagnostics only (never fail the probe): which H.264 decoder
                // runs, whether Android reports it as hardware, and how fast it
                // decodes 720p to CPU buffers and to a GPU-consumable Surface.
                timedDecode(activity, "probe720.mp4", "video/avc", false);
                timedDecode(activity, "probe720.mp4", "video/avc", true);
                // Codec matrix: content compared with Android's software
                // decoders, Surface output, repeat, seek/flush, resolution change.
                codecMatrix(activity);
                throughput(activity);
                File clip = new File(activity.getCacheDir(), "probe.mp4");
                try (InputStream in = activity.getAssets().open("probe.mp4");
                     FileOutputStream out = new FileOutputStream(clip)) {
                    byte[] data = new byte[8192];
                    int n;
                    while ((n = in.read(data)) != -1) out.write(data, 0, n);
                }
                activity.runOnUiThread(() -> {
                    LinearLayout layout = new LinearLayout(activity);
                    layout.setOrientation(LinearLayout.VERTICAL);
                    TextView status = new TextView(activity);
                    status.setText(result);
                    layout.addView(status);
                    VideoView view = new VideoView(activity);
                    layout.addView(view, new LinearLayout.LayoutParams(-1, -1));
                    activity.setContentView(layout);
                    view.setOnPreparedListener(player -> {
                        player.setLooping(true);
                        view.start();
                    });
                    view.setOnInfoListener((player, what, extra) -> {
                        if (what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START)
                            Log.i(TAG, "LEPTON_MEDIA_VIDEO_RENDERING_START");
                        return false;
                    });
                    view.setOnErrorListener((player, what, extra) -> {
                        Log.e(TAG, "LEPTON_MEDIA_VIDEO_FAIL what=" + what + " extra=" + extra);
                        return true;
                    });
                    view.setVideoPath(clip.getAbsolutePath());
                });
            } catch (Throwable error) {
                Log.e(TAG, "LEPTON_MEDIA_SMOKE_FAIL", error);
                activity.runOnUiThread(() -> {
                    TextView status = new TextView(activity);
                    status.setText("LEPTON_MEDIA_SMOKE_FAIL " + error);
                    activity.setContentView(status);
                });
            }
        }, "LeptonMediaProbe").start();
    }

    private static String describe(MediaCodecInfo info) {
        return "hw=" + info.isHardwareAccelerated() + " sw_only=" + info.isSoftwareOnly() +
            " vendor=" + info.isVendor() + " canonical=" + info.getCanonicalName();
    }

    // Every decoder that can take H.264, in the order MediaCodec.createDecoderByType
    // considers them (MediaCodecList order), so a newly added decoder's rank shows.
    private static void reportAvcCandidates() {
        int rank = 0;
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder()) continue;
            for (String type : info.getSupportedTypes()) {
                if (type.equalsIgnoreCase("video/avc")) {
                    Log.i(TAG, "LEPTON_MEDIA_AVC_CANDIDATE rank=" + rank++ + " name=" + info.getName() +
                        " " + describe(info));
                    android.os.SystemClock.sleep(20);
                }
            }
        }
        if (rank == 0) Log.w(TAG, "LEPTON_MEDIA_AVC_CANDIDATE none");
    }

    // Decodes the 720p clip with the decoder Android selects, either to
    // ByteBuffers (CPU copy) or to an ImageReader Surface (graphic buffers, the
    // path players use). Reports decoder, Android's hardware flag, frames and
    // throughput. Throughput alone does not prove hardware decoding; compare
    // with host evidence (e.g. DRM fdinfo video-engine time). Never throws.
    // Adds the visible luma rows of a decoded frame to the CRC; false without an image.
    // Players (VLC, ExoPlayer) choose by the stream's profile, not only the
    // media type: a decoder that does not list HEVC Main10 is skipped for
    // 10-bit streams. Report what each HEVC decoder lists and what Android
    // picks for a 1080p Main10 format.
    private static void reportHevcMain10() {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder()) continue;
            for (String type : info.getSupportedTypes()) {
                if (!type.equalsIgnoreCase("video/hevc")) continue;
                boolean main10 = false;
                StringBuilder profiles = new StringBuilder();
                for (MediaCodecInfo.CodecProfileLevel pl : info.getCapabilitiesForType(type).profileLevels) {
                    if (pl.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10) main10 = true;
                    String token = Integer.toString(pl.profile);
                    if (!(" " + profiles + " ").contains(" " + token + " ")) {
                        profiles.append(profiles.length() == 0 ? "" : " ").append(token);
                    }
                }
                Log.i(TAG, "LEPTON_MEDIA_HEVC_PROFILES name=" + info.getName() +
                    " main10=" + main10 + " profiles=" + profiles);
            }
        }
        MediaFormat format = MediaFormat.createVideoFormat("video/hevc", 1920, 1080);
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10);
        String found = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format);
        Log.i(TAG, "LEPTON_MEDIA_HEVC_MAIN10 decoder=" + (found == null ? "none" : found));
        reportLargestSizes();
    }

    // Size limits Android lists per video decoder (patches 0026/0027 take the
    // c2.ffmpeg.* ones from VA), and what it picks for an 8K 24 fps stream.
    private static void reportLargestSizes() {
        String[] mimes = { "video/avc", "video/hevc", "video/x-vnd.on2.vp9", "video/av01" };
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder()) continue;
            for (String type : info.getSupportedTypes()) {
                if (!java.util.Arrays.asList(mimes).contains(type.toLowerCase())) continue;
                MediaCodecInfo.VideoCapabilities video =
                    info.getCapabilitiesForType(type).getVideoCapabilities();
                if (video == null) continue;
                Log.i(TAG, "LEPTON_MEDIA_SIZE_LIMIT name=" + info.getName() + " type=" + type +
                    " width=" + video.getSupportedWidths() + " height=" + video.getSupportedHeights() +
                    " 8k24=" + video.areSizeAndRateSupported(7680, 4320, 24));
                android.os.SystemClock.sleep(20);
            }
        }
        for (String mime : mimes) {
            MediaFormat format = MediaFormat.createVideoFormat(mime, 7680, 4320);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 24);
            String found = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format);
            Log.i(TAG, "LEPTON_MEDIA_8K mime=" + mime + " decoder=" + (found == null ? "none" : found));
        }
    }

    private static boolean hashLuma(android.media.Image image, java.util.zip.CRC32 crc) {
        if (image == null) return false;
        try {
            android.graphics.Rect crop = image.getCropRect();
            android.media.Image.Plane y = image.getPlanes()[0];
            ByteBuffer data = y.getBuffer();
            int stride = y.getRowStride(), pixel = y.getPixelStride();
            byte[] row = new byte[crop.width()];
            for (int line = crop.top; line < crop.bottom; line++) {
                int base = line * stride + crop.left * pixel;
                for (int x = 0; x < row.length; x++) row[x] = data.get(base + x * pixel);
                crc.update(row);
            }
            return true;
        } finally {
            image.close();
        }
    }

    // First frame only: CRC32 of each visible luma row, 64 rows per log line,
    // to tell a row shift from changed pixel values when decoders disagree.
    private static void logLumaRows(android.media.Image image) {
        if (image == null) return;
        try {
            android.graphics.Rect crop = image.getCropRect();
            android.media.Image.Plane y = image.getPlanes()[0];
            ByteBuffer data = y.getBuffer();
            int stride = y.getRowStride(), pixel = y.getPixelStride();
            byte[] row = new byte[crop.width()];
            StringBuilder line = new StringBuilder();
            java.util.zip.CRC32 crc = new java.util.zip.CRC32();
            Log.i(TAG, "LEPTON_MEDIA_AVC_ROWS crop=" + crop.flattenToString() + " stride=" + stride);
            for (int r = crop.top; r < crop.bottom; r++) {
                int base = r * stride + crop.left * pixel;
                for (int x = 0; x < row.length; x++) row[x] = data.get(base + x * pixel);
                crc.reset();
                crc.update(row);
                line.append(Long.toHexString(crc.getValue())).append(',');
                if ((r - crop.top) % 64 == 63 || r == crop.bottom - 1) {
                    Log.i(TAG, "LEPTON_MEDIA_AVC_ROWS " + (r - crop.top) / 64 + " " + line);
                    line.setLength(0);
                }
            }
        } finally {
            image.close();
        }
    }

    private static void timedDecode(Activity activity, String asset, String mime, boolean toSurface) {
        String mode = toSurface ? "surface" : "buffer";
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        android.media.ImageReader reader = null;
        android.os.HandlerThread thread = null;
        final int[] images = { 0 };
        // Buffer mode: CRC32 of each frame's luma plane (visible area, row by
        // row, so strides do not matter), logged per frame and combined. H.264
        // decoding is bit-exact, so every correct decoder gives the same values.
        java.util.zip.CRC32 luma = new java.util.zip.CRC32();
        StringBuilder frameCrcs = new StringBuilder();
        int hashed = 0;
        try (AssetFileDescriptor fd = activity.getAssets().openFd(asset)) {
            extractor.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            MediaFormat format = null;
            for (int i = 0; i < extractor.getTrackCount() && format == null; i++) {
                MediaFormat candidate = extractor.getTrackFormat(i);
                if (mime.equals(candidate.getString(MediaFormat.KEY_MIME))) {
                    extractor.selectTrack(i);
                    format = candidate;
                }
            }
            if (format == null) throw new IllegalStateException("Missing test track " + mime);
            int width = format.getInteger(MediaFormat.KEY_WIDTH), height = format.getInteger(MediaFormat.KEY_HEIGHT);
            codec = MediaCodec.createDecoderByType(mime);
            android.view.Surface surface = null;
            if (toSurface) {
                thread = new android.os.HandlerThread("LeptonImageReader");
                thread.start();
                reader = android.media.ImageReader.newInstance(width, height,
                    android.graphics.ImageFormat.PRIVATE, 4,
                    android.hardware.HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE);
                reader.setOnImageAvailableListener(r -> {
                    android.media.Image image = r.acquireNextImage();
                    if (image != null) { images[0]++; image.close(); }
                }, new android.os.Handler(thread.getLooper()));
                surface = reader.getSurface();
            }
            codec.configure(format, surface, null, 0);
            codec.start();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            int frames = 0;
            boolean inputEnd = false, outputEnd = false;
            long start = android.os.SystemClock.elapsedRealtime();
            long deadline = start + 30000;
            while (!outputEnd && android.os.SystemClock.elapsedRealtime() < deadline) {
                if (!inputEnd) {
                    int input = codec.dequeueInputBuffer(10000);
                    if (input >= 0) {
                        int size = extractor.readSampleData(codec.getInputBuffer(input), 0);
                        if (size < 0) {
                            codec.queueInputBuffer(input, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputEnd = true;
                        } else {
                            codec.queueInputBuffer(input, 0, size, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }
                int output = codec.dequeueOutputBuffer(info, 10000);
                if (output >= 0) {
                    if (info.size > 0 || toSurface) frames++;
                    if (!toSurface && info.size > 0) {
                        java.util.zip.CRC32 frame = new java.util.zip.CRC32();
                        if (hashed == 0) logLumaRows(codec.getOutputImage(output));
                        if (hashLuma(codec.getOutputImage(output), frame)) {
                            hashed++;
                            long value = frame.getValue();
                            for (int b = 0; b < 4; b++) luma.update((int) (value >>> (8 * b)) & 0xff);
                            if (frameCrcs.length() < 2000) frameCrcs.append(Long.toHexString(value)).append(',');
                        }
                    }
                    outputEnd = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    codec.releaseOutputBuffer(output, toSurface && !outputEnd);
                }
            }
            long ms = Math.max(1, android.os.SystemClock.elapsedRealtime() - start);
            String color = "";
            try {
                MediaFormat out = codec.getOutputFormat();
                if (out.containsKey(MediaFormat.KEY_COLOR_FORMAT))
                    color = " color_format=0x" + Integer.toHexString(out.getInteger(MediaFormat.KEY_COLOR_FORMAT));
            } catch (Throwable ignored) { }
            android.os.SystemClock.sleep(200);  // let the last images arrive
            MediaCodecInfo selected = codec.getCodecInfo();
            Log.i(TAG, (outputEnd ? "LEPTON_MEDIA_AVC_DECODE" : "LEPTON_MEDIA_AVC_DECODE_INCOMPLETE") +
                " mode=" + mode + " decoder=" + selected.getName() + " " + describe(selected) +
                " size=" + width + "x" + height + " frames=" + frames +
                (toSurface ? " surface_images=" + images[0] :
                    " luma_crc=" + Long.toHexString(luma.getValue()) + " luma_frames=" + hashed) + " ms=" + ms +
                " fps=" + (frames * 1000L / ms) + color);
            if (!toSurface) Log.i(TAG, "LEPTON_MEDIA_AVC_FRAME_CRCS " + frameCrcs);
        } catch (Throwable error) {
            Log.w(TAG, "LEPTON_MEDIA_AVC_DECODE_FAIL mode=" + mode + " " + error);
        } finally {
            if (codec != null) {
                try { codec.stop(); } catch (Throwable ignored) { }
                codec.release();
            }
            if (reader != null) reader.close();
            if (thread != null) thread.quitSafely();
            extractor.release();
        }
    }

    // Informational: which DRM schemes Android offers (Widevine only when a
    // bundle was made with --with-widevine). Never fails the probe.
    private static final UUID WIDEVINE = new UUID(0xEDEF8BA979D64ACEL, 0xA3C827DCD51D21EDL);
    private static void reportDrm() {
        try {
            if (!MediaDrm.isCryptoSchemeSupported(WIDEVINE)) {
                Log.i(TAG, "LEPTON_MEDIA_DRM widevine=absent");
                return;
            }
            try (MediaDrm drm = new MediaDrm(WIDEVINE)) {
                Log.i(TAG, "LEPTON_MEDIA_DRM widevine=present securityLevel=" +
                    drm.getPropertyString("securityLevel") + " version=" +
                    drm.getPropertyString(MediaDrm.PROPERTY_VERSION) + " systemId=" +
                    drm.getPropertyString("systemId"));
            }
        } catch (Throwable error) {
            Log.w(TAG, "LEPTON_MEDIA_DRM widevine=error " + error);
        }
    }

    // Codec-free output: a 1 s tone written as PCM to a media-usage AudioTrack
    // (what a music player's decoded output becomes). played_frames=0 means
    // Android's output to the host is not consuming audio. Never fails the probe.
    private static void pcmTrack() {
        AudioTrack track = null;
        try {
            final int rate = 44100;
            short[] tone = new short[rate];
            for (int i = 0; i < tone.length; i++)
                tone[i] = (short) (Math.sin(2 * Math.PI * 440 * i / rate) * 8000);
            track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STREAM).build();
            track.play();
            // Non-blocking: a stalled output path must not stall the probe.
            int written = track.write(tone, 0, tone.length, AudioTrack.WRITE_NON_BLOCKING);
            android.os.SystemClock.sleep(1500);
            int played = track.getPlaybackHeadPosition();
            Log.i(TAG, (written > 0 && played > 0 ? "LEPTON_MEDIA_PCM_TRACK_PASS" : "LEPTON_MEDIA_PCM_TRACK_FAIL") +
                " written=" + written + " played_frames=" + played + " rate=" + track.getSampleRate());
        } catch (Throwable error) {
            Log.e(TAG, "LEPTON_MEDIA_PCM_TRACK_FAIL", error);
        } finally {
            if (track != null) track.release();
        }
    }

    // MediaPlayer on an asset (extractor + decoder + AudioTrack); diagnostic only.
    private static void playAsset(Activity activity, String asset, String label) {
        try {
            AssetFileDescriptor fd = activity.getAssets().openFd(asset);
            MediaPlayer player = new MediaPlayer();
            player.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            // Decoder failures (e.g. NO_MEMORY) arrive after start().
            player.setOnErrorListener((mp, what, extra) -> {
                Log.e(TAG, "LEPTON_MEDIA_" + label + "_PLAYBACK_FAIL what=" + what + " extra=" + extra);
                return true;
            });
            player.setOnCompletionListener(mp -> Log.i(TAG, "LEPTON_MEDIA_" + label + "_PLAYBACK_DONE"));
            player.prepare();
            player.start();
            Log.i(TAG, "LEPTON_MEDIA_" + label + "_PLAYBACK_STARTED duration_ms=" + player.getDuration());
        } catch (Throwable error) {
            Log.e(TAG, "LEPTON_MEDIA_" + label + "_PLAYBACK_FAIL " + error);
        }
    }

    // Plays the generated tone through MediaPlayer (decoder + AudioTrack), the
    // path many games use; logs the outcome without failing the probe.
    private static void playAudio(Activity activity) {
        try {
            android.content.res.AssetFileDescriptor fd = activity.getAssets().openFd("probe.ogg");
            android.media.MediaPlayer player = new android.media.MediaPlayer();
            player.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            player.setOnErrorListener((mp, what, extra) -> {
                Log.e(TAG, "LEPTON_MEDIA_PLAYBACK_FAIL what=" + what + " extra=" + extra);
                return true;
            });
            player.setOnCompletionListener(mp -> Log.i(TAG, "LEPTON_MEDIA_PLAYBACK_DONE"));
            player.prepare();
            player.start();
            Log.i(TAG, "LEPTON_MEDIA_PLAYBACK_STARTED duration_ms=" + player.getDuration());
        } catch (Exception error) {
            Log.e(TAG, "LEPTON_MEDIA_PLAYBACK_FAIL", error);
        }
    }

    private static int decode(Activity activity, String asset, String mime) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        boolean started = false;
        try (AssetFileDescriptor fd = activity.getAssets().openFd(asset)) {
            extractor.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            int track = -1;
            MediaFormat format = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat candidate = extractor.getTrackFormat(i);
                if (mime.equals(candidate.getString(MediaFormat.KEY_MIME))) {
                    track = i;
                    format = candidate;
                    break;
                }
            }
            if (track < 0) throw new IllegalStateException("Missing test track " + mime);
            extractor.selectTrack(track);
            codec = MediaCodec.createDecoderByType(mime);
            Log.i(TAG, "Selected " + codec.getName() + " for " + mime);
            codec.configure(format, null, null, 0);
            codec.start();
            started = true;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            int buffers = 0;
            boolean inputEnd = false, outputEnd = false;
            long deadline = android.os.SystemClock.elapsedRealtime() + 15000;
            while (!outputEnd && android.os.SystemClock.elapsedRealtime() < deadline) {
                if (!inputEnd) {
                    int input = codec.dequeueInputBuffer(10000);
                    if (input >= 0) {
                        ByteBuffer data = codec.getInputBuffer(input);
                        int size = extractor.readSampleData(data, 0);
                        if (size < 0) {
                            codec.queueInputBuffer(input, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputEnd = true;
                        } else {
                            codec.queueInputBuffer(input, 0, size, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }
                int output = codec.dequeueOutputBuffer(info, 10000);
                if (output >= 0) {
                    if (info.size > 0) buffers++;
                    outputEnd = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    codec.releaseOutputBuffer(output, false);
                }
            }
            if (!outputEnd || buffers == 0)
                throw new IllegalStateException("Decode incomplete " + mime + " buffers=" + buffers);
            return buffers;
        } finally {
            if (codec != null) {
                if (started) codec.stop();
                codec.release();
            }
            extractor.release();
        }
    }

    // ---- Codec matrix ---------------------------------------------------------
    // Each clip is decoded to ByteBuffers by Android's own software decoder (the
    // reference) and by the decoder Android selects, and the per-frame CRCs of
    // the visible luma are compared; H.264/HEVC/VP9/AV1 decoding is bit-exact.
    // 10-bit output is not compared (reference: 16-bit samples; the FFmpeg
    // service converts to 8-bit). Then the selected decoder renders to a
    // Surface. One LEPTON_MEDIA_CODEC line per clip. Whether the GPU decoded is
    // in the service's LEPTON_VA_SESSION lines and the host's DRM counters.
    private static final String[][] CLIPS = {
        { "probe1080.mp4", "video/avc", "h264-1080p" },
        { "probe-hevc.mp4", "video/hevc", "hevc-main" },
        { "probe-hevc10.mp4", "video/hevc", "hevc-main10" },
        { "probe-vp9.webm", "video/x-vnd.on2.vp9", "vp9" },
        { "probe-av1.mp4", "video/av01", "av1" },
        { "probe-reschange.ts", "video/avc", "h264-resolution-change" },
        // No VA-API driver decodes 4:4:4: exercises FFmpeg's software fallback
        // inside the service (LEPTON_VA_SESSION decode=software).
        { "probe-h264-444.mp4", "video/avc", "h264-high444" },
        // Copy-back at 1080p 10-bit and 4K (LEPTON_MEDIA_THROUGHPUT as well).
        { "probe-hevc10-1080.mp4", "video/hevc", "hevc-main10-1080p" },
        { "probe-h264-2160.mp4", "video/avc", "h264-2160p" },
        { "probe-hevc-2160.mp4", "video/hevc", "hevc-main-2160p" },
        { "probe-hevc10-2160.mp4", "video/hevc", "hevc-main10-2160p" },
        { "probe-vp9-2160.webm", "video/x-vnd.on2.vp9", "vp9-2160p" },
        { "probe-av1-2160.mp4", "video/av01", "av1-2160p" },
    };

    // Clips decoded as fast as possible, without CRCs: frames per second to
    // ByteBuffers and to a Surface, with the decoder Android selects.
    private static final String[][] THROUGHPUT = {
        { "probe1080.mp4", "video/avc", "h264-1080p" },
        { "probe-hevc10-1080.mp4", "video/hevc", "hevc-main10-1080p" },
        { "probe-h264-2160.mp4", "video/avc", "h264-2160p" },
        { "probe-hevc-2160.mp4", "video/hevc", "hevc-main-2160p" },
        { "probe-hevc10-2160.mp4", "video/hevc", "hevc-main10-2160p" },
        { "probe-vp9-2160.webm", "video/x-vnd.on2.vp9", "vp9-2160p" },
        { "probe-av1-2160.mp4", "video/av01", "av1-2160p" },
    };

    private static void throughput(Activity activity) {
        for (String[] clip : THROUGHPUT) {
            for (boolean toSurface : new boolean[] { false, true }) {
                Run run = decodeClip(activity, clip[0], clip[1], null, toSurface, -1, 0, false);
                Log.i(TAG, "LEPTON_MEDIA_THROUGHPUT clip=" + clip[2] + " mode=" + (toSurface ? "surface" : "buffer") +
                    " decoder=" + run.decoder + " frames=" + run.frames +
                    (toSurface ? " surface_images=" + run.surfaceImages : "") + " ms=" + run.ms +
                    " fps=" + (run.ms > 0 ? String.format(java.util.Locale.ROOT, "%.1f", run.frames * 1000.0 / run.ms) : "0") +
                    (run.error != null ? " error=\"" + run.error + "\"" : ""));
                android.os.SystemClock.sleep(20);
            }
        }
    }

    private static final class Run {
        String decoder = "?";
        java.util.List<Long> crcs = new java.util.ArrayList<>();
        java.util.List<Long> afterSeek = new java.util.ArrayList<>();
        int frames, surfaceImages = -1, bits = 8;
        boolean complete;
        long ms;
        String error;
    }

    private static String softwareDecoder(String mime) {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder() || !info.getName().startsWith("c2.android.")) continue;
            for (String type : info.getSupportedTypes()) {
                if (type.equalsIgnoreCase(mime)) return info.getName();
            }
        }
        return null;
    }

    // Decodes asset with decoder (null: the one Android selects). seekAfter >= 0:
    // after that many output frames, flush and seek to seekUs, and record the
    // CRCs that follow in afterSeek. Never throws; errors go to Run.error.
    private static Run decodeClip(Activity activity, String asset, String mime, String decoder,
                                  boolean toSurface, int seekAfter, long seekUs) {
        return decodeClip(activity, asset, mime, decoder, toSurface, seekAfter, seekUs, true);
    }

    // hash false: no luma CRCs (throughput runs; hashing a 4K frame in Java
    // takes longer than decoding it).
    private static Run decodeClip(Activity activity, String asset, String mime, String decoder,
                                  boolean toSurface, int seekAfter, long seekUs, boolean hash) {
        Run run = new Run();
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        android.media.ImageReader reader = null;
        android.os.HandlerThread thread = null;
        final int[] images = { 0 };
        try (AssetFileDescriptor fd = activity.getAssets().openFd(asset)) {
            extractor.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            MediaFormat format = null;
            for (int i = 0; i < extractor.getTrackCount() && format == null; i++) {
                MediaFormat candidate = extractor.getTrackFormat(i);
                if (mime.equals(candidate.getString(MediaFormat.KEY_MIME))) {
                    extractor.selectTrack(i);
                    format = candidate;
                }
            }
            if (format == null) throw new IllegalStateException("no " + mime + " track");
            codec = decoder != null ? MediaCodec.createByCodecName(decoder) : MediaCodec.createDecoderByType(mime);
            run.decoder = codec.getName();
            android.view.Surface surface = null;
            if (toSurface) {
                thread = new android.os.HandlerThread("LeptonMatrixReader");
                thread.start();
                reader = android.media.ImageReader.newInstance(
                    format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT),
                    android.graphics.ImageFormat.PRIVATE, 4,
                    android.hardware.HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE);
                reader.setOnImageAvailableListener(r -> {
                    android.media.Image image = r.acquireNextImage();
                    if (image != null) { images[0]++; image.close(); }
                }, new android.os.Handler(thread.getLooper()));
                surface = reader.getSurface();
            }
            codec.configure(format, surface, null, 0);
            codec.start();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean inputEnd = false, outputEnd = false, seeked = false;
            long start = android.os.SystemClock.elapsedRealtime();
            long lastProgress = start;
            while (!outputEnd) {
                long now = android.os.SystemClock.elapsedRealtime();
                if (now - lastProgress > 10000) throw new IllegalStateException("stalled: no output for 10 s");
                if (!inputEnd) {
                    int input = codec.dequeueInputBuffer(10000);
                    if (input >= 0) {
                        int size = extractor.readSampleData(codec.getInputBuffer(input), 0);
                        if (size < 0) {
                            codec.queueInputBuffer(input, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputEnd = true;
                        } else {
                            codec.queueInputBuffer(input, 0, size, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }
                int output = codec.dequeueOutputBuffer(info, 10000);
                if (output < 0) continue;
                lastProgress = android.os.SystemClock.elapsedRealtime();
                outputEnd = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                if (info.size > 0 || (toSurface && !outputEnd)) {
                    run.frames++;
                    if (!toSurface && hash) {
                        android.media.Image image = codec.getOutputImage(output);
                        if (image != null) {
                            if (image.getFormat() == 0x36 /* YCBCR_P010 */) run.bits = 10;
                            java.util.zip.CRC32 crc = new java.util.zip.CRC32();
                            if (hashLuma(image, crc)) (seeked ? run.afterSeek : run.crcs).add(crc.getValue());
                        }
                    }
                }
                codec.releaseOutputBuffer(output, toSurface && !outputEnd);
                if (seekAfter >= 0 && !seeked && run.frames == seekAfter && !outputEnd) {
                    codec.flush();
                    extractor.seekTo(seekUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC);
                    inputEnd = false;
                    seeked = true;
                }
            }
            run.complete = true;
            run.ms = android.os.SystemClock.elapsedRealtime() - start;
            if (toSurface) {
                android.os.SystemClock.sleep(200);
                run.surfaceImages = images[0];
            }
        } catch (Throwable error) {
            run.error = error.getClass().getSimpleName() + ": " + error.getMessage();
        } finally {
            if (codec != null) {
                try { codec.stop(); } catch (Throwable ignored) { }
                codec.release();
            }
            if (reader != null) reader.close();
            if (thread != null) thread.quitSafely();
            extractor.release();
        }
        return run;
    }

    private static String crcList(java.util.List<Long> crcs) {
        StringBuilder out = new StringBuilder();
        for (Long crc : crcs) out.append(out.length() == 0 ? "" : ",").append(Long.toHexString(crc));
        return out.toString();
    }

    // Up to 12 frame numbers (of a) whose CRC differs from b, for diagnosis.
    private static String differing(java.util.List<Long> a, java.util.List<Long> b, int bOffset) {
        StringBuilder out = new StringBuilder();
        int n = 0;
        for (int i = 0; i < a.size() && n < 12; i++) {
            if (i + bOffset >= b.size() || !a.get(i).equals(b.get(i + bOffset))) {
                out.append(n++ == 0 ? "" : ",").append(i);
            }
        }
        return out.toString();
    }

    private static int matching(java.util.List<Long> a, java.util.List<Long> b, int bOffset) {
        int same = 0;
        for (int i = 0; i < a.size() && i + bOffset < b.size(); i++) {
            if (a.get(i).equals(b.get(i + bOffset))) same++;
        }
        return same;
    }

    private static void codecMatrix(Activity activity) {
        for (String[] clip : CLIPS) {
            String asset = clip[0], mime = clip[1], name = clip[2];
            String refName = softwareDecoder(mime);
            Run ref = refName != null ? decodeClip(activity, asset, mime, refName, false, -1, 0) : null;
            Run sel = decodeClip(activity, asset, mime, null, false, -1, 0);
            Run surf = sel.error == null ? decodeClip(activity, asset, mime, null, true, -1, 0) : null;
            String result;
            int match = ref != null ? matching(sel.crcs, ref.crcs, 0) : 0;
            if (sel.error != null && sel.error.contains("stalled")) result = "INCOMPLETE";
            else if (sel.error != null) result = "UNSUPPORTED";
            else if (ref == null || ref.error != null) result = "NO_REFERENCE";
            else if (sel.bits != 8 || ref.bits != 8) result = "NOT_COMPARED";
            else if (sel.crcs.size() == ref.crcs.size() && match == ref.crcs.size() && match > 0) result = "PASS";
            else result = "MISMATCH";
            if (surf != null && result.equals("PASS") && (surf.error != null || surf.surfaceImages < 1)) result = "SURFACE_FAIL";
            Log.i(TAG, "LEPTON_MEDIA_CODEC clip=" + name + " mime=" + mime + " selected=" + sel.decoder +
                " reference=" + (refName != null ? refName : "none") +
                " frames=" + sel.crcs.size() + "/" + (ref != null ? ref.crcs.size() : -1) +
                " crc_match=" + match + " bits=" + sel.bits + "/" + (ref != null ? ref.bits : -1) +
                " surface_frames=" + (surf != null ? surf.frames : -1) +
                " surface_images=" + (surf != null ? surf.surfaceImages : -1) +
                " ms=" + sel.ms + " result=" + result +
                (result.equals("MISMATCH") ? " differing_frames=" + differing(sel.crcs, ref.crcs, 0) : "") +
                (sel.error != null ? " error=\"" + sel.error + "\"" : "") +
                (surf != null && surf.error != null ? " surface_error=\"" + surf.error + "\"" : "") +
                (ref != null && ref.error != null ? " reference_error=\"" + ref.error + "\"" : ""));
            if (result.equals("NO_REFERENCE") || result.equals("NOT_COMPARED")) {
                // Compared off-device (host FFmpeg) and between builds.
                Log.i(TAG, "LEPTON_MEDIA_CODEC_CRCS clip=" + name + " selected=" + crcList(sel.crcs));
            }
            if (result.equals("MISMATCH")) {
                // Full per-frame CRC lists, to tell a dropped or extra frame
                // (lists shifted) from changed pixels.
                Log.i(TAG, "LEPTON_MEDIA_CODEC_CRCS clip=" + name + " selected=" + crcList(sel.crcs));
                Log.i(TAG, "LEPTON_MEDIA_CODEC_CRCS clip=" + name + " reference=" + crcList(ref.crcs));
            }
            android.os.SystemClock.sleep(20);
            if (name.equals("h264-1080p") && ref != null && ref.error == null) {
                repeatAndSeek(activity, asset, mime, ref);
            }
        }
    }

    // The selected decoder three times (decoder and buffer clean-up), then a
    // flush + seek to the second key frame (1 s; clips have one per second).
    private static void repeatAndSeek(Activity activity, String asset, String mime, Run ref) {
        int identical = 0;
        String decoder = "?";
        for (int i = 0; i < 3; i++) {
            Run again = decodeClip(activity, asset, mime, null, false, -1, 0);
            decoder = again.decoder;
            if (again.error == null && again.crcs.equals(ref.crcs)) identical++;
        }
        Log.i(TAG, "LEPTON_MEDIA_REPEAT decoder=" + decoder + " runs=3 identical_to_reference=" + identical +
            " result=" + (identical == 3 ? "PASS" : "FAIL"));
        Run seek = decodeClip(activity, asset, mime, null, false, 15, 1000000L);
        int keyframe = 30;  // 30 fps, one key frame per second
        int match = matching(seek.afterSeek, ref.crcs, keyframe);
        boolean pass = seek.error == null && !seek.afterSeek.isEmpty() &&
            match == seek.afterSeek.size() && seek.afterSeek.size() == ref.crcs.size() - keyframe;
        Log.i(TAG, "LEPTON_MEDIA_SEEK decoder=" + seek.decoder + " before=" + seek.crcs.size() +
            " after=" + seek.afterSeek.size() + "/" + (ref.crcs.size() - keyframe) + " crc_match=" + match +
            " result=" + (pass ? "PASS" : "FAIL") +
            (pass ? "" : " differing_frames=" + differing(seek.afterSeek, ref.crcs, keyframe)) +
            (seek.error != null ? " error=\"" + seek.error + "\"" : ""));
    }
}
