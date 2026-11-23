import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/cms_client.dart';
import '../core/models.dart';
import '../core/source_verification.dart';
import 'apple_theme.dart';
import 'motion/ios27_springs.dart';
import 'windows_appearance.dart';

/// Explicit user action, never an automatic modal from a background search.
class SourceVerificationButton extends StatefulWidget {
  final CmsClient client;
  final CmsSite site;
  final Future<void> Function() onVerified;
  final String label;
  const SourceVerificationButton({
    super.key,
    required this.client,
    required this.site,
    required this.onVerified,
    this.label = '完成验证',
  });

  @override
  State<SourceVerificationButton> createState() =>
      _SourceVerificationButtonState();
}

class _SourceVerificationButtonState extends State<SourceVerificationButton> {
  Completer<void>? _abort;
  void _cancel() {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  @override
  void didUpdateWidget(SourceVerificationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.site != widget.site || oldWidget.client != widget.client) {
      _cancel();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  Future<void> _open() async {
    if (_abort != null) return;
    final abort = Completer<void>();
    setState(() => _abort = abort);
    try {
      final verified = usesWindowsAppearance(context)
          ? await showGeneralDialog<bool>(
              context: context,
              barrierDismissible: true,
              barrierLabel: '关闭片源验证',
              barrierColor: const Color(0x99000000),
              transitionDuration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              pageBuilder: (_, __, ___) => SourceVerificationDialog(
                client: widget.client,
                site: widget.site,
                cancellation: abort,
              ),
            )
          : await showIos27LiquidSheet<bool>(
              context: context,
              title: '验证片源',
              maxWidth: 440,
              builder: (_) => SourceVerificationDialog(
                client: widget.client,
                site: widget.site,
                cancellation: abort,
                embeddedInSheet: true,
              ),
            );
      if (mounted && !abort.isCompleted && verified == true) {
        await widget.onVerified();
      }
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (mounted) setState(() => _abort = null);
    }
  }

  @override
  Widget build(BuildContext context) => AppleCapsuleButton(
    label: widget.label,
    icon: CupertinoIcons.shield,
    primary: true,
    compact: true,
    onPressed: _abort == null ? _open : null,
  );
}

class SourceVerificationDialog extends StatefulWidget {
  final CmsClient client;
  final CmsSite site;
  final Completer<void> cancellation;
  final bool embeddedInSheet;
  const SourceVerificationDialog({
    super.key,
    required this.client,
    required this.site,
    required this.cancellation,
    this.embeddedInSheet = false,
  });
  @override
  State<SourceVerificationDialog> createState() =>
      _SourceVerificationDialogState();
}

class _SourceVerificationDialogState extends State<SourceVerificationDialog> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  SourceImageChallenge? _challenge;
  bool _busy = true;
  bool _imageFailed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.cancellation.future.then((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      // Remove this route, never another dialog that may now be above it.
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    _refresh();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
      _challenge = null;
      _imageFailed = false;
    });
    _input.clear();
    try {
      final value = await widget.client.loadSourceChallenge(
        widget.site,
        cancellation: widget.cancellation,
      );
      if (!mounted || widget.cancellation.isCompleted) return;
      setState(() => _challenge = value);
    } catch (_) {
      if (mounted) setState(() => _error = '验证码暂时无法加载，请刷新后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final challenge = _challenge;
    if (_busy || challenge == null || _imageFailed) return;
    final code = _input.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9]{4,6}$').hasMatch(code)) {
      setState(() => _error = '请输入图片中的 4 至 6 位字符');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verified = await widget.client.submitSourceChallenge(
        widget.site,
        challenge.id,
        code,
        cancellation: widget.cancellation,
      );
      if (!mounted || widget.cancellation.isCompleted) return;
      if (verified) {
        // A successful dismissal must not cancel the parent's pending retry.
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = '验证码不正确，请重新输入或刷新图片');
        _input.clear();
        _focus.requestFocus();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '验证未完成，请刷新图片后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final innerCardRadius = Ios27ConcentricGeometry.innerRadius(
      outerRadius: Ios27ConcentricGeometry.sheetOuterRadiusPt,
      padding: 20.0,
    );
    final body = Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.embeddedInSheet) ...[
            const Text(
              '验证片源',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            widget.site.name,
            style: TextStyle(
              color: widget.embeddedInSheet
                  ? ApplePalette.of(context).labelSecondary
                  : const Color(0xFFE0E0E5),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 104,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(innerCardRadius),
            ),
            child: _challenge == null
                ? (_busy
                    ? const CupertinoActivityIndicator(
                        color: Colors.black,
                      )
                    : const Text(
                        '图片未加载',
                        style: TextStyle(color: Colors.black87),
                      ))
                : Image.memory(
                    _challenge!.bytes,
                    key: ValueKey(_challenge!.id),
                    cacheWidth: 560,
                    fit: BoxFit.contain,
                    semanticLabel: '片源验证码图片',
                    errorBuilder: (_, __, ___) {
                      if (!_imageFailed) {
                        final imageId = _challenge?.id;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _challenge?.id == imageId) {
                            setState(() => _imageFailed = true);
                          }
                        });
                      }
                      return const Text(
                        '图片无法显示，请刷新',
                        style: TextStyle(color: Colors.black87),
                      );
                    },
                  ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Ios27Pressable(
              pressedScale: Ios27Spring.pressSwellScale,
              borderRadius: 999,
              onTap: _busy ? null : _refresh,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Text(
                  '刷新图片',
                  style: TextStyle(
                    color: ApplePalette.of(context).accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          TextSelectionMouseGuard(
            child: CupertinoTextField(
              controller: _input,
              focusNode: _focus,
              enabled: !_busy && _challenge != null && !_imageFailed,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: '输入图片中的字符',
              padding: const EdgeInsets.all(14),
              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 18,
                  ),
              placeholderStyle:
                  CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                        color: ApplePalette.of(context).labelTertiary,
                      ),
              decoration: BoxDecoration(
                color: ApplePalette.isDarkOf(context)
                    ? const Color(0x33000000)
                    : Colors.white,
                borderRadius: BorderRadius.circular(innerCardRadius),
                border: Border.all(
                  color: ApplePalette.of(context).separator,
                  width: 0.7,
                ),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp('[a-zA-Z0-9]'),
                ),
                LengthLimitingTextInputFormatter(6),
              ],
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: widget.embeddedInSheet
                        ? AppleColors.systemRed
                        : const Color(0xFFFFD1CC),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: AppleCapsuleButton(
                  label: '取消',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: AppleCapsuleButton(
                  label: _busy ? '请稍候' : '验证并重试',
                  primary: true,
                  onPressed:
                      _busy || _challenge == null || _imageFailed
                          ? null
                          : _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (widget.embeddedInSheet) {
      return TextSelectionMouseGuard(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: body,
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Center(
          child: TextSelectionMouseGuard(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: LiquidGlass(
                  borderRadius: Ios27ConcentricGeometry.sheetOuterRadiusPt,
                  tint: const Color(0xC01E1E22),
                  padding: const EdgeInsets.all(24),
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
