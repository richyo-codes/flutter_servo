import 'package:flutter/material.dart';
import 'package:flutter_servo/flutter_servo.dart';

Future<void> main() async {
  debugPrint('flutter_servo: Dart main start');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('flutter_servo: WidgetsFlutterBinding initialized');
  await FlutterServo.init();
  debugPrint('flutter_servo: FlutterServo.init complete');
  runApp(const ServoExampleApp());
  debugPrint('flutter_servo: runApp called');
}

class ServoExampleApp extends StatelessWidget {
  const ServoExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('flutter_servo: ServoExampleApp build');
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0F766E),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF4F1EA),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'Flutter Servo Example',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const BootstrapHomePage(),
    );
  }
}

class BootstrapHomePage extends StatefulWidget {
  const BootstrapHomePage({super.key});

  @override
  State<BootstrapHomePage> createState() => _BootstrapHomePageState();
}

class _BootstrapHomePageState extends State<BootstrapHomePage> {
  late final Future<BootstrapData> _bootstrapFuture = _loadBootstrapData();
  final TextEditingController _urlController = TextEditingController();
  String _activeContent = '';
  FlutterServoContentType _activeContentType = FlutterServoContentType.url;
  bool _nativeInputEnabled = true;
  bool _nativeLoadInProgress = false;
  static const String _richYoungUrl = 'https://richyoung.ca';
  static const String _autostartMode = String.fromEnvironment(
    'FLUTTER_SERVO_AUTOSTART',
    defaultValue: '',
  );

  bool get _isHtmlInput {
    final trimmed = _urlController.text.trimLeft();
    return trimmed.startsWith('<') || trimmed.toLowerCase().contains('<html');
  }

  Future<BootstrapData> _loadBootstrapData() async {
    debugPrint('flutter_servo: Bootstrap load start');
    final data = BootstrapData(
      greeting: FlutterServo.greet(name: 'Servo'),
      initialUrl: FlutterServo.mvpInitialUrl(),
      initialHtml: FlutterServo.mvpInitialHtml(),
    );
    _urlController.text = data.initialUrl;
    _scheduleAutostart(data);
    debugPrint('flutter_servo: Bootstrap load complete');
    return data;
  }

  void _scheduleAutostart(BootstrapData data) {
    final mode = _autostartMode.trim().toLowerCase();
    if (mode.isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeContent.isNotEmpty) {
        return;
      }

      debugPrint('flutter_servo: autostart mode=$mode');
      setState(() {
        switch (mode) {
          case 'html':
            _activeContent = data.initialHtml;
            _activeContentType = FlutterServoContentType.html;
            break;
          case 'url':
          default:
            _activeContent = data.initialUrl;
            _activeContentType = FlutterServoContentType.url;
            break;
        }
        _nativeLoadInProgress = true;
      });
    });
  }

  void _loadRichYoung() {
    setState(() {
      _urlController.text = _richYoungUrl;
      _activeContent = _richYoungUrl;
      _activeContentType = FlutterServoContentType.url;
      _nativeLoadInProgress = true;
    });
  }

  void _setNativeInputEnabled(bool value) {
    setState(() {
      _nativeInputEnabled = value;
    });
  }

  void _setNativeLoadInProgress(bool value) {
    if (_nativeLoadInProgress == value) {
      return;
    }

    setState(() {
      _nativeLoadInProgress = value;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<BootstrapData>(
          future: _bootstrapFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Rust bridge init failed: ${snapshot.error}'),
                ),
              );
            }

            final data = snapshot.requireData;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Flutter Servo Browser',
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${data.greeting} Package-first Linux MVP shell.',
                    style: textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFD6D0C4)),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 24,
                          color: Color(0x14000000),
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) {
                          debugPrint('flutter_servo: toolbar pointer down');
                        },
                        child: Row(
                          children: [
                            const Icon(Icons.arrow_back, size: 18),
                            const SizedBox(width: 10),
                            const Icon(Icons.arrow_forward, size: 18),
                            const SizedBox(width: 10),
                            const Icon(Icons.refresh, size: 18),
                            const SizedBox(width: 14),
                            Expanded(
                              child: TextField(
                                controller: _urlController,
                                onTap: () {
                                  debugPrint('flutter_servo: url field tapped');
                                },
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  hintText:
                                      'https://example.com, data:text/html,..., or raw <html>...',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton(
                              onPressed: () {
                                debugPrint(
                                  'flutter_servo: load button pressed',
                                );
                                setState(() {
                                  _activeContent = _urlController.text;
                                  _activeContentType = _isHtmlInput
                                      ? FlutterServoContentType.html
                                      : FlutterServoContentType.url;
                                  _nativeLoadInProgress = true;
                                });
                              },
                              child: const Text('Load'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFDFBF7), Color(0xFFE7F0EE)],
                        ),
                        border: Border.all(color: const Color(0xFFC9D8D2)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final isWide = constraints.maxWidth >= 960;
                            final children = [
                              Expanded(
                                child: _ServoSurfaceCard(
                                  html: data.initialHtml,
                                  content: _activeContent,
                                  useHtmlContent:
                                      _activeContentType ==
                                      FlutterServoContentType.html,
                                  enableInputPlumbing: _nativeInputEnabled,
                                  isLoading: _nativeLoadInProgress,
                                  onLoadStateChanged: _setNativeLoadInProgress,
                                ),
                              ),
                              SizedBox(
                                width: isWide ? 20 : 0,
                                height: isWide ? 0 : 20,
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    _StatusCard(
                                      currentUrl: _urlController.text,
                                      contentMode: _activeContent.isEmpty
                                          ? 'Idle'
                                          : _nativeLoadInProgress
                                          ? 'Loading'
                                          : _activeContentType ==
                                                FlutterServoContentType.html
                                          ? 'HTML'
                                          : 'URL/Data URL',
                                      isLoading: _nativeLoadInProgress,
                                    ),
                                    const SizedBox(height: 20),
                                    _InputPlumbingCard(
                                      enabled: _nativeInputEnabled,
                                      onChanged: _setNativeInputEnabled,
                                    ),
                                    const SizedBox(height: 20),
                                    _QuickLoadCard(
                                      title: 'RichYoung.ca',
                                      subtitle:
                                          'Load the public site into Servo with one tap.',
                                      url: _richYoungUrl,
                                      onTap: _loadRichYoung,
                                    ),
                                  ],
                                ),
                              ),
                            ];
                            return isWide
                                ? Row(children: children)
                                : Column(children: children);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ServoSurfaceCard extends StatelessWidget {
  const _ServoSurfaceCard({
    required this.html,
    required this.content,
    required this.useHtmlContent,
    required this.enableInputPlumbing,
    required this.isLoading,
    required this.onLoadStateChanged,
  });

  final String html;
  final String content;
  final bool useHtmlContent;
  final bool enableInputPlumbing;
  final bool isLoading;
  final ValueChanged<bool> onLoadStateChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF6EFE1), Color(0xFFE8E1D3)],
        ),
        border: Border.all(color: const Color(0xFFCFBFA5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1E2E2A),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  'FLUTTER PREVIEW',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'This is the fallback renderer.',
              style: textTheme.titleMedium?.copyWith(
                color: const Color(0xFF1E2E2A),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'It stays active until you press Load, then the native Servo surface takes over.',
              style: textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5E6B67),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F5EE),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFD8CCB8)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    html,
                    style: textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      color: const Color(0xFF243331),
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final surface = content.trim().isEmpty
        ? fallback
        : useHtmlContent
        ? FlutterServoSurface.html(
            content: content,
            fallback: fallback,
            enableInputPlumbing: enableInputPlumbing,
            onLoadStateChanged: onLoadStateChanged,
          )
        : FlutterServoSurface.url(
            content: content,
            fallback: fallback,
            enableInputPlumbing: enableInputPlumbing,
            onLoadStateChanged: onLoadStateChanged,
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF101C1A),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Servo Surface',
              style: textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This native texture is now fed by a Rust render session.',
              style: textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFD9E8E2),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              content.trim().isEmpty
                  ? 'Showing the Flutter fallback preview until you load a target.'
                  : 'Native rendering requested.',
              style: textTheme.bodySmall?.copyWith(
                color: const Color(0xFFAAC4BD),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: surface),
                  if (isLoading)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xAA101C1A),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xFFF6F1E7),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFFD8CCB8),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 14),
                                    Text(
                                      'Loading native Servo content',
                                      style: textTheme.titleMedium?.copyWith(
                                        color: const Color(0xFF1E2E2A),
                                        fontWeight: FontWeight.w700,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Waiting for the first painted frame.',
                                      style: textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF5E6B67),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputPlumbingCard extends StatelessWidget {
  const _InputPlumbingCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFD6D0C4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Native input plumbing',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Disable this to leave the Servo surface rendering only. Useful for isolating focus and event forwarding issues.',
              style: textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5F5A4F),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Forward mouse, keyboard, and focus'),
              subtitle: Text(enabled ? 'Enabled' : 'Disabled'),
              value: enabled,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.currentUrl,
    required this.contentMode,
    required this.isLoading,
  });

  final String currentUrl;
  final String contentMode;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bridge Status',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _StatusRow(label: 'Current target', value: currentUrl),
            const SizedBox(height: 12),
            _StatusRow(label: 'Content mode', value: contentMode),
            const SizedBox(height: 12),
            _StatusRow(
              label: 'Load state',
              value: isLoading ? 'Waiting for first frame' : 'Idle',
            ),
            const SizedBox(height: 12),
            const _StatusRow(label: 'Package API', value: 'Ready'),
            const SizedBox(height: 12),
            const _StatusRow(label: 'Linux plugin', value: 'Ready'),
            const SizedBox(height: 12),
            const _StatusRow(label: 'Rust session bridge', value: 'Ready'),
            const SizedBox(height: 12),
            _StatusRow(
              label: 'Servo renderer',
              value: isLoading ? 'Rendering' : 'Ready',
            ),
            const Spacer(),
            Text(
              isLoading
                  ? 'Servo is loading the target and will replace this overlay when the first frame arrives.'
                  : 'The example app now drives a stateful Rust session with URL or HTML content updates.',
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickLoadCard extends StatelessWidget {
  const _QuickLoadCard({
    required this.title,
    required this.subtitle,
    required this.url,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17312B), Color(0xFF10211D)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF28463E)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFD8E7E1),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              url,
              style: textTheme.bodySmall?.copyWith(
                color: const Color(0xFFA8C6BE),
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFF0C66E),
                  foregroundColor: const Color(0xFF13231F),
                ),
                child: const Text('Load Site'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            color: const Color(0xFF6E7D79),
          ),
        ),
        const SizedBox(height: 4),
        Text(value, style: textTheme.bodyLarge),
      ],
    );
  }
}

class BootstrapData {
  const BootstrapData({
    required this.greeting,
    required this.initialUrl,
    required this.initialHtml,
  });

  final String greeting;
  final String initialUrl;
  final String initialHtml;
}
