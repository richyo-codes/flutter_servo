/// Self-contained embedding fixtures. Only the video fetches remote resources.
enum BrowserDemo {
  login('Login / consent', 'login'),
  licenses('License notices', 'licenses'),
  documentation('Documentation', 'documentation'),
  video('Video playback', 'video');

  const BrowserDemo(this.label, this.id);
  final String label;
  final String id;
  String get asset => 'assets/demos/$id.html';
}
