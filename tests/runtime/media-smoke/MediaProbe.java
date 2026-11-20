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

    private static void timedDecode(Activity activity, String asset, String mime, boolean toSurface) {
        String mode = toSurface ? "surface" : "buffer";
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        android.media.ImageReader reader = null;
        android.os.HandlerThread thread = null;
        final int[] images = { 0 };
        // Buffer mode: CRC32 of every frame's luma plane (visible area, row by
        // row, so strides do not matter). H.264 decoding is bit-exact, so every
        // correct decoder gives the same value.
        java.util.zip.CRC32 luma = new java.util.zip.CRC32();
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
                    if (!toSurface && info.size > 0 && hashLuma(codec.getOutputImage(output), luma)) hashed++;
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
}
