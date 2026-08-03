import 'package:flutter/material.dart';
import 'package:flutter_servo/flutter_servo.dart';

enum _ViewportMode { desktop, mobile }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterServo.init();
  runApp(const ServoBrowserApp());
}

class ServoBrowserApp extends StatelessWidget {
  const ServoBrowserApp({super.key});

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
      home: const BrowserPage(),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final TextEditingController _addressController = TextEditingController(
    text: FlutterServo.mvpInitialUrl(),
  );
  final FocusNode _addressFocusNode = FocusNode();

  String _content = FlutterServo.mvpInitialUrl();
  FlutterServoContentType _contentType = FlutterServoContentType.url;
  int _reloadRevision = 0;
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  _ViewportMode _viewportMode = _ViewportMode.desktop;

  @override
  void dispose() {
    _addressController.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  bool get _isHtmlInput {
    final input = _addressController.text.trimLeft().toLowerCase();
    return input.startsWith('<') || input.contains('<html');
  }

  void _navigate() {
    final rawInput = _addressController.text.trim();
    if (rawInput.isEmpty) {
      return;
    }

    final contentType = _isHtmlInput
        ? FlutterServoContentType.html
        : FlutterServoContentType.url;
    final target = contentType == FlutterServoContentType.html
        ? rawInput
        : _resolveAddress(rawInput);
    _addressFocusNode.unfocus();
    setState(() {
      _content = target;
      _contentType = contentType;
      _isLoading = true;
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

  Future<void> _goBack() async {
    if (!await FlutterServo.goBack()) {
      return;
    }
    if (mounted) {
      setState(() => _isLoading = true);
    }
  }

  Future<void> _goForward() async {
    if (!await FlutterServo.goForward()) {
      return;
    }
    if (mounted) {
      setState(() => _isLoading = true);
    }
  }

  Future<void> _reload() async {
    if (!await FlutterServo.reload()) {
      return;
    }
    if (mounted) {
      setState(() => _isLoading = true);
    }
  }

  void _loadQuickSite(String url) {
    _addressController.text = url;
    _navigate();
  }

  void _setViewportMode(_ViewportMode mode) {
    if (_viewportMode == mode) {
      return;
    }
    setState(() {
      _viewportMode = mode;
      _isLoading = true;
      _reloadRevision++;
    });
  }

  void _handleNavigationState(FlutterServoNavigationState state) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (state.url.isNotEmpty && !_addressFocusNode.hasFocus) {
        _addressController.text = state.url;
      }
      _canGoBack = state.canGoBack;
      _canGoForward = state.canGoForward;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              viewportMode: _viewportMode,
              onBack: _goBack,
              onForward: _goForward,
              onReload: _reload,
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
                  isLoading: _isLoading,
                  viewportMode: _viewportMode,
                  onLoadStateChanged: (isLoading) {
                    if (mounted && _isLoading != isLoading) {
                      setState(() => _isLoading = isLoading);
                    }
                  },
                  onNavigationStateChanged: _handleNavigationState,
                  onQuickSite: _loadQuickSite,
                ),
              ),
            ),
            _BrowserStatus(
              isLoading: _isLoading,
              viewportMode: _viewportMode,
              currentAddress: _addressController.text,
            ),
          ],
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
      child: Row(
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
          const Text(
            'SERVO',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.8),
          ),
          const SizedBox(width: 10),
          const Text('Browser MVP', style: TextStyle(color: Color(0xFF9BA8B5))),
          const Spacer(),
          _StatePill(label: isLoading ? 'LOADING' : 'READY', active: isLoading),
        ],
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
    required this.viewportMode,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onSubmit,
    required this.onViewportModeChanged,
  });

  final TextEditingController addressController;
  final FocusNode addressFocusNode;
  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final _ViewportMode viewportMode;
  final Future<void> Function() onBack;
  final Future<void> Function() onForward;
  final Future<void> Function() onReload;
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

          if (compact) {
            return Column(
              children: [
                Row(children: [navigation, const SizedBox(width: 8), mode]),
                const SizedBox(height: 8),
                address,
              ],
            );
          }
          return Row(
            children: [
              navigation,
              const SizedBox(width: 8),
              Expanded(child: address),
              const SizedBox(width: 10),
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
    required this.isLoading,
    required this.viewportMode,
    required this.onLoadStateChanged,
    required this.onNavigationStateChanged,
    required this.onQuickSite,
  });

  final String content;
  final FlutterServoContentType contentType;
  final int reloadRevision;
  final bool isLoading;
  final _ViewportMode viewportMode;
  final ValueChanged<bool> onLoadStateChanged;
  final ValueChanged<FlutterServoNavigationState> onNavigationStateChanged;
  final ValueChanged<String> onQuickSite;

  @override
  Widget build(BuildContext context) {
    final fallback = _StartSurface(onQuickSite: onQuickSite);
    final surface = contentType == FlutterServoContentType.html
        ? FlutterServoSurface.html(
            content: content,
            fallback: fallback,
            reloadRevision: reloadRevision,
            onLoadStateChanged: onLoadStateChanged,
            onNavigationStateChanged: onNavigationStateChanged,
          )
        : FlutterServoSurface.url(
            content: content,
            fallback: fallback,
            reloadRevision: reloadRevision,
            onLoadStateChanged: onLoadStateChanged,
            onNavigationStateChanged: onNavigationStateChanged,
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
          if (isLoading)
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

class _StartSurface extends StatelessWidget {
  const _StartSurface({required this.onQuickSite});

  final ValueChanged<String> onQuickSite;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.7, -0.8),
          radius: 1.3,
          colors: [Color(0xFF263744), Color(0xFF10171E)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StatePill(label: 'SERVO 0.4', active: true),
            const Spacer(),
            Text(
              'A browser shell\nfor an embeddable engine.',
              style: textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                height: 0.98,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Use the address bar for URLs, search terms, data URLs, or raw HTML. The buttons below load real Servo pages.',
              style: TextStyle(color: Color(0xFFC3CED7), height: 1.45),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _QuickSiteButton(
                  label: 'RichYoung.ca',
                  icon: Icons.public,
                  onPressed: () => onQuickSite('https://richyoung.ca'),
                ),
                _QuickSiteButton(
                  label: 'Servo',
                  icon: Icons.rocket_launch_outlined,
                  onPressed: () => onQuickSite('https://servo.org'),
                ),
                _QuickSiteButton(
                  label: 'Search',
                  icon: Icons.search,
                  onPressed: () => onQuickSite('servo browser embedding'),
                ),
              ],
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class _QuickSiteButton extends StatelessWidget {
  const _QuickSiteButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFF3F6F8),
        side: const BorderSide(color: Color(0xFF536673)),
      ),
    );
  }
}

class _BrowserStatus extends StatelessWidget {
  const _BrowserStatus({
    required this.isLoading,
    required this.viewportMode,
    required this.currentAddress,
  });

  final bool isLoading;
  final _ViewportMode viewportMode;
  final String currentAddress;

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
            isLoading ? Icons.sync : Icons.lock_outline,
            size: 14,
            color: isLoading
                ? const Color(0xFFE9B44C)
                : const Color(0xFF77C6A2),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              isLoading
                  ? 'Servo is painting a new frame'
                  : (host?.isNotEmpty ?? false)
                  ? host!
                  : 'Local document',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9BA8B5)),
            ),
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
