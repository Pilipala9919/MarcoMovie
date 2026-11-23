import 'package:flutter/cupertino.dart';
import '../core/app_update.dart';
import 'apple_theme.dart';

/// Structured, automatically summarized & categorized view for release notes.
class ReleaseNotesSummaryView extends StatelessWidget {
  final String rawNotes;
  final double fontSize;

  const ReleaseNotesSummaryView({
    super.key,
    required this.rawNotes,
    this.fontSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    final summary = ReleaseNotesSummary.parse(rawNotes);
    if (summary.isEmpty) {
      return Text(
        rawNotes.trim(),
        style: TextStyle(
          color: ApplePalette.of(context).labelSecondary,
          fontSize: fontSize,
          height: 1.5,
        ),
      );
    }
    if (summary.totalItems == 1 && summary.overview.isEmpty) {
      return Text(
        summary.sections.first.items.first,
        style: TextStyle(
          color: ApplePalette.of(context).labelSecondary,
          fontSize: fontSize,
          height: 1.5,
        ),
      );
    }
    final showHeaders = summary.sections.length > 1 || summary.totalItems >= 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary.overview.isNotEmpty) ...[
          Text(
            summary.overview,
            style: TextStyle(
              color: ApplePalette.of(context).labelPrimary,
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              height: 1.48,
            ),
          ),
          SizedBox(height: 10),
        ] else if (summary.totalItems >= 2) ...[
          Text(
            '共整理 ${summary.totalItems} 项重点升级改进',
            style: TextStyle(
              color: ApplePalette.of(context).labelTertiary,
              fontSize: fontSize - 0.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (var sIdx = 0; sIdx < summary.sections.length; sIdx++) ...[
          if (sIdx > 0) const SizedBox(height: 10),
          if (showHeaders) ...[
            Row(
              children: [
                Container(
                  width: 3,
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  summary.sections[sIdx].title,
                  style: TextStyle(
                    color: AppleColors.systemBlue,
                    fontSize: fontSize - 0.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
          ],
          for (final item in summary.sections[sIdx].items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _buildBulletRow(context, item),
            ),
        ],
      ],
    );
  }

  Widget _buildBulletRow(BuildContext context, String item) {
    final colonIdx = item.indexOf('：');
    final hasLead = colonIdx > 0 && colonIdx <= 24;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• ',
          style: TextStyle(
            color: ApplePalette.of(context).labelTertiary,
            fontSize: fontSize,
            height: 1.48,
          ),
        ),
        Expanded(
          child: hasLead
              ? Text.rich(
                  TextSpan(
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: fontSize,
                      height: 1.48,
                    ),
                    children: [
                      TextSpan(
                        text: item.substring(0, colonIdx + 1),
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: item.substring(colonIdx + 1)),
                    ],
                  ),
                )
              : Text(
                  item,
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: fontSize,
                    height: 1.48,
                  ),
                ),
        ),
      ],
    );
  }
}
