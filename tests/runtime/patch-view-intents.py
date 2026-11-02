#!/usr/bin/env python3
"""Replace only the reviewed, overly broad Valve VIEW interceptor in a copy."""
from pathlib import Path
import sys

original = '''            if (mRequest.intent != null
                    && Intent.ACTION_VIEW.equals(mRequest.intent.getAction())) {
                final android.net.Uri uri = mRequest.intent.getData();

                if (uri != null) {
                    Slog.i(TAG, "Intercepted VIEW: " + uri);

                    final String url = uri.toString();

                    try (java.io.FileWriter writer = new java.io.FileWriter("/lepton/steam.pipe", true)) {
                        writer.write("steam://openurl/" + url);
                        writer.write("\\n");
                    } catch (java.io.IOException e) {
                        Slog.e(TAG, "Failed to write VIEW URL", e);
                    }
                }

                return START_SUCCESS;
            }
'''

def transform(source):
    if source.count(original) != 1:
        raise ValueError("Expected exactly one reviewed Valve VIEW interceptor")
    patch = Path(__file__).resolve().parents[2] / (
        "image-14/android_vendor_valve/patches/base-patches-34/frameworks/base/"
        "0023-lepton-Intercept-VIEW-intent-for-URIs-and-forward-it.patch")
    replacement = "\n".join(line[1:] for line in patch.read_text().splitlines()
                            if line.startswith('+') and not line.startswith('+++'))
    return source.replace(original, replacement, 1)

if __name__ == "__main__":
    Path(sys.argv[2]).write_text(transform(Path(sys.argv[1]).read_text()))
