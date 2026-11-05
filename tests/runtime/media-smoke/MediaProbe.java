package org.lepton.smoke;

import android.app.Activity;
import android.content.res.AssetFileDescriptor;
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
                int count = 0;
                for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
                    if (!info.isEncoder()) {
                        count++;
                        Log.i(TAG, "decoder=" + info.getName());
                    }
                }
                Log.i(TAG, "LEPTON_MEDIA_DECODERS count=" + count);
                reportDrm();
                // Audio first: games' SoundPool/MediaPlayer/WebView audio needs
                // these decoders even when video output is unavailable.
                int audio = decode(activity, "probe.ogg", "audio/vorbis");
                Log.i(TAG, "LEPTON_MEDIA_AUDIO_PASS vorbis_buffers=" + audio);
                playAudio(activity);
                int video = decode(activity, "probe.mp4", "video/avc");
                final String result = "LEPTON_MEDIA_SMOKE_PASS decoders=" + count +
                    " avc_frames=" + video + " vorbis_buffers=" + audio;
                Log.i(TAG, result);
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
