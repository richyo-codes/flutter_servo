import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_servo/flutter_servo.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demos.dart';

enum _ViewportMode { desktop, mobile }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterServo.init();
  final uri = Uri.tryParse(
    Platform.environment['FLUTTER_SERVO_START_URL'] ?? '',
  );
  final initialUrl =
      uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty
      ? uri.toString()
      : null;
  runApp(ServoBrowserApp(initialUrl: initialUrl));
}

class ServoBrowserApp extends StatelessWidget {
  const ServoBrowserApp({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  Widget build(BuildContext context) {
    const chrome = Color(0xFF11161C);
    return MaterialApp(
      title: 'Servo Browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE57345),
          brightness: Brightness.dark,
          surface: chrome,
        ),
        scaffoldBackgroundColor: chrome,
        useMaterial3: true,
      ),
      home: BrowserPage(initialUrl: initialUrl),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  static const _bookmarksKey = 'browser.bookmarks';

  late final TextEditingController _addressController = TextEditingController(
    text: _content,
  );
  final FocusNode _addressFocusNode = FocusNode();
  final FocusNode _browserFocusNode = FocusNode();
  final Set<PhysicalKeyboardKey> _handledShortcutKeys = {};

  late String _content = widget.initialUrl ?? FlutterServo.mvpInitialUrl();
  FlutterServoContentType _contentType = FlutterServoContentType.url;
  int _reloadRevision = 0;
  int _zoomPercent = 100;
  bool _isLoading = false;
  PlatformException? _surfaceError;
  FlutterServoLoadProgress _loadProgress = FlutterServoLoadProgress.complete;
  bool _canGoBack = false;
  bool _canGoForward = false;
  _ViewportMode _viewportMode = _ViewportMode.desktop;
  List<String> _bookmarks = const [];
  late final Future<void> _bookmarksReady;
  bool _bookmarkUpdateInFlight = false;
  int _demoLoadGeneration = 0;
  final Map<String, BrowserDemo> _demoDocuments = {};

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleBrowserKeyEvent);
    _bookmarksReady = _loadBookmarks();
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleBrowserKeyEvent);
    _browserFocusNode.dispose();
    _addressController.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  bool get _isHtmlInput {
    final input = _addressController.text.trimLeft().toLowerCase();
    return input.startsWith('<') || input.contains('<html');
  }

  String? get _bookmarkableAddress {
    final uri = Uri.tryParse(_addressController.text.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.toString();
  }

  Future<void> _loadBookmarks() async {
    final preferences = await SharedPreferences.getInstance();
    final bookmarks = preferences.getStringList(_bookmarksKey) ?? const [];
    if (mounted) {
      setState(() => _bookmarks = bookmarks);
    }
  }

  Future<void> _toggleBookmark() async {
    final address = _bookmarkableAddress;
    if (address == null || _bookmarkUpdateInFlight) {
      return;
    }
    setState(() => _bookmarkUpdateInFlight = true);
    try {
      await _bookmarksReady;
      final bookmarks = [..._bookmarks];
      if (!bookmarks.remove(address)) {
        bookmarks.add(address);
        bookmarks.sort();
      }
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setStringList(_bookmarksKey, bookmarks);
      if (saved && mounted) {
        setState(() => _bookmarks = bookmarks);
      }
    } finally {
      if (mounted) {
        setState(() => _bookmarkUpdateInFlight = false);
      }
    }
  }

  void _focusAddressBar() {
    _addressFocusNode.requestFocus();
    _addressController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _addressController.text.length,
    );
  }

  bool get _supportsZoom =>
      resolveFlutterServoBackend(FlutterServoBackend.auto) ==
      FlutterServoBackend.servo;

  void _setZoom(int percent) {
    setState(() => _zoomPercent = percent.clamp(50, 300));
  }

  Map<ShortcutActivator, VoidCallback> get _browserShortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyL, control: true):
        _focusAddressBar,
    const SingleActivator(LogicalKeyboardKey.keyK, control: true):
        _focusAddressBar,
    const SingleActivator(LogicalKeyboardKey.keyD, alt: true): _focusAddressBar,
    const SingleActivator(LogicalKeyboardKey.f6): _focusAddressBar,
    if (_supportsZoom) ...{
      const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
          _setZoom(_zoomPercent + 10),
      const SingleActivator(
        LogicalKeyboardKey.equal,
        control: true,
        shift: true,
      ): () =>
          _setZoom(_zoomPercent + 10),
      const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): () =>
          _setZoom(_zoomPercent + 10),
      const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
          _setZoom(_zoomPercent - 10),
      const SingleActivator(
        LogicalKeyboardKey.numpadSubtract,
        control: true,
      ): () =>
          _setZoom(_zoomPercent - 10),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
          _setZoom(100),
    },
    const SingleActivator(
      LogicalKeyboardKey.keyR,
      control: true,
      includeRepeats: false,
    ): () {
      _reload();
    },
    const SingleActivator(LogicalKeyboardKey.f5, includeRepeats: false): () {
      _reload();
    },
    const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      alt: true,
      includeRepeats: false,
    ): () {
      _goBack();
    },
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      alt: true,
      includeRepeats: false,
    ): () {
      _goForward();
    },
    const SingleActivator(
      LogicalKeyboardKey.keyD,
      control: true,
      includeRepeats: false,
    ): () {
      _toggleBookmark();
    },
  };

  KeyEventResult _handleBrowserKeyEvent(KeyEvent event) {
    if (!mounted || !_browserFocusNode.hasFocus) return KeyEventResult.ignored;
    if (event is KeyUpEvent && _handledShortcutKeys.remove(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        _handledShortcutKeys.contains(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    // Browser commands take precedence over the focused webpage's input handler.
    for (final shortcut in _browserShortcuts.entries) {
      if (shortcut.key.accepts(event, HardwareKeyboard.instance)) {
        _handledShortcutKeys.add(event.physicalKey);
        shortcut.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _navigate() {
    final rawInput = _addressController.text.trim();
    if (rawInput.isEmpty) {
      return;
    }
    for (final demo in BrowserDemo.values) {
      if (rawInput == 'demo:${demo.id}') {
        _openDemo(demo);
        return;
      }
    }
    if (Uri.tryParse(rawInput)?.scheme == 'demo') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unknown demo. Choose one from Embedding demos.'),
        ),
      );
      return;
    }
    _demoLoadGeneration++;

    final contentType = _isHtmlInput
        ? FlutterServoContentType.html
        : FlutterServoContentType.url;
    final target = contentType == FlutterServoContentType.html
        ? rawInput
        : _resolveAddress(rawInput);
    _addressFocusNode.unfocus();
    setState(() {
      _content = target;
      _surfaceError = null;
      _contentType = contentType;
      _isLoading = true;
      _loadProgress = FlutterServoLoadProgress.started;
      _reloadRevision++;
    });
  }

  String _resolveAddress(String input) {
    final uri = Uri.tryParse(input);
    if (uri != null && uri.hasScheme) {
      return input;
    }
    if (input.contains(RegExp(r'\s'))) {
      return 'https://duckduckgo.com/html/?q=${Uri.encodeQueryComponent(input)}';
    }
    return 'https://$input';
  }

  void _beginLoading() {
    setState(() {
      _surfaceError = null;
      _isLoading = true;
      _loadProgress = FlutterServoLoadProgress.started;
    });
  }

  Future<void> _goBack() async {
    if (!await FlutterServo.goBack()) {
      return;
    }
    if (mounted) {
      _beginLoading();
    }
  }

  Future<void> _goForward() async {
    if (!await FlutterServo.goForward()) {
      return;
    }
    if (mounted) {
      _beginLoading();
    }
  }

  Future<void> _reload() async {
    if (_surfaceError != null) {
      setState(() {
        _surfaceError = null;
        _reloadRevision++;
        _isLoading = true;
        _loadProgress = FlutterServoLoadProgress.started;
      });
      return;
    }
    if (!await FlutterServo.reload()) {
      return;
    }
    if (mounted) {
      _beginLoading();
    }
  }

  void _loadQuickSite(String url) {
    _addressController.text = url;
    _navigate();
  }

  Future<void> _openDemo(BrowserDemo demo) async {
    final generation = ++_demoLoadGeneration;
    try {
      final html = await rootBundle.loadString(demo.asset);
      if (!mounted || generation != _demoLoadGeneration) return;
      _addressFocusNode.unfocus();
      setState(() {
        // FlutterServoSurface trims content before sending it to the renderer.
        _demoDocuments[html.trim()] = demo;
        _content = html;
        _contentType = FlutterServoContentType.html;
        _addressController.text = 'demo:${demo.id}';
        _reloadRevision++;
        _surfaceError = null;
        _isLoading = true;
        _loadProgress = FlutterServoLoadProgress.started;
        _canGoBack = false;
        _canGoForward = false;
      });
    } catch (error) {
      if (!mounted || generation != _demoLoadGeneration) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open demo: $error')));
    }
  }

  void _setViewportMode(_ViewportMode mode) {
    if (_viewportMode == mode) {
      return;
    }
    setState(() {
      _viewportMode = mode;
      _isLoading = true;
      _loadProgress = FlutterServoLoadProgress.started;
      _reloadRevision++;
    });
  }

  void _handleNavigationState(FlutterServoNavigationState state) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (state.url.isNotEmpty && !_addressFocusNode.hasFocus) {
        _addressController.text = _displayAddress(state.url);
      }
      _canGoBack = state.canGoBack;
      _canGoForward = state.canGoForward;
    });
  }

  String _displayAddress(String url) {
    if (url.startsWith('data:')) {
      try {
        // Match document content, not merely the scheme: unrelated data URLs
        // must not acquire a trusted demo label, including during history moves.
        // UriData treats a literal '#' as payload; Servo uses it as a fragment.
        // Encoded %23 characters inside the document must remain untouched.
        final uri = Uri.parse(url.split('#').first);
        final demo = _demoDocuments[uri.data?.contentAsString()];
        if (demo != null) return 'demo:${demo.id}';
      } on FormatException {
        // Preserve malformed or non-text URLs as supplied by the renderer.
      }
    }
    return url;
  }

  void _handleLoadProgress(FlutterServoLoadProgress progress) {
    if (!mounted) {
      return;
    }
    setState(() {
      _loadProgress = progress;
      _isLoading =
          progress == FlutterServoLoadProgress.started ||
          progress == FlutterServoLoadProgress.firstFrame;
    });
  }

  void _handleSurfaceError(PlatformException error) {
    if (!mounted) return;
    setState(() {
      _surfaceError = error;
      _isLoading = false;
      _loadProgress = FlutterServoLoadProgress.failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _browserShortcuts,
      child: Focus(
        focusNode: _browserFocusNode,
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _BrowserIdentity(isLoading: _isLoading),
                _BrowserToolbar(
                  addressController: _addressController,
                  addressFocusNode: _addressFocusNode,
                  canGoBack: _canGoBack,
                  canGoForward: _canGoForward,
                  isLoading: _isLoading,
                  bookmarks: _bookmarks,
                  currentBookmark: _bookmarkableAddress,
                  bookmarkUpdateInFlight: _bookmarkUpdateInFlight,
                  viewportMode: _viewportMode,
                  onBack: _goBack,
                  onForward: _goForward,
                  onReload: _reload,
                  onToggleBookmark: _toggleBookmark,
                  onOpenBookmark: _loadQuickSite,
                  onOpenDemo: _openDemo,
                  onSubmit: _navigate,
                  onViewportModeChanged: _setViewportMode,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: _BrowserViewport(
                      content: _content,
                      contentType: _contentType,
                      reloadRevision: _reloadRevision,
                      pageZoom: _zoomPercent / 100,
                      onWheelZoom: _supportsZoom
                          ? (steps) => _setZoom(_zoomPercent + 10 * steps)
                          : null,
                      loadProgress: _loadProgress,
                      viewportMode: _viewportMode,
                      onLoadProgressChanged: _handleLoadProgress,
                      onNavigationStateChanged: _handleNavigationState,
                      onQuickSite: _loadQuickSite,
                      error: _surfaceError,
                      onError: _handleSurfaceError,
                      onRetry: _reload,
                    ),
                  ),
                ),
                _BrowserStatus(
                  isLoading: _isLoading,
                  viewportMode: _viewportMode,
                  currentAddress: _addressController.text,
                  zoomPercent: _zoomPercent,
                  onResetZoom: _supportsZoom ? () => _setZoom(100) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserIdentity extends StatelessWidget {
  const _BrowserIdentity({required this.isLoading});

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF29313A))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Color(0xFFE57345),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              resolveFlutterServoBackend(FlutterServoBackend.auto) ==
                      FlutterServoBackend.webview
                  ? 'WEBVIEW'
                  : 'SERVO',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
              ),
            ),
            if (constraints.maxWidth >= 350) ...[
              const SizedBox(width: 10),
              const Text(
                'Browser MVP',
                style: TextStyle(color: Color(0xFF9BA8B5)),
              ),
            ],
            const Spacer(),
            _StatePill(
              label: isLoading ? 'LOADING' : 'READY',
              active: isLoading,
            ),
          ],
        ),
      ),
    );
  }
}

class _BrowserToolbar extends StatelessWidget {
  const _BrowserToolbar({
    required this.addressController,
    required this.addressFocusNode,
    required this.canGoBack,
    required this.canGoForward,
    required this.isLoading,
    required this.bookmarks,
    required this.currentBookmark,
    required this.bookmarkUpdateInFlight,
    required this.viewportMode,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onToggleBookmark,
    required this.onOpenBookmark,
    required this.onOpenDemo,
    required this.onSubmit,
    required this.onViewportModeChanged,
  });

  final TextEditingController addressController;
  final FocusNode addressFocusNode;
  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final List<String> bookmarks;
  final String? currentBookmark;
  final bool bookmarkUpdateInFlight;
  final _ViewportMode viewportMode;
  final Future<void> Function() onBack;
  final Future<void> Function() onForward;
  final Future<void> Function() onReload;
  final Future<void> Function() onToggleBookmark;
  final ValueChanged<String> onOpenBookmark;
  final ValueChanged<BrowserDemo> onOpenDemo;
  final VoidCallback onSubmit;
  final ValueChanged<_ViewportMode> onViewportModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF171D24),
        border: Border(bottom: BorderSide(color: Color(0xFF29313A))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final navigation = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: canGoBack && !isLoading ? () => onBack() : null,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              IconButton(
                tooltip: 'Forward',
                onPressed: canGoForward && !isLoading
                    ? () => onForward()
                    : null,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
              IconButton(
                tooltip: 'Reload',
                onPressed: isLoading ? null : () => onReload(),
                icon: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          );
          final address = TextField(
            controller: addressController,
            focusNode: addressFocusNode,
            onSubmitted: (_) => onSubmit(),
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.travel_explore_outlined, size: 19),
              suffixIcon: IconButton(
                tooltip: 'Open address',
                onPressed: onSubmit,
                icon: const Icon(Icons.arrow_upward_rounded, size: 19),
              ),
              hintText: 'Search or enter an address',
              filled: true,
              fillColor: const Color(0xFF0E1319),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF34404C)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF34404C)),
              ),
            ),
            style: theme.textTheme.bodyMedium,
          );
          final mode = SegmentedButton<_ViewportMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _ViewportMode.desktop,
                icon: Icon(Icons.desktop_windows_outlined, size: 17),
                tooltip: 'Desktop viewport',
              ),
              ButtonSegment(
                value: _ViewportMode.mobile,
                icon: Icon(Icons.phone_android_outlined, size: 17),
                tooltip: 'Mobile viewport',
              ),
            ],
            selected: {viewportMode},
            onSelectionChanged: (selection) =>
                onViewportModeChanged(selection.single),
          );
          final bookmarkControls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<BrowserDemo>(
                key: const ValueKey('demos-menu'),
                tooltip: 'Embedding demos',
                onSelected: onOpenDemo,
                itemBuilder: (context) => [
                  for (final demo in BrowserDemo.values)
                    PopupMenuItem(value: demo, child: Text(demo.label)),
                ],
                icon: const Icon(Icons.science_outlined),
              ),
              IconButton(
                key: const ValueKey('bookmark-toggle'),
                tooltip:
                    currentBookmark != null &&
                        bookmarks.contains(currentBookmark)
                    ? 'Remove bookmark'
                    : 'Bookmark page',
                onPressed: currentBookmark == null || bookmarkUpdateInFlight
                    ? null
                    : () => onToggleBookmark(),
                icon: Icon(
                  currentBookmark != null && bookmarks.contains(currentBookmark)
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('bookmarks-menu'),
                tooltip: 'Bookmarks',
                enabled: bookmarks.isNotEmpty,
                onSelected: onOpenBookmark,
                itemBuilder: (context) => [
                  for (final bookmark in bookmarks)
                    PopupMenuItem(value: bookmark, child: Text(bookmark)),
                ],
                icon: const Icon(Icons.bookmarks_outlined),
              ),
            ],
          );

          if (compact) {
            return Column(
              children: [
                Row(children: [navigation, const Spacer(), bookmarkControls]),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: address),
                    const SizedBox(width: 8),
                    mode,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              navigation,
              const SizedBox(width: 8),
              Expanded(child: address),
              const SizedBox(width: 10),
              bookmarkControls,
              const SizedBox(width: 6),
              mode,
            ],
          );
        },
      ),
    );
  }
}

class _BrowserViewport extends StatelessWidget {
  const _BrowserViewport({
    required this.content,
    required this.contentType,
    required this.reloadRevision,
    required this.pageZoom,
    required this.onWheelZoom,
    required this.loadProgress,
    required this.viewportMode,
    required this.onLoadProgressChanged,
    required this.onNavigationStateChanged,
    required this.onQuickSite,
    required this.error,
    required this.onError,
    required this.onRetry,
  });

  final String content;
  final FlutterServoContentType contentType;
  final int reloadRevision;
  final double pageZoom;
  final ValueChanged<int>? onWheelZoom;
  final FlutterServoLoadProgress loadProgress;
  final _ViewportMode viewportMode;
  final ValueChanged<FlutterServoLoadProgress> onLoadProgressChanged;
  final ValueChanged<FlutterServoNavigationState> onNavigationStateChanged;
  final ValueChanged<String> onQuickSite;
  final PlatformException? error;
  final ValueChanged<PlatformException> onError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final fallback = _PageLoadingSurface(content: content);
    final surface = contentType == FlutterServoContentType.html
        ? FlutterServoSurface.html(
            content: content,
            fallback: fallback,
            reloadRevision: reloadRevision,
            pageZoom: pageZoom,
            onWheelZoom: onWheelZoom,
            onLoadProgressChanged: onLoadProgressChanged,
            onNavigationStateChanged: onNavigationStateChanged,
            onError: onError,
            enableContextMenu: true,
          )
        : FlutterServoSurface.url(
            content: content,
            fallback: fallback,
            reloadRevision: reloadRevision,
            pageZoom: pageZoom,
            onWheelZoom: onWheelZoom,
            onLoadProgressChanged: onLoadProgressChanged,
            onNavigationStateChanged: onNavigationStateChanged,
            onError: onError,
            enableContextMenu: true,
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0C1117),
        border: Border.all(color: const Color(0xFF29313A)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = viewportMode == _ViewportMode.mobile
                    ? constraints.maxWidth.clamp(1.0, 390.0)
                    : constraints.maxWidth;
                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: width,
                    height: constraints.maxHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: surface,
                    ),
                  ),
                );
              },
            ),
          ),
          if (error != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xFF10171E),
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Page could not be rendered',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          error!.message ??
                              'The native renderer reported an error.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try Again'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (error == null && loadProgress == FlutterServoLoadProgress.started)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

class _PageLoadingSurface extends StatelessWidget {
  const _PageLoadingSurface({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(content)?.host ?? '';
    return ColoredBox(
      color: const Color(0xFF10171E),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language, size: 28, color: Color(0xFF93A1AD)),
              const SizedBox(height: 18),
              Text(
                host.isEmpty ? 'Opening page' : 'Opening $host',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowserStatus extends StatelessWidget {
  const _BrowserStatus({
    required this.isLoading,
    required this.viewportMode,
    required this.currentAddress,
    required this.zoomPercent,
    required this.onResetZoom,
  });

  final bool isLoading;
  final _ViewportMode viewportMode;
  final String currentAddress;
  final int zoomPercent;
  final VoidCallback? onResetZoom;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(currentAddress)?.host;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF171D24),
        border: Border(top: BorderSide(color: Color(0xFF29313A))),
      ),
      child: Row(
        children: [
          Icon(
            isLoading ? Icons.sync : Icons.language,
            size: 14,
            color: isLoading
                ? const Color(0xFFE9B44C)
                : const Color(0xFF77C6A2),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              isLoading
                  ? 'Loading page'
                  : (host?.isNotEmpty ?? false)
                  ? host!
                  : 'Local document',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9BA8B5)),
            ),
          ),
          if (onResetZoom != null)
            TextButton(
              onPressed: onResetZoom,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('$zoomPercent%', semanticsLabel: 'Reset page zoom'),
            ),
          Text(
            viewportMode == _ViewportMode.mobile ? '390px MOBILE' : 'DESKTOP',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Color(0xFF9BA8B5),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? const Color(0xFF473A28) : const Color(0xFF202A33),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: active ? const Color(0xFFEFD094) : const Color(0xFFB5C1CB),
          ),
        ),
      ),
    );
  }
}
