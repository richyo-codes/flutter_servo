import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Exposes the page's semantic targets alongside the painted Flutter texture.
class ServoPageSemantics extends StatelessWidget {
  const ServoPageSemantics({
    super.key,
    required this.nodes,
    required this.displayScale,
    required this.onActivate,
  });

  final List<Object?> nodes;
  final double displayScale;
  final ValueChanged<String>? onActivate;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Web content',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (index, node) in nodes.indexed)
            if (node is Map<String, dynamic>) _buildNode(node, index),
        ],
      ),
    );
  }

  Widget _buildNode(Map<String, dynamic> node, int index) {
    final id = node['id'];
    final bounds = node['rect'];
    if (id is! String ||
        bounds is! List ||
        bounds.length != 4 ||
        !bounds.every((item) => item is num && item.isFinite)) {
      return const SizedBox.shrink();
    }
    final rect = Rect.fromLTRB(
      (bounds[0] as num) / displayScale,
      (bounds[1] as num) / displayScale,
      (bounds[2] as num) / displayScale,
      (bounds[3] as num) / displayScale,
    );
    if (rect.isEmpty) return const SizedBox.shrink();
    final role = node['role'] as String?;
    final disabled = node['disabled'] == true;
    final isText = role == 'Label' || role == 'TextRun';
    final isInput = role?.endsWith('Input') ?? false;
    return Positioned.fromRect(
      key: ValueKey(id),
      rect: rect,
      child: Semantics(
        container: true,
        sortKey: OrdinalSortKey(index.toDouble()),
        label: (node['label'] ?? (isText ? node['value'] : null)) as String?,
        value: isText ? null : node['value'] as String?,
        header: role == 'Heading',
        button: role == 'Button' || role == 'DefaultButton',
        link: role == 'Link',
        image: role == 'Image',
        textField: isInput,
        obscured: role == 'PasswordInput',
        readOnly: isInput ? node['readOnly'] == true : null,
        enabled: disabled ? false : null,
        focused: node['focused'] == true ? true : null,
        checked: switch (node['checked']) {
          'True' => true,
          'False' => false,
          _ => null,
        },
        mixed: node['checked'] == 'Mixed' ? true : null,
        onTap: !disabled && node['clickable'] == true && onActivate != null
            ? () => onActivate!(id)
            : null,
        child: const SizedBox.expand(),
      ),
    );
  }
}
