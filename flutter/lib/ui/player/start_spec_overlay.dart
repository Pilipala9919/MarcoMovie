// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ohos_runtime.dart';
import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

/// Text-only media specification badge aligned with `badge-rules.json` and
/// `motion-tokens.json` (zero trademark logos).
@immutable
class PlayerSpecBadge {
  final String id;
  final String group;
  final String label;
  final int priority;
  final String style;

  const PlayerSpecBadge({
    required this.id,
    required this.group,
    required this.label,
    required this.priority,
    required this.style,
  });

  @override
  bool operator ==(Object other) =>
      other is PlayerSpecBadge &&
      other.id == id &&
      other.group == group &&
      other.label == label &&
      other.priority == priority &&
      other.style == style;

  @override
  int get hashCode => Object.hash(id, group, label, priority, style);
}

/// Optional Wave 2 hook allowing M1 `MediaBadges` to supply fused badges
/// directly when integrated.
typedef ExternalSpecFusionCallback = List<PlayerSpecBadge> Function({
  required int videoWidth,
  required int videoHeight,
  required String trackDescription,
  required String metadataDescription,
});

class _SpecRule {
  final String id;
  final String group;
  final String label;
  final RegExp regex;
  final int priority;
  final String style;

  _SpecRule({
    required this.id,
    required this.group,
    required this.label,
    required String pattern,
    required this.priority,
    required this.style,
  }) : regex = RegExp(pattern, caseSensitive: false);

  PlayerSpecBadge toBadge() => PlayerSpecBadge(
        id: id,
        group: group,
        label: label,
        priority: priority,
        style: style,
      );
}

class _ComboRule {
  final String id;
  final String group;
  final String label;
  final List<String> requires;
  final List<String> consumes;
  final int priority;
  final String style;

  const _ComboRule({
    required this.id,
    required this.group,
    required this.label,
    required this.requires,
    required this.consumes,
    required this.priority,
    required this.style,
  });

  PlayerSpecBadge toBadge() => PlayerSpecBadge(
        id: id,
        group: group,
        label: label,
        priority: priority,
        style: style,
      );
}

/// Dual-channel group-safe media spec badge extractor & fusion engine aligned
/// with `shared/ui-spec/badge-rules.json` and `player-hud-spec.md §4.1`.
class MediaSpecFusion {
  static const int maxStartSpecBadges = 5;
  static const int _maxNormCodeUnits = 1024;

  /// Optional Wave 2 injection hook for unified M1 engine delegation.
  static ExternalSpecFusionCallback? externalFusion;

  static final List<_SpecRule> _rules = <_SpecRule>[
    _SpecRule(
      id: 'res_8k',
      group: 'resolution',
      label: '8K',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1440[pi]|2k|qhd|wqhd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|2560|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:4320[pi]|8k|fuhd|7680[ ]*[x×][ ]*4320[pi]?)(?![a-z0-9])',
      priority: 100,
      style: 'uhdGold',
    ),
    _SpecRule(
      id: 'res_4k',
      group: 'resolution',
      label: '4K',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|(?:3840|4096)[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
      priority: 110,
      style: 'uhdGold',
    ),
    _SpecRule(
      id: 'res_2k',
      group: 'resolution',
      label: '2K',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:1440[pi]|2k|qhd|wqhd|2560[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
      priority: 120,
      style: 'hdCyan',
    ),
    _SpecRule(
      id: 'res_1080p',
      group: 'resolution',
      label: '1080p',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])|.*(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|.*[^a-z0-9])1080[ ]*(?:高码|蓝光|超清))',
      priority: 130,
      style: 'hdCyan',
    ),
    _SpecRule(
      id: 'res_720p',
      group: 'resolution',
      label: '720p',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:^|.*[^a-z0-9])(?:720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
      priority: 140,
      style: 'sdNeutral',
    ),
    _SpecRule(
      id: 'res_sd',
      group: 'resolution',
      label: 'SD',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?|720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:(?:^|.*[^a-z0-9])(?:(?:480|576)[pi]|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9])|.*标清|(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))',
      priority: 150,
      style: 'sdNeutral',
    ),
    _SpecRule(
      id: 'dr_dv',
      group: 'dynamic_range',
      label: 'DV',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision|(?:dvh[e1]|dav1)(?:\.[0-9]{2}(?:\.[0-9]{2})?)?)(?![a-z0-9])|.*杜比视界)',
      priority: 210,
      style: 'visionPurple',
    ),
    _SpecRule(
      id: 'dr_hdr10plus',
      group: 'dynamic_range',
      label: 'HDR10+',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9]))',
      priority: 220,
      style: 'visionPurple',
    ),
    _SpecRule(
      id: 'dr_hdr10',
      group: 'dynamic_range',
      label: 'HDR10',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9]))',
      priority: 230,
      style: 'hdrBlue',
    ),
    _SpecRule(
      id: 'dr_hlg',
      group: 'dynamic_range',
      label: 'HLG',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:hlg|arib[ ._-]?std[ ._-]?b67)(?![a-z0-9])',
      priority: 240,
      style: 'hdrBlue',
    ),
    _SpecRule(
      id: 'dr_hdr',
      group: 'dynamic_range',
      label: 'HDR',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])|hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9])|hlg(?![a-z0-9])|arib[ ._-]?std[ ._-]?b67(?![a-z0-9])|(?:non|no)[ ._-]?hdr(?![a-z0-9])))(?:(?:^|.*[^a-z0-9])(?:hdr(?:[ ._-]?vivid)?(?![a-z0-9])|hdr10[ ._-]?bits?(?![a-z0-9]))|(?=(?:^|.*[^a-z0-9])bt\.?2020(?![a-z0-9]))(?=(?:^|.*[^a-z0-9])pq(?![a-z0-9])).*|.*臻彩)',
      priority: 250,
      style: 'hdrBlue',
    ),
    _SpecRule(
      id: 'src_remux',
      group: 'source_quality',
      label: 'REMUX',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9])',
      priority: 310,
      style: 'discEmerald',
    ),
    _SpecRule(
      id: 'src_bluray',
      group: 'source_quality',
      label: 'BluRay',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9]))(?:(?:^|.*[^a-z0-9])(?:(?:blu[ ._-]?ray|bdrip|brrip|bdmv|bdiso|uhdbd|bd(?:25|50|66|100))(?![a-z0-9])|bd(?![a-z0-9])(?!://))|.*(?:蓝光原盘|原盘))',
      priority: 320,
      style: 'discEmerald',
    ),
    _SpecRule(
      id: 'src_webdl',
      group: 'source_quality',
      label: 'WEB-DL',
      pattern: r'^(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9])',
      priority: 330,
      style: 'streamTeal',
    ),
    _SpecRule(
      id: 'src_webrip',
      group: 'source_quality',
      label: 'WEBRip',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9]))(?:^|.*[^a-z0-9])web[ ._-]?rip(?![a-z0-9])',
      priority: 340,
      style: 'streamTeal',
    ),
    _SpecRule(
      id: 'src_hdtv',
      group: 'source_quality',
      label: 'HDTV',
      pattern: r'^(?:^|.*[^a-z0-9])(?:hdtv(?:rip)?|pdtv|dsr)(?![a-z0-9])',
      priority: 350,
      style: 'streamTeal',
    ),
    _SpecRule(
      id: 'aud_atmos',
      group: 'audio_codec',
      label: 'ATMOS',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9])(?:atmos(?![a-z0-9])|e[ ._-]?ac[ ._-]?3[ ._-]?joc(?![a-z0-9])|ec\+3(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))|.*(?:杜比)?全景声)',
      priority: 410,
      style: 'spatialAudio',
    ),
    _SpecRule(
      id: 'aud_dtsx',
      group: 'audio_codec',
      label: 'DTS:X',
      pattern:
          r'^(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 420,
      style: 'spatialAudio',
    ),
    _SpecRule(
      id: 'aud_truehd',
      group: 'audio_codec',
      label: 'TrueHD',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:true[ ._-]?hd|mlp)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 430,
      style: 'spatialAudio',
    ),
    _SpecRule(
      id: 'aud_dtshd_ma',
      group: 'audio_codec',
      label: 'DTS-HD MA',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 440,
      style: 'spatialAudio',
    ),
    _SpecRule(
      id: 'aud_dtshd',
      group: 'audio_codec',
      label: 'DTS-HD',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd(?:[ ._-]?(?:hr|hra))?|dts[ ._-]?(?:hr|hra))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 450,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_dts',
      group: 'audio_codec',
      label: 'DTS',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd(?:[ ._-]?(?:ma|hr|hra))?|dts[ ._-]?(?:ma|xll|hr|hra))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])dts(?:[ ._-]?es)?(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 460,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_ddp',
      group: 'audio_codec',
      label: 'DD+',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:dd\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))',
      priority: 470,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_dd',
      group: 'audio_codec',
      label: 'DD',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9])(?:dd\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))))(?:(?:^|.*[^a-z0-9])(?:ac[ ._-]?3|dolby[ ._-]?(?:digital|audio))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))|(?:^|.*[^a-z0-9])dd[ ._-]?[125678]\.[01](?![0-9])|(?:^|.*[^a-z0-9/])dd(?![a-z0-9+/]))',
      priority: 480,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_lpcm',
      group: 'audio_codec',
      label: 'LPCM',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:lpcm|pcm)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 485,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_flac',
      group: 'audio_codec',
      label: 'FLAC',
      pattern:
          r'^(?:^|.*[^a-z0-9])flac(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 490,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_opus',
      group: 'audio_codec',
      label: 'OPUS',
      pattern:
          r'^(?:^|.*[^a-z0-9])opus(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
      priority: 492,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'aud_aac',
      group: 'audio_codec',
      label: 'AAC',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:he[ ._-]?)?aac(?:[ ._-]?lc)?(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))|mp4a(?:\.40\.[0-9]+)?(?![a-z0-9]))',
      priority: 495,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'ch_7_1',
      group: 'audio_channels',
      label: '7.1',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))',
      priority: 510,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'ch_5_1',
      group: 'audio_channels',
      label: '5.1',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))5\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])6[ ]*ch(?:annels?)?(?![a-z0-9]))',
      priority: 520,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'ch_2_0',
      group: 'audio_channels',
      label: '2.0',
      pattern:
          r'^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))[57]\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])[68][ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))2\.0(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])(?:2[ ]*ch(?:annels?)?|stereo)(?![a-z0-9])|.*(?:立体声|双声道))',
      priority: 530,
      style: 'standardAudio',
    ),
    _SpecRule(
      id: 'vid_av1',
      group: 'video_codec',
      label: 'AV1',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:svt[ ._-]?)?av1|(?:av01|dav1)(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
      priority: 610,
      style: 'codecSlate',
    ),
    _SpecRule(
      id: 'vid_hevc',
      group: 'video_codec',
      label: 'HEVC',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:hevc|[hx][ ._-]?265|h(?:ev|vc)1(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
      priority: 620,
      style: 'codecSlate',
    ),
    _SpecRule(
      id: 'vid_vp9',
      group: 'video_codec',
      label: 'VP9',
      pattern: r'^(?:^|.*[^a-z0-9])(?:vp9|vp09(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
      priority: 630,
      style: 'codecSlate',
    ),
    _SpecRule(
      id: 'vid_avc',
      group: 'video_codec',
      label: 'AVC',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:avc|[hx][ ._-]?264|avc1(?:\.[0-9a-z]+)?)(?![a-z0-9])',
      priority: 640,
      style: 'codecSlate',
    ),
    _SpecRule(
      id: 'plt_nf',
      group: 'release_platform',
      label: 'NF',
      pattern: r'^(?:^|.*[^a-z0-9])(?:netflix|nflx|nf)(?![a-z0-9])',
      priority: 710,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_amzn',
      group: 'release_platform',
      label: 'AMZN',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:amzn|amazon|prime[ ._-]?video)(?![a-z0-9])',
      priority: 715,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_atvp',
      group: 'release_platform',
      label: 'ATVP',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:atvp|aptv)(?![a-z0-9])|apple[ ._-]?tv\+(?![a-z0-9])|apple[ ._-]?tv(?![a-z0-9+]))',
      priority: 720,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_dsnp',
      group: 'release_platform',
      label: 'DSNP',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:dsnp|dsny)(?![a-z0-9])|disney\+(?![a-z0-9])|disney[ ._-]?plus(?![a-z0-9]))',
      priority: 725,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_max',
      group: 'release_platform',
      label: 'MAX',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:hmax(?![a-z0-9])|hbo[ ._-]?max(?![a-z0-9])|max(?=[ ._-]+(?:2160[pi]|1080[pi]|720[pi]|4k|web[ ._-]?(?:dl|rip))(?![a-z0-9])))',
      priority: 730,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_hulu',
      group: 'release_platform',
      label: 'HULU',
      pattern: r'^(?:^|.*[^a-z0-9])hulu(?![a-z0-9])',
      priority: 735,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_pcok',
      group: 'release_platform',
      label: 'PCOK',
      pattern: r'^(?:^|.*[^a-z0-9])(?:pcok|peacock)(?![a-z0-9])',
      priority: 740,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_pmtp',
      group: 'release_platform',
      label: 'PMTP',
      pattern:
          r'^(?:^|.*[^a-z0-9])(?:(?:pmtp|pamp)(?![a-z0-9])|paramount\+(?![a-z0-9])|paramount[ ._-]?plus(?![a-z0-9]))',
      priority: 745,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_bili',
      group: 'release_platform',
      label: 'BILI',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9])(?:bili(?:bili)?|b[ ._-]?global)(?![a-z0-9])|(?:^|.*[^a-z0-9])b站(?!点))',
      priority: 750,
      style: 'platformTag',
    ),
    _SpecRule(
      id: 'plt_cr',
      group: 'release_platform',
      label: 'CR',
      pattern:
          r'^(?:(?:^|.*[^a-z0-9])crunchyroll(?![a-z0-9])|.*\[cr\]|(?:^|.*[^a-z0-9])cr(?=[ ._-]+(?:1080[pi]|720[pi]|web[ ._-]?(?:dl|rip))(?![a-z0-9])))',
      priority: 755,
      style: 'platformTag',
    ),
  ];

  static final Map<String, _SpecRule> _rulesById = <String, _SpecRule>{
    for (final rule in _rules) rule.id: rule,
  };

  static const List<_ComboRule> _comboRules = <_ComboRule>[
    _ComboRule(
      id: 'combo_dv_atmos',
      group: 'dynamic_range',
      label: 'DV · ATMOS',
      requires: <String>['dr_dv', 'aud_atmos'],
      consumes: <String>['dr_dv', 'aud_atmos'],
      priority: 205,
      style: 'premiumCombo',
    ),
    _ComboRule(
      id: 'combo_dv_truehd',
      group: 'dynamic_range',
      label: 'DV · TrueHD',
      requires: <String>['dr_dv', 'aud_truehd'],
      consumes: <String>['dr_dv', 'aud_truehd'],
      priority: 206,
      style: 'premiumCombo',
    ),
    _ComboRule(
      id: 'combo_dv_ddp',
      group: 'dynamic_range',
      label: 'DV · DD+',
      requires: <String>['dr_dv', 'aud_ddp'],
      consumes: <String>['dr_dv', 'aud_ddp'],
      priority: 207,
      style: 'premiumCombo',
    ),
  ];

  static int _hexVal(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
    if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
    return -1;
  }

  /// Exact `+`-preserving percent-decoding & whitespace normalization contract
  /// from `shared/ui-spec/badge-rules.json`.
  static String normalize(String? input) {
    if (input == null || input.isEmpty) return '';
    // Step 2: percent-decode valid %XX UTF-8 runs ONLY (keep literal '+').
    final decodedBuf = StringBuffer();
    final len = input.length;
    var i = 0;
    while (i < len) {
      final cu = input.codeUnitAt(i);
      if (cu == 0x25 && i + 2 < len) {
        final h1 = _hexVal(input.codeUnitAt(i + 1));
        final h2 = _hexVal(input.codeUnitAt(i + 2));
        if (h1 >= 0 && h2 >= 0) {
          final bytes = <int>[];
          while (i + 2 < len && input.codeUnitAt(i) == 0x25) {
            final a = _hexVal(input.codeUnitAt(i + 1));
            final b = _hexVal(input.codeUnitAt(i + 2));
            if (a < 0 || b < 0) break;
            bytes.add((a << 4) | b);
            i += 3;
          }
          decodedBuf.write(utf8.decode(bytes, allowMalformed: true));
          continue;
        }
      }
      decodedBuf.writeCharCode(cu);
      i++;
    }

    // Step 3 & 4: collapse space/controls and strip leading/trailing 0x0020.
    final decoded = decodedBuf.toString();
    final collapsed = StringBuffer();
    var lastWasSpace = true;
    for (var j = 0; j < decoded.length; j++) {
      final ch = decoded.codeUnitAt(j);
      final isWs = ch <= 0x0020 ||
          (ch >= 0x007F && ch <= 0x00A0) ||
          ch == 0x2028 ||
          ch == 0x2029 ||
          ch == 0x3000 ||
          ch == 0xFEFF;
      if (isWs) {
        if (!lastWasSpace) {
          collapsed.writeCharCode(0x0020);
          lastWasSpace = true;
        }
      } else {
        collapsed.writeCharCode(ch);
        lastWasSpace = false;
      }
    }
    var out = collapsed.toString();
    if (out.isNotEmpty && out.codeUnitAt(out.length - 1) == 0x0020) {
      out = out.substring(0, out.length - 1);
    }

    // Step 5: surrogate-safe 1024 UTF-16 code-unit cap.
    if (out.length > _maxNormCodeUnits) {
      var cut = _maxNormCodeUnits;
      final last = out.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        cut -= 1;
      }
      out = out.substring(0, cut);
      while (out.isNotEmpty && out.codeUnitAt(out.length - 1) == 0x0020) {
        out = out.substring(0, out.length - 1);
      }
    }
    return out;
  }

  static Set<String> _matchRawRuleIds(String? text) {
    final norm = normalize(text);
    if (norm.isEmpty) return <String>{};
    final matched = <String>{};
    for (final rule in _rules) {
      if (rule.regex.hasMatch(norm)) {
        matched.add(rule.id);
      }
    }
    return matched;
  }

  static String? _resolutionRuleIdFromDimensions(int width, int height) {
    if (width <= 0 || height <= 0) return null;
    final maxDim = math.max(width, height);
    final minDim = math.min(width, height);
    if (maxDim >= 7600 || minDim >= 4300) return 'res_8k';
    if (maxDim >= 3800 || minDim >= 2100) return 'res_4k';
    if (maxDim >= 2500 || minDim >= 1400) return 'res_2k';
    if (maxDim >= 1900 || minDim >= 1000) return 'res_1080p';
    if (maxDim >= 1200 || minDim >= 700) return 'res_720p';
    return 'res_sd';
  }

  /// Dual-channel group-safe fusion per `player-hud-spec.md §4.1`:
  /// - Channel A (`M_track`): real decoded dimensions (`videoWidth x videoHeight`)
  ///   + live track codecs/descriptions.
  /// - Channel B (`M_meta`): line name + episode name + stream filename.
  /// - When real dimensions are known (`w > 0 && h > 0`), the `resolution` group
  ///   strictly comes from Channel A so misleading metadata like `"4K专线"` can
  ///   NEVER mislabel a `960x540` stream as `4K`.
  static List<PlayerSpecBadge> fuse({
    required int videoWidth,
    required int videoHeight,
    String videoCodec = '',
    String audioCodec = '',
    String extraTrackInfo = '',
    String lineName = '',
    String episodeName = '',
    String streamUrl = '',
    int maxBadges = maxStartSpecBadges,
  }) {
    final trackDesc = <String>[
      if (videoWidth > 0 && videoHeight > 0) '${videoWidth}x$videoHeight',
      if (videoCodec.trim().isNotEmpty) videoCodec.trim(),
      if (audioCodec.trim().isNotEmpty) audioCodec.trim(),
      if (extraTrackInfo.trim().isNotEmpty) extraTrackInfo.trim(),
    ].join(' ');
    final urlFileName = streamUrl.split('?').first.split('/').last;
    final metaDesc = <String>[
      if (lineName.trim().isNotEmpty) lineName.trim(),
      if (episodeName.trim().isNotEmpty) episodeName.trim(),
      if (urlFileName.trim().isNotEmpty) urlFileName.trim(),
    ].join(' ');

    if (externalFusion != null) {
      return externalFusion!(
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        trackDescription: trackDesc,
        metadataDescription: metaDesc,
      ).take(maxBadges).toList(growable: false);
    }

    final trackIds = _matchRawRuleIds(trackDesc);
    final metaIds = _matchRawRuleIds(metaDesc);
    final dimRuleId = _resolutionRuleIdFromDimensions(videoWidth, videoHeight);

    final merged = <String>{};

    // 1. Resolution group: strictly from real decoded dimensions when known.
    if (dimRuleId != null) {
      merged.add(dimRuleId);
    } else {
      final trackRes = trackIds
          .where((id) => _rulesById[id]?.group == 'resolution')
          .toList();
      if (trackRes.isNotEmpty) {
        merged.addAll(trackRes);
      } else {
        merged.addAll(
          metaIds.where((id) => _rulesById[id]?.group == 'resolution'),
        );
      }
    }

    // 2. source_quality & release_platform come from Channel B (metadata).
    for (final id in metaIds) {
      final g = _rulesById[id]?.group;
      if (g == 'source_quality' || g == 'release_platform') {
        merged.add(id);
      }
    }

    // 3. Other groups prefer Channel A (track), falling back / supplementing
    //    from Channel B (including dr_dv / aud_atmos).
    const remainingGroups = <String>[
      'dynamic_range',
      'audio_codec',
      'audio_channels',
      'video_codec',
    ];
    for (final group in remainingGroups) {
      final fromTrack =
          trackIds.where((id) => _rulesById[id]?.group == group).toSet();
      final fromMeta =
          metaIds.where((id) => _rulesById[id]?.group == group).toSet();
      if (fromTrack.isNotEmpty) {
        merged.addAll(fromTrack);
        if (group == 'dynamic_range') {
          if (fromMeta.contains('dr_dv')) {
            merged.add('dr_dv');
          }
          const baseHdrIds = <String>{
            'dr_hdr10plus',
            'dr_hdr10',
            'dr_hlg',
            'dr_hdr',
          };
          final trackHasBaseHdr = fromTrack.any(baseHdrIds.contains);
          if (!trackHasBaseHdr) {
            merged.addAll(fromMeta.where(baseHdrIds.contains));
          }
        }
        if (group == 'audio_codec' && fromMeta.contains('aud_atmos')) {
          merged.add('aud_atmos');
        }
      } else {
        merged.addAll(fromMeta);
      }
    }

    // 4. Single comboRules pass in deterministic (priority ASC, id ASC) order.
    final result = <PlayerSpecBadge>[];
    for (final combo in _comboRules) {
      if (combo.requires.every(merged.contains)) {
        merged.removeAll(combo.consumes);
        result.add(combo.toBadge());
      }
    }

    for (final id in merged) {
      final rule = _rulesById[id];
      if (rule != null) result.add(rule.toBadge());
    }

    result.sort((a, b) {
      final cmp = a.priority.compareTo(b.priority);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });

    if (result.length > maxBadges) {
      return result.sublist(0, maxBadges);
    }
    return result;
  }
}

/// Manages the once-per-session start-of-playback spec highlight lifecycle:
/// 350ms after first frame ready (`w > 0 && h > 0`) -> visible for 3000ms ->
/// settles quietly. Guaranteed timer cleanup on reset/dispose.
class StartSpecDisplayController extends ChangeNotifier {
  static const int triggerDelayMs = 350;
  static const int displayDurationMs = 3000;

  Timer? _delayTimer;
  Timer? _hideTimer;
  bool _triggeredForSession = false;
  bool _highlightActive = false;
  bool _disposed = false;

  bool get highlightActive => _highlightActive;
  bool get hasTriggeredForSession => _triggeredForSession;

  void onFirstFrameReady({required bool enabled, required bool isLive}) {
    if (_disposed || _triggeredForSession || !enabled || isLive || OhosRuntime.isOhos) {
      return;
    }
    _triggeredForSession = true;
    _delayTimer?.cancel();
    _delayTimer = Timer(const Duration(milliseconds: triggerDelayMs), () {
      if (_disposed) return;
      _highlightActive = true;
      notifyListeners();
      _hideTimer?.cancel();
      _hideTimer = Timer(const Duration(milliseconds: displayDurationMs), () {
        if (_disposed) return;
        _highlightActive = false;
        notifyListeners();
      });
    });
  }

  void resetForNewSession() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    _triggeredForSession = false;
    if (_highlightActive) {
      _highlightActive = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    super.dispose();
  }
}

/// Visual tokens matching `shared/ui-spec/motion-tokens.json` `badgeStyles`.
class SpecBadgeStyleColors {
  final Color fill;
  final Color stroke;
  final Color text;
  final Color solidFill;

  const SpecBadgeStyleColors({
    required this.fill,
    required this.stroke,
    required this.text,
    required this.solidFill,
  });

  static SpecBadgeStyleColors forStyle(String style) => switch (style) {
        'uhdGold' => const SpecBadgeStyleColors(
            fill: Color(0x2EFF9F0A),
            stroke: Color(0x66FF9F0A),
            text: Color(0xFFFFB340),
            solidFill: Color(0xEB3A2810),
          ),
        'hdCyan' => const SpecBadgeStyleColors(
            fill: Color(0x2964D2FF),
            stroke: Color(0x5C64D2FF),
            text: Color(0xFF70D7FF),
            solidFill: Color(0xEB142C38),
          ),
        'sdNeutral' => const SpecBadgeStyleColors(
            fill: Color(0x33787884),
            stroke: Color(0x4DEBEBF5),
            text: Color(0xFFD1D1DA),
            solidFill: Color(0xEB25252B),
          ),
        'premiumCombo' => const SpecBadgeStyleColors(
            fill: Color(0x335E5CE6),
            stroke: Color(0x73BF5AF2),
            text: Color(0xFFE5C7FF),
            solidFill: Color(0xEB261F42),
          ),
        'visionPurple' => const SpecBadgeStyleColors(
            fill: Color(0x2EBF5AF2),
            stroke: Color(0x66BF5AF2),
            text: Color(0xFFDEB0FF),
            solidFill: Color(0xEB2D1B38),
          ),
        'hdrBlue' => const SpecBadgeStyleColors(
            fill: Color(0x2E0A84FF),
            stroke: Color(0x660A84FF),
            text: Color(0xFF64D2FF),
            solidFill: Color(0xEB122640),
          ),
        'discEmerald' => const SpecBadgeStyleColors(
            fill: Color(0x2930D158),
            stroke: Color(0x5C30D158),
            text: Color(0xFF63E682),
            solidFill: Color(0xEB142E1C),
          ),
        'streamTeal' => const SpecBadgeStyleColors(
            fill: Color(0x265AC8FA),
            stroke: Color(0x525AC8FA),
            text: Color(0xFF82D7FF),
            solidFill: Color(0xEB152936),
          ),
        'spatialAudio' => const SpecBadgeStyleColors(
            fill: Color(0x2E0A84FF),
            stroke: Color(0x665AC8FA),
            text: Color(0xFF8AE0FF),
            solidFill: Color(0xEB13283D),
          ),
        'standardAudio' => const SpecBadgeStyleColors(
            fill: Color(0x38787884),
            stroke: Color(0x3BFFFFFF),
            text: Color(0xFFF5F5F7),
            solidFill: Color(0xEB28282E),
          ),
        'codecSlate' => const SpecBadgeStyleColors(
            fill: Color(0x29787884),
            stroke: Color(0x29FFFFFF),
            text: Color(0xFFD1D1DA),
            solidFill: Color(0xEB222228),
          ),
        'platformTag' => const SpecBadgeStyleColors(
            fill: Color(0x2E36363D),
            stroke: Color(0x45FFFFFF),
            text: Color(0xFFEBEBF5),
            solidFill: Color(0xEB28282E),
          ),
        _ => const SpecBadgeStyleColors(
            fill: Color(0x33787884),
            stroke: Color(0x45FFFFFF),
            text: Color(0xFFF5F5F7),
            solidFill: Color(0xEB25252B),
          ),
      };
}

/// Pure typography media spec pill (zero trademark logos).
class SpecBadgePill extends StatelessWidget {
  final PlayerSpecBadge badge;
  final bool compact;
  final bool concentric;
  final bool reduceTransparency;

  const SpecBadgePill({
    super.key,
    required this.badge,
    this.compact = true,
    this.concentric = false,
    this.reduceTransparency = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveReduce = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final colors = SpecBadgeStyleColors.forStyle(badge.style);
    final height = compact ? 18.0 : 23.0;
    final radius = concentric ? 999.0 : (compact ? 4.5 : 6.0);
    // Avoid `alignment:` on Container without an explicit width — inside a
    // `Wrap` that causes Container to expand to `constraints.maxWidth` and
    // stretch each badge into a full-width bar. Use tight `Row(mainAxisSize: min)`
    // instead so every spec badge shrink-wraps cleanly to its label.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: effectiveReduce ? colors.solidFill : colors.fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: effectiveReduce
              ? colors.stroke.withValues(alpha: math.max(colors.stroke.a, 0.55))
              : colors.stroke,
          width: 0.85,
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5.5 : 7.5,
            vertical: compact ? 2.5 : 4.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                badge.label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: colors.text,
                  fontSize: compact ? 9.5 : 11.5,
                  fontWeight: compact ? FontWeight.w700 : FontWeight.w700,
                  letterSpacing: compact ? 0.25 : 0.35,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline badge row embedded inside the player top header so media spec badges
/// NEVER collide or overlap with the top-left return capsule.
class InlineSpecBadgeRow extends StatelessWidget {
  final List<PlayerSpecBadge> badges;
  final bool expanded;
  final bool concentric;
  final bool reduceTransparency;

  const InlineSpecBadgeRow({
    super.key,
    required this.badges,
    required this.expanded,
    this.concentric = false,
    this.reduceTransparency = false,
  });

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return const SizedBox.shrink();
    final visible = expanded ? badges.take(5).toList() : badges.take(2).toList();
    return Wrap(
      key: const Key('player-video-specs'),
      spacing: 4.5,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final badge in visible)
          SpecBadgePill(
            badge: badge,
            compact: true,
            concentric: concentric,
            reduceTransparency: reduceTransparency,
          ),
      ],
    );
  }
}

/// Standalone top-left start-of-playback spec banner.
///
/// Per `player-hud-spec.md §4.1` and `motion-tokens.json`:
/// - Fades in over `180ms` (`Curves.easeOutCubic`) and fades out over `240ms`
///   (`Curves.easeInCubic`) when `controlsVisible == false` (instant snap under
///   `MediaQuery.disableAnimationsOf(context)`).
/// - Unmounts the subtree strictly once `AnimationStatus.dismissed` is reached.
/// - Immediately hides (`value = 0.0`) whenever `controlsVisible == true` so it
///   can never overlap the top-left return button, handing off cleanly to
///   [InlineSpecBadgeRow] inside the top header.
/// - Constrains width via `Positioned(left: left, right: left, top: top)` +
///   `Align(alignment: Alignment.topLeft)` so 4–5 badges wrap cleanly at `320pt`
///   iPad Split-View without horizontal overflow.
class StartSpecOverlay extends StatefulWidget {
  final List<PlayerSpecBadge> badges;
  final bool highlightActive;
  final bool controlsVisible;
  final bool concentric;
  final bool reduceTransparency;

  const StartSpecOverlay({
    super.key,
    required this.badges,
    required this.highlightActive,
    required this.controlsVisible,
    this.concentric = false,
    this.reduceTransparency = false,
  });

  @override
  State<StartSpecOverlay> createState() => _StartSpecOverlayState();
}

class _StartSpecOverlayState extends State<StartSpecOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final CurvedAnimation _opacityAnim = CurvedAnimation(
    parent: _fadeCtrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _initialized = false;
  bool _reduceMotion = false;

  bool get _shouldShow =>
      !OhosRuntime.isOhos &&
      widget.badges.isNotEmpty &&
      widget.highlightActive &&
      !widget.controlsVisible;

  @override
  void initState() {
    super.initState();
    _fadeCtrl.addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (mounted && status == AnimationStatus.dismissed) {
      setState(() {});
    }
  }

  void _syncAnimation({required bool immediateHide}) {
    if (immediateHide || OhosRuntime.isOhos || widget.badges.isEmpty) {
      _fadeCtrl.stop();
      if (_fadeCtrl.value != 0.0) {
        _fadeCtrl.value = 0.0;
      }
      return;
    }
    if (_shouldShow) {
      if (_reduceMotion) {
        _fadeCtrl.stop();
        _fadeCtrl.value = 1.0;
      } else if (_fadeCtrl.status != AnimationStatus.forward &&
          _fadeCtrl.status != AnimationStatus.completed) {
        _fadeCtrl.forward();
      }
    } else {
      if (_reduceMotion) {
        _fadeCtrl.stop();
        _fadeCtrl.value = 0.0;
      } else if (_fadeCtrl.status != AnimationStatus.reverse &&
          _fadeCtrl.status != AnimationStatus.dismissed) {
        _fadeCtrl.reverse();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!_initialized) {
      _initialized = true;
      _syncAnimation(immediateHide: widget.controlsVisible);
    }
  }

  @override
  void didUpdateWidget(covariant StartSpecOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    final controlsJustOpened = widget.controlsVisible;
    _syncAnimation(immediateHide: controlsJustOpened);
  }

  @override
  void dispose() {
    _fadeCtrl.removeStatusListener(_handleAnimationStatus);
    _opacityAnim.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos ||
        widget.badges.isEmpty ||
        widget.controlsVisible ||
        (!_shouldShow && _fadeCtrl.status == AnimationStatus.dismissed)) {
      return const SizedBox.shrink();
    }
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final left = math.max(16.0, viewPadding.left + 12.0);
    final top = math.max(16.0, viewPadding.top + 12.0);
    final effectiveReduce = widget.reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);

    return Positioned(
      left: left,
      right: left,
      top: top,
      child: Align(
        alignment: Alignment.topLeft,
        child: IgnorePointer(
          child: FadeTransition(
            key: const Key('player-start-spec-overlay'),
            opacity: _opacityAnim,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: effectiveReduce
                    ? const Color(0xEB16161A)
                    : const Color(0x99121318),
                borderRadius:
                    BorderRadius.circular(widget.concentric ? 18 : 12),
                border: Border.all(
                  color: Colors.white.withValues(
                    alpha: effectiveReduce ? 0.45 : 0.18,
                  ),
                  width: 0.75,
                ),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final badge in widget.badges.take(5))
                    SpecBadgePill(
                      badge: badge,
                      compact: false,
                      concentric: widget.concentric,
                      reduceTransparency: effectiveReduce,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
