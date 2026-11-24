#include "include/flutter_servo/flutter_servo_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "rust_bridge.h"

namespace flutter_servo {
namespace {
using Value = flutter::EncodableValue;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
constexpr UINT kWakeMessage = WM_APP + 17;
constexpr UINT_PTR kAnimationTimer = 1;

bool Integer(const Value &value, int32_t &result) {
  if (const auto *number = std::get_if<int32_t>(&value)) {
    result = *number;
    return true;
  }
  if (const auto *number = std::get_if<int64_t>(&value)) {
    if (*number < INT32_MIN || *number > INT32_MAX)
      return false;
    result = static_cast<int32_t>(*number);
    return true;
  }
  return false;
}

struct Frame {
  std::shared_ptr<RustBridge> bridge;
  void *handle = nullptr;
  const uint8_t *pixels = nullptr;
  size_t width = 0;
  size_t height = 0;
  ~Frame() {
    if (handle)
      bridge->frame_free(handle);
  }
};

struct TextureState {
  std::mutex mutex;
  std::shared_ptr<Frame> frame;

  const FlutterDesktopPixelBuffer *Acquire() {
    struct Lease {
      std::shared_ptr<Frame> frame;
      FlutterDesktopPixelBuffer buffer;
    };
    std::lock_guard<std::mutex> lock(mutex);
    if (!frame)
      return nullptr;
    auto *lease = new Lease{frame, {}};
    lease->buffer.buffer = frame->pixels;
    lease->buffer.width = frame->width;
    lease->buffer.height = frame->height;
    lease->buffer.release_callback = [](void *context) {
      delete static_cast<Lease *>(context);
    };
    lease->buffer.release_context = lease;
    return &lease->buffer;
  }
};

struct WakeTarget {
  HWND window = nullptr;
  std::atomic<bool> queued{false};
  static void Notify(void *context) {
    auto *target = static_cast<WakeTarget *>(context);
    if (!target->queued.exchange(true) &&
        !PostMessageW(target->window, kWakeMessage, 0, 0)) {
      target->queued.store(false);
    }
  }
};
} // namespace

class FlutterServoPlugin : public flutter::Plugin {
public:
  explicit FlutterServoPlugin(flutter::PluginRegistrarWindows *registrar)
      : registrar_(registrar),
        channel_(std::make_unique<flutter::MethodChannel<Value>>(
            registrar->messenger(), "flutter_servo",
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler([this](const auto &call, auto result) {
      Handle(call, std::move(result));
    });
    close_delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message == WM_DESTROY)
            Shutdown();
          return std::nullopt;
        });
  }

  ~FlutterServoPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    registrar_->UnregisterTopLevelWindowProcDelegate(close_delegate_);
    Shutdown();
    if (texture_id_ >= 0) {
      // The registrar may still be invoking the texture callback on its raster
      // thread. Keep the callback and its state until unregistration completes.
      registrar_->texture_registrar()->UnregisterTexture(
          texture_id_, [texture = texture_]() { (void)texture; });
    }
  }

private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto *self = reinterpret_cast<FlutterServoPlugin *>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<FlutterServoPlugin *>(
          reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(self));
    }
    if (self && message == kWakeMessage) {
      self->wake_.queued.store(false);
      // While animating, coalesce wakeups into the next scheduled frame.
      if (!self->animation_timer_)
        self->Pump(false);
      return 0;
    }
    if (self && message == WM_TIMER && wparam == kAnimationTimer) {
      self->Pump(false);
      return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  bool EnsureSession(std::string &error) {
    if (session_)
      return true;
    if (closing_) {
      error = "The browser is shutting down.";
      return false;
    }
    if (!bridge_->Load(error))
      return false;
    if (!wake_.window) {
      WNDCLASSW window_class{};
      window_class.lpfnWndProc = WindowProc;
      window_class.hInstance = GetModuleHandleW(nullptr);
      window_class.lpszClassName = L"FlutterServoWakeWindow";
      if (!RegisterClassW(&window_class) &&
          GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        error = "Cannot register the Servo message window.";
        return false;
      }
      wake_.window =
          CreateWindowExW(0, window_class.lpszClassName, L"", 0, 0, 0, 0, 0,
                          HWND_MESSAGE, nullptr, window_class.hInstance, this);
      if (!wake_.window) {
        error = "Cannot create the Servo message window.";
        return false;
      }
    }
    session_ =
        bridge_->session_new(http_proxy_ ? http_proxy_->c_str() : nullptr,
                             https_proxy_ ? https_proxy_->c_str() : nullptr,
                             no_proxy_ ? no_proxy_->c_str() : nullptr);
    if (!session_) {
      error = "Servo initialization failed. See the native console output.";
      return false;
    }
    bridge_->set_wake_callback(session_, WakeTarget::Notify, &wake_);
    ApplyViewportScale();
    return true;
  }

  void ApplyViewportScale() {
    if (bridge_->set_viewport_scale)
      bridge_->set_viewport_scale(session_, display_scale_, page_zoom_);
  }

  void Shutdown() {
    closing_ = true;
    if (session_)
      bridge_->set_wake_callback(session_, nullptr, nullptr);
    if (wake_.window) {
      KillTimer(wake_.window, kAnimationTimer);
      DestroyWindow(wake_.window);
      wake_.window = nullptr;
    }
    animation_timer_ = false;
    if (session_) {
      bridge_->session_free(session_);
      session_ = nullptr;
    }
  }

  void Notify(const char *method, Value value = Value()) {
    channel_->InvokeMethod(method, std::make_unique<Value>(std::move(value)));
  }

  void SetProgress(int progress) {
    if (progress != progress_) {
      progress_ = progress;
      Notify("loadStateChanged", Value(progress));
    }
  }

  void Pump(bool force) {
    if (!session_ || closing_ || texture_id_ < 0)
      return;
    const bool dirty = bridge_->poll(session_);
    if (dirty || force) {
      auto frame = std::make_shared<Frame>();
      frame->bridge = bridge_;
      frame->width = width_;
      frame->height = height_;
      size_t length = 0;
      frame->handle = bridge_->render_frame(session_, width_, height_,
                                            &frame->pixels, &length);
      if (frame->handle && frame->pixels &&
          length == static_cast<size_t>(width_) * height_ * 4) {
        {
          std::lock_guard<std::mutex> lock(state_->mutex);
          state_->frame = std::move(frame);
        }
        registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
        if (!has_frame_) {
          has_frame_ = true;
          Notify("frameAvailable");
        }
      }
    }
    SetProgress(bridge_->load_progress(session_));
    char url[16384]{};
    bool back = false, forward = false;
    if (bridge_->navigation_state(session_, url, sizeof(url), &back,
                                  &forward)) {
      List navigation{Value(url), Value(back), Value(forward)};
      if (navigation != navigation_) {
        navigation_ = navigation;
        Notify("navigationStateChanged", Value(navigation));
      }
    }
    for (int i = 0; i < 64; ++i) {
      char *event = bridge_->take_control_event(session_);
      if (!event)
        break;
      const std::string copy(event);
      bridge_->control_event_free(event);
      Notify("embedderControl", Value(copy));
      if (i == 63)
        WakeTarget::Notify(&wake_);
    }
    const bool animate = progress_ != 3 && bridge_->is_animating(session_);
    if (animate && !animation_timer_) {
      animation_timer_ =
          SetTimer(wake_.window, kAnimationTimer, 16, nullptr) != 0;
    } else if (!animate && animation_timer_) {
      KillTimer(wake_.window, kAnimationTimer);
      animation_timer_ = false;
    }
  }

  void Handle(const flutter::MethodCall<Value> &call,
              std::unique_ptr<Result> result) {
    const auto &method = call.method_name();
    const auto *args = call.arguments();
    const auto *list = args ? std::get_if<List>(args) : nullptr;
    auto invalid = [&] {
      result->Error("invalid-args", "Invalid arguments for " + method);
    };
    if (closing_) {
      result->Error("session-closed", "The browser is shutting down.");
      return;
    }

    if (method == "createTexture" || method == "resizeTexture") {
      int32_t width = 0, height = 0;
      if (!list || (list->size() != 2 && list->size() != 4) || !Integer((*list)[0], width) ||
          !Integer((*list)[1], height) || width < 1 || height < 1 ||
          width > 16384 || height > 16384 ||
          static_cast<int64_t>(width) * height > 64 * 1024 * 1024) {
        invalid();
        return;
      }
      if (method == "resizeTexture" && texture_id_ < 0) {
        result->Error("texture-missing",
                      "Create the texture before resizing it.");
        return;
      }
      if (list->size() == 4) {
        const auto *scale = std::get_if<double>(&(*list)[2]);
        const auto *zoom = std::get_if<double>(&(*list)[3]);
        if (!scale || !zoom ||
            !(*scale >= 0.5 && *scale <= 8.0 && *zoom >= 0.5 && *zoom <= 3.0)) {
          invalid();
          return;
        }
        display_scale_ = static_cast<float>(*scale);
        page_zoom_ = static_cast<float>(*zoom);
      }
      width_ = static_cast<uint32_t>(width);
      height_ = static_cast<uint32_t>(height);
      if (texture_id_ < 0) {
        texture_ = std::make_shared<flutter::TextureVariant>(
            flutter::PixelBufferTexture(
                [state = state_](size_t, size_t) { return state->Acquire(); }));
        texture_id_ =
            registrar_->texture_registrar()->RegisterTexture(texture_.get());
        if (texture_id_ < 0) {
          result->Error("texture-register-failed",
                        "Cannot register the Servo texture.");
          return;
        }
      }
      if (session_) {
        ApplyViewportScale();
        Pump(true);
      }
      if (has_frame_)
        Notify("frameAvailable");
      result->Success(Value(texture_id_));
      return;
    }
    if (method == "setProxySettings") {
      if (!list || list->size() != 3) {
        invalid();
        return;
      }
      for (const auto &item : *list) {
        if (!std::holds_alternative<std::monostate>(item) &&
            !std::get_if<std::string>(&item)) {
          invalid();
          return;
        }
      }
      if (session_) {
        result->Error("session-locked",
                      "Set proxies before loading the first page.");
        return;
      }
      auto proxy = [](const Value &value) -> std::optional<std::string> {
        if (const auto *text = std::get_if<std::string>(&value))
          return *text;
        return std::nullopt;
      };
      http_proxy_ = proxy((*list)[0]);
      https_proxy_ = proxy((*list)[1]);
      no_proxy_ = proxy((*list)[2]);
      result->Success();
      return;
    }
    if (method == "setUrl" || method == "setPolicyUrl" || method == "setHtml") {
      const auto *text = list && list->size() == 1
                             ? std::get_if<std::string>(&(*list)[0])
                             : nullptr;
      if (!text) {
        invalid();
        return;
      }
      if (texture_id_ < 0) {
        result->Error("texture-missing",
                      "Create the texture before loading content.");
        return;
      }
      std::string error;
      if (!EnsureSession(error)) {
        result->Error("session-create-failed", error);
        return;
      }
      if (method == "setPolicyUrl" && (!bridge_->control_response ||
          !bridge_->control_response(session_, R"({"type":"requireNavigationPolicy"})"))) {
        result->Error("unsupported-navigation-policy", "Native policy unavailable.");
        return;
      }
      const bool accepted = method != "setHtml"
                                ? bridge_->set_url(session_, text->c_str())
                                : bridge_->set_html(session_, text->c_str());
      if (!accepted) {
        result->Error("session-update-failed", "Servo rejected the content.");
        return;
      }
      SetProgress(0);
      Pump(true);
      result->Success();
      return;
    }
    if (method == "refreshTexture" || method == "goBack" ||
        method == "goForward" || method == "reload") {
      if (!session_) {
        result->Error("session-missing", "Load content first.");
        return;
      }
      if (method == "refreshTexture") {
        Pump(true);
        result->Success(Value(bridge_->is_animating(session_)));
        return;
      }
      bool accepted = method == "goBack"      ? bridge_->go_back(session_)
                      : method == "goForward" ? bridge_->go_forward(session_)
                                              : bridge_->reload(session_);
      if (accepted)
        SetProgress(0);
      Pump(true);
      result->Success(Value(accepted));
      return;
    }
    if (method == "respondToControl") {
      const auto *response = args ? std::get_if<std::string>(args) : nullptr;
      if (!response) {
        invalid();
        return;
      }
      bool accepted =
          session_ && bridge_->control_response(session_, response->c_str());
      if (accepted)
        WakeTarget::Notify(&wake_);
      result->Success(Value(accepted));
      return;
    }
    const bool input =
        method == "notifyMouseMove" || method == "notifyMouseButton" ||
        method == "notifyMouseLeaveViewport" || method == "notifyMouseWheel" ||
        method == "notifyKeyEvent" || method == "focusWebView" ||
        method == "blurWebView";
    if (!input) {
      result->NotImplemented();
      return;
    }
    if (!session_) {
      result->Error("session-missing", "Load content before sending input.");
      return;
    }
    bool accepted = false;
    if (method == "focusWebView")
      accepted = bridge_->focus(session_);
    else if (method == "blurWebView")
      accepted = bridge_->blur(session_);
    else if (method == "notifyMouseLeaveViewport")
      accepted = bridge_->mouse_leave(session_);
    else if (method == "notifyKeyEvent") {
      if (!list || list->size() != 3) {
        invalid();
        return;
      }
      const auto *label = std::get_if<std::string>(&(*list)[0]);
      const auto *character = std::get_if<std::string>(&(*list)[1]);
      const auto *down = std::get_if<bool>(&(*list)[2]);
      if (!label || !character || !down) {
        invalid();
        return;
      }
      accepted = bridge_->key_event(session_, label->c_str(),
                                    character->c_str(), *down);
    } else {
      int32_t x = 0, y = 0, a = 0, b = 0;
      const size_t count = method == "notifyMouseMove" ? 2 : 4;
      if (!list || list->size() != count || !Integer((*list)[0], x) ||
          !Integer((*list)[1], y)) {
        invalid();
        return;
      }
      if (method == "notifyMouseMove")
        accepted = bridge_->mouse_move(session_, x, y);
      else if (method == "notifyMouseWheel") {
        if (!Integer((*list)[2], a) || !Integer((*list)[3], b)) {
          invalid();
          return;
        }
        accepted = bridge_->mouse_wheel(session_, x, y, a, b);
      } else {
        const auto *down = std::get_if<bool>(&(*list)[3]);
        if (!Integer((*list)[2], a) || a < 0 || a > 4 || !down) {
          invalid();
          return;
        }
        accepted = bridge_->mouse_button(session_, x, y,
                                         static_cast<uint8_t>(a), *down);
      }
    }
    if (!accepted) {
      result->Error("input-failed", "Servo rejected the input event.");
      return;
    }
    WakeTarget::Notify(&wake_);
    result->Success();
  }

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::shared_ptr<RustBridge> bridge_ = std::make_shared<RustBridge>();
  std::shared_ptr<TextureState> state_ = std::make_shared<TextureState>();
  std::shared_ptr<flutter::TextureVariant> texture_;
  void *session_ = nullptr;
  WakeTarget wake_;
  int64_t texture_id_ = -1;
  uint32_t width_ = 1, height_ = 1;
  float display_scale_ = 1.0f, page_zoom_ = 1.0f;
  int progress_ = -1;
  int close_delegate_ = 0;
  bool has_frame_ = false, closing_ = false, animation_timer_ = false;
  List navigation_;
  std::optional<std::string> http_proxy_, https_proxy_, no_proxy_;
};
} // namespace flutter_servo

void FlutterServoPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto *windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<flutter_servo::FlutterServoPlugin>(windows_registrar));
}
