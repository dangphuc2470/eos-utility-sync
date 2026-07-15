import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/config_slot.dart';

class ConfigService {
  static const String _slotsKey = 'slots_v2';
  static const String _activeSlotKey = 'active_slot_id';
  static const String _localBaseKey = 'local_base_path';
  static const String _driveBaseKey = 'drive_base_path';
  static const String _autoPushKey = 'auto_push_changes';

  static const String defaultLocalBase = r'C:\Users\HP\AppData\Local\Canon_INC';
  static const String defaultDriveBase = r'G:\My Drive\Sync\Canon_INC';

  // ── Persistence ──────────────────────────────────────────────

  Future<List<ConfigSlot>> loadSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_slotsKey);
    if (raw == null) return [];
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => ConfigSlot.fromJson(e)).toList();
  }

  Future<void> saveSlots(List<ConfigSlot> slots) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _slotsKey,
      jsonEncode(slots.map((s) => s.toJson()).toList()),
    );
  }

  Future<String?> getActiveSlotId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeSlotKey);
  }

  Future<void> setActiveSlotId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeSlotKey, id);
  }

  Future<String> getLocalBasePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_localBaseKey) ?? defaultLocalBase;
  }

  Future<String> getDriveBasePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_driveBaseKey) ?? defaultDriveBase;
  }

  Future<void> setLocalBasePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localBaseKey, path);
  }

  Future<void> setDriveBasePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_driveBaseKey, path);
  }

  Future<bool> getAutoPush() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoPushKey) ?? true;
  }

  Future<void> setAutoPush(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPushKey, enabled);
  }

  // ── XML Reading / Writing ────────────────────────────────────

  /// Parse all settings from a user.config XML file
  Map<String, String> parseConfig(String xmlContent) {
    final doc = XmlDocument.parse(xmlContent);
    final result = <String, String>{};
    for (final setting in doc.findAllElements('setting')) {
      final name = setting.getAttribute('name');
      final value = setting.findElements('value').firstOrNull?.innerText ?? '';
      if (name != null) result[name] = value;
    }
    return result;
  }

  /// Write settings back into a user.config XML string, preserving structure
  String writeConfig(String originalXml, Map<String, String> newSettings) {
    final doc = XmlDocument.parse(originalXml);
    for (final setting in doc.findAllElements('setting')) {
      final name = setting.getAttribute('name');
      if (name != null && newSettings.containsKey(name)) {
        final valueEl = setting.findElements('value').firstOrNull;
        if (valueEl != null) {
          valueEl.children
            ..clear()
            ..add(XmlText(newSettings[name]!));
        }
      }
    }
    return doc.toXmlString(pretty: true, indent: '    ');
  }

  // ── Scan local Canon_INC ─────────────────────────────────────

  /// Returns list of {appDir, version, path} for all user.config found
  Future<List<Map<String, String>>> scanLocalConfigs(String localBase) async {
    final baseDir = Directory(localBase);
    if (!baseDir.existsSync()) return [];

    final results = <Map<String, String>>[];
    try {
      for (final appDir in baseDir.listSync().whereType<Directory>()) {
        final appName = appDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!appName.contains('EOS_Utility')) continue;

        for (final versionDir in appDir.listSync().whereType<Directory>()) {
          final versionName = versionDir.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last;

          if (!versionDir.existsSync()) continue;

          // 1. Direct active file
          final activeFile = File('${versionDir.path}\\user.config');
          if (activeFile.existsSync()) {
            results.add({
              'appDir': appName,
              'version': versionName,
              'path': activeFile.path,
              'alias': 'active',
            });
          }

          // 2. Subdirectory alias files
          for (final subDir in versionDir.listSync().whereType<Directory>()) {
            final aliasVal = subDir.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last;
            final subFile = File('${subDir.path}\\user.config');
            if (subFile.existsSync()) {
              results.add({
                'appDir': appName,
                'version': versionName,
                'path': subFile.path,
                'alias': aliasVal.toLowerCase(),
              });
            }
          }
        }
      }
    } catch (_) {}
    return results;
  }

  // ── Upload (read from local → create slot) ───────────────────

  /// Read the best local config (highest FileNameNumber) and return as a slot
  Future<ConfigSlot?> uploadFromLocal({
    required String localBase,
    required String appFilter, // e.g. "EOS_Utility_3"
    required String slotName,
  }) async {
    final all = await scanLocalConfigs(localBase);
    final filtered = all
        .where((e) => e['appDir']!.split('.exe').first == appFilter)
        .toList();

    if (filtered.isEmpty) return null;

    ConfigSlot? best;
    for (final entry in filtered) {
      final file = File(entry['path']!);
      final xml = await file.readAsString();
      final settings = parseConfig(xml);
      final seq = int.tryParse(settings['FileNameNumber'] ?? '0') ?? 0;

      if (best == null || seq > (int.tryParse(best.fileNameNumber) ?? 0)) {
        best = ConfigSlot(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: slotName,
          lastModified: file.lastModifiedSync(),
          settings: settings,
          sourcePath: entry['path'],
        );
      }
    }
    return best;
  }

  // ── Apply (write slot → all matching local versions) ─────────

  Future<List<String>> applySlot({
    required ConfigSlot slot,
    required String localBase,
    required String appFilter,
  }) async {
    return applySettings(
      settings: slot.settings,
      localBase: localBase,
      appFilter: appFilter,
    );
  }

  Future<List<String>> applySettings({
    required Map<String, String> settings,
    required String localBase,
    required String appFilter,
    String? alias,
    String? fallbackPath,
  }) async {
    final targetAlias = (alias ?? 'active').toLowerCase();
    final all = await scanLocalConfigs(localBase);
    final targets = all
        .where(
          (e) =>
              e['appDir']!.split('.exe').first == appFilter &&
              (e['alias'] ?? 'active') == targetAlias,
        )
        .toList();

    final List<String> targetPaths = [];
    if (targets.isNotEmpty) {
      targetPaths.addAll(targets.map((e) => e['path']!));
    } else if (fallbackPath != null) {
      targetPaths.add(fallbackPath);
    }

    final written = <String>[];
    for (final path in targetPaths) {
      final file = File(path);
      try {
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }

        String newXml;
        if (file.existsSync()) {
          try {
            final originalXml = await file.readAsString();
            newXml = writeConfig(originalXml, settings);
          } catch (_) {
            newXml = buildMinimalXml(settings);
          }
        } else {
          newXml = buildMinimalXml(settings);
        }
        await file.writeAsString(newXml);
        written.add(path);
      } catch (e) {
        // skip unwritable
      }
    }
    return written;
  }

  static String getBaseVersionKey(String folderName) {
    if (folderName == 'EOS_Utility') return 'EOS_Utility';
    if (folderName.startsWith('EOS_Utility_2')) return 'EOS_Utility_2';
    if (folderName.startsWith('EOS_Utility_3')) return 'EOS_Utility_3';
    return 'EOS_Utility';
  }

  // ── Drive sync ───────────────────────────────────────────────

  Future<void> uploadSlotToDrive({
    required ConfigSlot slot,
    required String driveBase,
    required String appFilter,
  }) async {
    return uploadSettingsToDrive(
      settings: slot.settings,
      driveBase: driveBase,
      appFilter: appFilter,
    );
  }

  Future<void> uploadSettingsToDrive({
    required Map<String, String> settings,
    required String driveBase,
    required String appFilter,
  }) async {
    final driveDir = Directory('$driveBase\\$appFilter');
    if (!driveDir.existsSync()) driveDir.createSync(recursive: true);
    final driveFile = File('${driveDir.path}\\user.config');

    // Build XML from settings (use a template)
    // We find a template from local if possible
    final localBase = await getLocalBasePath();
    final all = await scanLocalConfigs(localBase);
    final baseKey = getBaseVersionKey(appFilter);
    final template = all.firstWhere(
      (e) => e['appDir']!.split('.exe').first == baseKey,
      orElse: () => {},
    );

    String xml;
    if (template.isNotEmpty) {
      try {
        final templateXml = await File(template['path']!).readAsString();
        xml = writeConfig(templateXml, settings);
      } catch (_) {
        xml = buildMinimalXml(settings);
      }
    } else {
      xml = buildMinimalXml(settings);
    }
    await driveFile.writeAsString(xml);
  }

  String buildMinimalXml(Map<String, String> settings) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buf.writeln('<configuration>');
    buf.writeln('  <userSettings>');
    buf.writeln('    <EOSUtility.AppSettings>');
    for (final e in settings.entries) {
      final escapedKey = _escapeXml(e.key);
      final escapedValue = _escapeXml(e.value);
      buf.writeln('      <setting name="$escapedKey" serializeAs="String">');
      buf.writeln('        <value>$escapedValue</value>');
      buf.writeln('      </setting>');
    }
    buf.writeln('    </EOSUtility.AppSettings>');
    buf.writeln('  </userSettings>');
    buf.writeln('</configuration>');
    return buf.toString();
  }

  String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  // ── Scan Drive Canon_INC ─────────────────────────────────────

  Future<List<Map<String, String>>> scanDriveConfigs(String driveBase) async {
    final baseDir = Directory(driveBase);
    if (!baseDir.existsSync()) return [];

    final results = <Map<String, String>>[];
    try {
      for (final appDir in baseDir.listSync().whereType<Directory>()) {
        final appName = appDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!appName.contains('EOS_Utility')) continue;

        // 1. Check for legacy folder format (e.g. EOS_Utility_3_5d2)
        if (appName.startsWith('EOS_Utility_') &&
            appName.contains(RegExp(r'_[^_]+$'))) {
          final parts = appName.split('_');
          if (parts.length >= 3) {
            final baseKey = 'EOS_Utility_${parts[2]}';
            final aliasVal = parts.sublist(3).join('_');
            if (aliasVal.isNotEmpty) {
              final legacyFile = File('${appDir.path}\\user.config');
              if (legacyFile.existsSync()) {
                results.add({
                  'appDir': appName,
                  'key': baseKey,
                  'alias': aliasVal.toLowerCase(),
                  'path': legacyFile.path,
                });
              }
            }
          }
        }

        // 2. Direct active file (e.g. EOS_Utility_3/user.config)
        final activeFile = File('${appDir.path}\\user.config');
        if (activeFile.existsSync()) {
          results.add({
            'appDir': appName,
            'key': appName,
            'alias': 'active',
            'path': activeFile.path,
          });
        }

        // 3. Child subdirectory alias files (e.g. EOS_Utility_3/5d2/user.config)
        for (final subDir in appDir.listSync().whereType<Directory>()) {
          final aliasVal = subDir.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last;
          final subFile = File('${subDir.path}\\user.config');
          if (subFile.existsSync()) {
            results.add({
              'appDir': appName,
              'key': appName,
              'alias': aliasVal.toLowerCase(),
              'path': subFile.path,
            });
          }
        }
      }
    } catch (_) {}
    return results;
  }

  // ── Drive Fetch ─────────────────────────────────────────────

  /// Fetch the config file from Google Drive if it exists
  Future<Map<String, String>?> fetchDriveConfig({
    required String driveBase,
    required String appFilter,
  }) async {
    final driveFile = File('$driveBase\\$appFilter\\user.config');
    if (!driveFile.existsSync()) return null;
    try {
      final xml = await driveFile.readAsString();
      return parseConfig(xml);
    } catch (e) {
      return null;
    }
  }

  /// Get last modified time of the drive config file
  Future<DateTime?> getDriveConfigLastModified({
    required String driveBase,
    required String appFilter,
  }) async {
    final driveFile = File('$driveBase\\$appFilter\\user.config');
    if (!driveFile.existsSync()) return null;
    try {
      return await driveFile.lastModified();
    } catch (e) {
      return null;
    }
  }
}
