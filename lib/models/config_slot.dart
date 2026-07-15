import 'package:flutter/material.dart';

class ConfigSlot {
  final String id;
  String name;
  DateTime lastModified;
  Map<String, String> settings;
  String? sourcePath; // which local user.config this came from

  ConfigSlot({
    required this.id,
    required this.name,
    required this.lastModified,
    required this.settings,
    this.sourcePath,
  });

  // Key settings getters
  String get fileNameNumber => settings['FileNameNumber'] ?? '0';
  String get saveFolder => settings['SaveFolder'] ?? '';
  String get fileNamePrefix => settings['FileNamePrefix'] ?? 'IMG';
  String get fileNameFigure => settings['FileNameFigure'] ?? '4';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastModified': lastModified.toIso8601String(),
        'settings': settings,
        'sourcePath': sourcePath,
      };

  factory ConfigSlot.fromJson(Map<String, dynamic> json) => ConfigSlot(
        id: json['id'],
        name: json['name'],
        lastModified: DateTime.parse(json['lastModified']),
        settings: Map<String, String>.from(json['settings']),
        sourcePath: json['sourcePath'],
      );

  ConfigSlot copyWith({
    String? name,
    DateTime? lastModified,
    Map<String, String>? settings,
    String? sourcePath,
  }) =>
      ConfigSlot(
        id: id,
        name: name ?? this.name,
        lastModified: lastModified ?? this.lastModified,
        settings: settings ?? Map<String, String>.from(this.settings),
        sourcePath: sourcePath ?? this.sourcePath,
      );

  static String formatSettingValue(String key, String val) {
    if (val.isEmpty) return '—';

    // 1. Delimiter / Separator mapping
    if (key == 'FileNameSeparator' || key == 'FolderNameSeparator') {
      switch (val) {
        case '0':
          return 'Underbar (_)';
        case '1':
          return 'Hyphen (-)';
        case '2':
          return 'None';
        default:
          return val;
      }
    }

    // 2. File Name Figure (Number of digits)
    if (key == 'FileNameFigure') {
      return '$val Digits';
    }

    // 3. Customize Index mappings
    if (key == 'FileCustomizeIndex' || key == 'FileCustomizeSelectedIndex2') {
      switch (val) {
        case '0':
          return 'Prefix + Sequential Number';
        case '1':
          return 'Prefix + Shooting Date + Sequential Number';
        case '2':
          return 'Prefix + Shooting Time + Sequential Number';
        case '3':
          return 'Camera Settings';
        case '4':
          return 'User Settings';
        case '5':
          return 'Custom Rule 1';
        case '6':
          return 'Custom Rule 2';
        case '7':
          return 'Custom Rule 3';
        default:
          return val;
      }
    }

    if (key == 'FolderCustomizeIndex' || key == 'FolderCustomizeSelectedIndex2') {
      switch (val) {
        case '0':
          return 'Default Folder';
        case '1':
          return 'Camera Name';
        case '2':
          return 'Shooting Date';
        case '5':
          return 'Custom Folder Rule 1';
        case '6':
          return 'Custom Folder Rule 2';
        default:
          return val;
      }
    }

    // 4. File Customize string formatting (translating codes like <18>, <8>, <17>)
    if (key.startsWith('FileCustomize') && key != 'FileCustomizeIndex' && key != 'FileCustomizeSelectedIndex2') {
      if (val.replaceAll('|', '').trim().isEmpty) {
        return 'Not configured';
      }
      final segments = val.split('|');
      final mappedSegments = segments.map((seg) {
        if (seg.isEmpty) return '';
        switch (seg) {
          case '<0>':
            return '';
          case '<1>':
            return '<Shooting Date yy/mm/dd>';
          case '<2>':
            return '<Shooting Date mm/dd/yy>';
          case '<3>':
            return '<Shooting Date dd/mm/yy>';
          case '<4>':
            return '<Shooting Year (Last Two Digits)>';
          case '<5>':
            return '<Shooting Year>';
          case '<6>':
            return '<Shooting Month>';
          case '<7>':
            return '<Shooting Day>';
          case '<8>':
            return '<Shooting Time>';
          case '<9>':
            return '<Download Time>';
          case '<10>':
            return '<Folder Number>';
          case '<11>':
            return '<Image Number>';
          case '<12>':
            return '<Prefix>';
          case '<13>':
            return '<Owner\'s Name>';
          case '<14>':
            return '<ISO>';
          case '<15>':
            return '<Camera Body No.>';
          case '<16>':
            return '<Camera Model>';
          case '<17>':
            return '<Sequential Number>';
          case '<18>':
            return '<Shooting Date>';
          default:
            return seg;
        }
      }).where((s) => s.isNotEmpty).toList();

      return mappedSegments.join('');
    }

    // 5. Folder Date Order
    if (key == 'FolderDateOrder') {
      switch (val) {
        case '0':
          return 'Year / Month / Day';
        case '1':
          return 'Month / Day / Year';
        case '2':
          return 'Day / Month / Year';
        default:
          return val;
      }
    }

    // 6. Folder Date Format
    if (key == 'FolderDateFormat') {
      switch (val) {
        case '0':
          return 'YYYYMMDD';
        case '1':
          return 'YYYY_MM_DD';
        case '2':
          return 'YYMMDD';
        case '3':
          return 'YY_MM_DD';
        default:
          return val;
      }
    }

    return val;
  }
}

// Groups of settings for the detail screen
class SettingGroup {
  final String title;
  final IconData icon;
  final List<String> keys;

  const SettingGroup({
    required this.title,
    required this.icon,
    required this.keys,
  });
}

const List<SettingGroup> kSettingGroups = [
  SettingGroup(
    title: 'File Naming',
    icon: Icons.edit_note,
    keys: [
      'FileNameNumber',
      'FileNamePrefix',
      'FileNameFigure',
      'FileNameSeparator',
      'FileCustomizeIndex',
      'FileCustomize1',
      'FileCustomize2',
      'FileCustomize3',
      'FileCustomizeSelectedIndex2',
    ],
  ),
  SettingGroup(
    title: 'Save Location',
    icon: Icons.folder_open,
    keys: [
      'SaveFolder',
      'SubFolderDownload',
      'SubFolderCapture',
      'SubFolderFolderWatcher',
      'FolderCustomize1',
      'FolderCustomize2',
      'FolderCustomize3',
      'FolderCustomizeIndex',
      'FolderCustomizeSelectedIndex2',
      'FolderNameSeparator',
      'FolderDateOrder',
      'FolderDateFormat',
    ],
  ),
  SettingGroup(
    title: 'Download',
    icon: Icons.download,
    keys: [
      'DownloadSource',
      'OnlyTransferJpeg',
      'SaveCF',
    ],
  ),
  SettingGroup(
    title: 'Notifications',
    icon: Icons.notifications_none,
    keys: [
      'NotifyJPG',
      'NotifyCRW',
      'NotifyCR2',
      'NotifyTIF',
    ],
  ),
  SettingGroup(
    title: 'Launch Action',
    icon: Icons.rocket_launch,
    keys: [
      'LaunchActionMainMenu',
      'LaunchActionCapture',
      'LaunchActionDownload',
      'LaunchActionSelectDownload',
    ],
  ),
  SettingGroup(
    title: 'Live View',
    icon: Icons.videocam,
    keys: [
      'AutoLaunchQuickPreview',
      'LvRotateType',
      'LvFitHideControlPanel',
      'LvLinkWB',
      'LvGridColor',
      'LvGridLineNum',
      'IsSyncWithStartOfCameraLV',
      'IsSyncWithEndOfCameraLV',
    ],
  ),
  SettingGroup(
    title: 'Linked Apps',
    icon: Icons.link,
    keys: [
      'LinkedApp',
      'IsLinkedAppZB',
      'IsLinkedAppDPP',
      'IsLinkedAppNA',
      'IsLinkedAppOther',
      'IsLinkedAppIBX',
    ],
  ),
  SettingGroup(
    title: 'General',
    icon: Icons.settings,
    keys: [
      'AutoPowerOFF',
      'Rotate',
      'MouseWheelInhibit',
      'TimeWarning',
      'TimeSyncPC',
      'TimeNone',
      'TimeWarningTimeLag',
      'IsZbDispFolder',
      'IsZbSelectAction',
    ],
  ),
];
