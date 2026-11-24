package ca.richyoung.flutter_servo;

import android.webkit.WebView;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi;
import java.util.HashMap;
import java.util.Map;

public final class FlutterServoDownloads implements FlutterPlugin {
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_servo/android_downloads");
        channel.setMethodCallHandler((call, result) -> {
            if (!call.method.equals("install") || !(call.arguments instanceof Number)) {
                result.notImplemented();
                return;
            }
            long id = ((Number) call.arguments).longValue();
            WebView view = WebViewFlutterAndroidExternalApi.getWebView(binding, id);
            if (view == null) {
                result.error("missing-webview", "Cannot install download policy.", null);
                return;
            }
            MethodChannel events = new MethodChannel(binding.getBinaryMessenger(),
                    "flutter_servo/android_downloads/" + id);
            view.setDownloadListener((url, agent, disposition, mime, length) -> {
                if (channel == null) return;
                Map<String, Object> info = new HashMap<>();
                info.put("url", url);
                info.put("mimeType", mime);
                info.put("contentLength", length);
                events.invokeMethod("download", info);
            });
            result.success(null);
        });
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }
}
