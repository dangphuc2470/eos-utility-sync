import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/config_slot.dart';
import '../services/config_service.dart';
import '../theme/app_theme.dart';

class VersionState {
  final String key; // "EOS_Utility", "EOS_Utility_2", "EOS_Utility_3"
  final String displayName; // "EOS Utility", "EOS Utility 2", "EOS Utility 3"
  final String alias; // "active" or e.g. "5d2", "6d"

  Map<String, String>? localSettings;
  String? localPath;
  DateTime? localLastModified;

  Map<String, String>? remoteSettings;
  String? remotePath;
  DateTime? remoteLastModified;

  VersionState({
    required this.key,
    required this.displayName,
    required this.alias,
    this.localSettings,
    this.localPath,
    this.localLastModified,
    this.remoteSettings,
    this.remotePath,
    this.remoteLastModified,
  });

  String get branchName => alias == 'active' ? 'Active' : alias;

  bool get localExists => localSettings != null;
  bool get remoteExists => remoteSettings != null;

  bool get isSynced {
    if (!localExists || !remoteExists) return false;
    final Map<String, String> local = localSettings!;
    final Map<String, String> remote = remoteSettings!;
    if (local.length != remote.length) return false;
    for (final k in local.keys) {
      if (local[k] != remote[k]) return false;
    }
    return true;
  }

  bool get isLocalAhead {
    if (!localExists) return false;
    if (!remoteExists) return true;

    final localSeq = int.tryParse(localSettings!['FileNameNumber'] ?? '0') ?? 0;
    final remoteSeq =
        int.tryParse(remoteSettings!['FileNameNumber'] ?? '0') ?? 0;
    if (localSeq > remoteSeq) return true;
    if (localSeq < remoteSeq) return false;

    if (localLastModified != null && remoteLastModified != null) {
      return localLastModified!.isAfter(remoteLastModified!);
    }
    return false;
  }

  bool get isRemoteAhead {
    if (!remoteExists) return false;
    if (!localExists) return true;

    final localSeq = int.tryParse(localSettings!['FileNameNumber'] ?? '0') ?? 0;
    final remoteSeq =
        int.tryParse(remoteSettings!['FileNameNumber'] ?? '0') ?? 0;
    if (remoteSeq > localSeq) return true;
    if (remoteSeq < localSeq) return false;

    if (remoteLastModified != null && localLastModified != null) {
      return remoteLastModified!.isAfter(localLastModified!);
    }
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────

/// Extract plain custom text segments from a FileCustomize value (pipe-separated).
/// Only returns non-empty, non-token segments (those that don't look like &lt;N&gt; codes).
String _extractCustomText(String? value) {
  if (value == null || value.isEmpty) return '';
  final parts = value.split('|');
  final texts = parts.where(
    (s) => s.isNotEmpty && !RegExp(r'^<\d+>$').hasMatch(s),
  );
  return texts.join('').trim();
}

// ─────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = ConfigService();

  // Dynamically populated branch list
  final List<VersionState> _versions = [];

  String? _selectedVersionKey;
  String? _selectedAlias = 'active';
  bool _selectedIsRemote = false;

  bool _localTreeExpanded = true;
  bool _remoteTreeExpanded = true;
  final Map<String, bool> _localSubExpanded = {
    'EOS_Utility': true,
    'EOS_Utility_2': true,
    'EOS_Utility_3': true,
  };
  final Map<String, bool> _remoteSubExpanded = {
    'EOS_Utility': true,
    'EOS_Utility_2': true,
    'EOS_Utility_3': true,
  };

  String _localBase = ConfigService.defaultLocalBase;
  String _driveBase = ConfigService.defaultDriveBase;
  bool _loading = false;
  OverlayEntry? _toastEntry;
  bool _autoPush = true;
  Timer? _localCheckTimer;

  // Detail panel state
  int _selectedGroupIndex = 0;
  Map<String, String> _editedSettings = {};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, List<String>> _segmentTypes = {};
  bool _hasChanges = false;
  bool _detailLoading = false;
  final Map<String, String> _activeAliases = {};

  @override
  void initState() {
    super.initState();
    _loadAll().then((_) {
      _startLocalCheckTimer();
    });
  }

  @override
  void dispose() {
    _localCheckTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  ConfigSlot? get _selectedSlot {
    if (_selectedVersionKey == null) return null;
    try {
      final vs = _versions.firstWhere(
        (v) => v.key == _selectedVersionKey && v.alias == _selectedAlias,
      );
      final settings = _selectedIsRemote ? vs.remoteSettings : vs.localSettings;
      if (settings == null) return null;
      return ConfigSlot(
        id: vs.key,
        name:
            '${_selectedIsRemote ? "Remote:" : "Local:"} ${vs.displayName} (${vs.branchName})',
        lastModified: _selectedIsRemote
            ? (vs.remoteLastModified ?? DateTime.now())
            : (vs.localLastModified ?? DateTime.now()),
        settings: settings,
        sourcePath: vs.localPath,
      );
    } catch (_) {
      return null;
    }
  }

  bool _areSettingsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    _localBase = await _service.getLocalBasePath();
    _driveBase = await _service.getDriveBasePath();
    _autoPush = await _service.getAutoPush();

    await _fetchLocalAndRemoteStates();

    final prefs = await SharedPreferences.getInstance();
    for (final key in ['EOS_Utility', 'EOS_Utility_2', 'EOS_Utility_3']) {
      final activeVer = _versions.firstWhere(
        (v) => v.key == key && v.alias == 'active',
        orElse: () => VersionState(key: key, displayName: '', alias: 'active'),
      );
      final stored = prefs.getString('active_alias_$key');
      bool matched = false;

      if (stored != null && activeVer.localSettings != null) {
        final storedVer = _versions.firstWhere(
          (v) => v.key == key && v.alias == stored,
          orElse: () => VersionState(key: key, displayName: '', alias: stored),
        );
        if (storedVer.localSettings != null &&
            _areSettingsEqual(
              storedVer.localSettings!,
              activeVer.localSettings!,
            )) {
          _activeAliases[key] = stored;
          matched = true;
        }
      }

      if (!matched && activeVer.localSettings != null) {
        final siblings = _versions
            .where((v) => v.key == key && v.alias != 'active')
            .toList();
        for (final sib in siblings) {
          if (sib.localSettings != null &&
              _areSettingsEqual(sib.localSettings!, activeVer.localSettings!)) {
            _activeAliases[key] = sib.alias;
            await prefs.setString('active_alias_$key', sib.alias);
            matched = true;
            break;
          }
        }
        if (!matched) {
          _activeAliases.remove(key);
          await prefs.remove('active_alias_$key');
        }
      }
    }

    // Auto-select first available local/remote version if nothing is selected
    if (_selectedVersionKey == null) {
      String? firstKey;
      String firstAlias = 'active';
      bool isRemote = false;
      for (final v in _versions) {
        if (v.localExists) {
          firstKey = v.key;
          firstAlias = v.alias;
          isRemote = false;
          break;
        }
      }
      if (firstKey == null) {
        for (final v in _versions) {
          if (v.remoteExists) {
            firstKey = v.key;
            firstAlias = v.alias;
            isRemote = true;
            break;
          }
        }
      }
      if (firstKey != null) {
        _selectedVersionKey = firstKey;
        _selectedAlias = firstAlias;
        _selectedIsRemote = isRemote;
        final slot = _selectedSlot;
        if (slot != null) {
          _loadDetailFor(slot);
        }
      }
    } else {
      final slot = _selectedSlot;
      if (slot != null) {
        _loadDetailFor(slot);
      }
    }
    setState(() => _loading = false);
  }

  Future<void> _fetchLocalAndRemoteStates() async {
    final localConfigs = await _service.scanLocalConfigs(_localBase);
    final remoteConfigs = await _service.scanDriveConfigs(_driveBase);

    // Collect all unique (key, alias) combinations from local and remote
    final branchKeys = <String>{};

    // Add all from local
    for (final cfg in localConfigs) {
      final key = ConfigService.getBaseVersionKey(cfg['appDir']!);
      final alias = cfg['alias'] ?? 'active';
      branchKeys.add('$key:$alias');
    }

    // Add all from remote
    for (final cfg in remoteConfigs) {
      final key = cfg['key']!;
      final alias = cfg['alias']!;
      branchKeys.add('$key:$alias');
    }

    // Always ensure the default 'active' branch exists for the 3 main keys
    branchKeys.add('EOS_Utility:active');
    branchKeys.add('EOS_Utility_2:active');
    branchKeys.add('EOS_Utility_3:active');

    final newVersions = <VersionState>[];

    for (final combined in branchKeys) {
      final parts = combined.split(':');
      final key = parts[0];
      final alias = parts[1];

      String displayName = '';
      if (key == 'EOS_Utility')
        displayName = 'EOS Utility';
      else if (key == 'EOS_Utility_2')
        displayName = 'EOS Utility 2';
      else if (key == 'EOS_Utility_3')
        displayName = 'EOS Utility 3';
      else
        displayName = key;

      final vs = VersionState(key: key, displayName: displayName, alias: alias);

      // 1. Resolve Local
      final localMatch = localConfigs.firstWhere(
        (cfg) =>
            ConfigService.getBaseVersionKey(cfg['appDir']!) == key &&
            cfg['alias'] == alias,
        orElse: () => {},
      );

      if (localMatch.isNotEmpty) {
        final file = File(localMatch['path']!);
        if (file.existsSync()) {
          try {
            final xml = await file.readAsString();
            vs.localSettings = _service.parseConfig(xml);
            vs.localPath = file.path;
            vs.localLastModified = file.lastModifiedSync();
          } catch (_) {}
        }
      }

      // 2. Resolve Remote
      final remoteMatch = remoteConfigs.firstWhere(
        (cfg) => cfg['key'] == key && cfg['alias'] == alias,
        orElse: () => {},
      );
      if (remoteMatch.isNotEmpty) {
        final file = File(remoteMatch['path']!);
        if (file.existsSync()) {
          try {
            final xml = await file.readAsString();
            vs.remoteSettings = _service.parseConfig(xml);
            vs.remotePath = file.path;
            vs.remoteLastModified = file.lastModifiedSync();
          } catch (_) {}
        }
      }

      newVersions.add(vs);
    }

    // Sort: EOS_Utility first, then EOS_Utility_2, then EOS_Utility_3
    // Under each group, 'active' comes first, then other aliases alphabetically
    newVersions.sort((a, b) {
      final keyOrder = {
        'EOS_Utility': 0,
        'EOS_Utility_2': 1,
        'EOS_Utility_3': 2,
      };
      final aKey = keyOrder[a.key] ?? 3;
      final bKey = keyOrder[b.key] ?? 3;
      if (aKey != bKey) {
        return aKey.compareTo(bKey);
      }
      if (a.alias == 'active' && b.alias != 'active') return -1;
      if (a.alias != 'active' && b.alias == 'active') return 1;
      return a.alias.compareTo(b.alias);
    });

    _versions.clear();
    _versions.addAll(newVersions);
  }

  void _startLocalCheckTimer() {
    _localCheckTimer?.cancel();
    _localCheckTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _checkLocalChanges();
    });
  }

  Future<void> _checkLocalChanges() async {
    if (_loading || _detailLoading) return;

    final localConfigs = await _service.scanLocalConfigs(_localBase);
    bool updatedAny = false;

    for (final version in _versions) {
      final localMatch = localConfigs.firstWhere(
        (cfg) =>
            ConfigService.getBaseVersionKey(cfg['appDir']!) == version.key &&
            cfg['alias'] == version.alias,
        orElse: () => {},
      );

      if (localMatch.isNotEmpty) {
        final file = File(localMatch['path']!);
        if (file.existsSync()) {
          try {
            final lastMod = file.lastModifiedSync();
            if (version.localLastModified == null ||
                lastMod.isAfter(version.localLastModified!)) {
              final xml = await file.readAsString();
              final localSettings = _service.parseConfig(xml);

              bool hasChanges = false;
              if (version.localSettings == null) {
                hasChanges = true;
              } else {
                for (final entry in localSettings.entries) {
                  if (version.localSettings![entry.key] != entry.value) {
                    hasChanges = true;
                    break;
                  }
                }
              }

              if (hasChanges) {
                version.localSettings = localSettings;
                version.localPath = file.path;
                version.localLastModified = lastMod;
                updatedAny = true;

                // Active push
                if (_autoPush) {
                  version.remoteSettings = Map<String, String>.from(
                    localSettings,
                  );
                  version.remoteLastModified = lastMod;
                  final driveFolder = version.alias == 'active'
                      ? version.key
                      : '${version.key}_${version.alias}';
                  _service
                      .uploadSettingsToDrive(
                        settings: localSettings,
                        driveBase: _driveBase,
                        appFilter: driveFolder,
                      )
                      .catchError((_) {});
                }

                // If selected and not dirty
                if (version.key == _selectedVersionKey &&
                    version.alias == _selectedAlias &&
                    !_selectedIsRemote &&
                    !_hasChanges) {
                  _editedSettings = Map<String, String>.from(localSettings);
                  _initSegmentTypes();
                  _controllers.forEach((k, ctrl) {
                    if (_editedSettings.containsKey(k)) {
                      ctrl.text = _editedSettings[k]!;
                    }
                    if (k.contains('_seg_')) {
                      final parts = k.split('_seg_');
                      final baseKey = parts[0];
                      final idx = int.tryParse(parts[1]) ?? 0;
                      final origSeg = _parseSegments(
                        _editedSettings[baseKey] ?? '',
                      )[idx];
                      final isTag =
                          origSeg.startsWith('<') && origSeg.endsWith('>');
                      ctrl.text = isTag ? '' : origSeg;
                    }
                  });
                }
              } else {
                // Just update timestamp
                version.localLastModified = lastMod;
                updatedAny = true;
              }
            }
          } catch (_) {}
        }
      }
    }

    if (updatedAny && mounted) {
      setState(() {});
    }
  }

  void _loadDetailFor(ConfigSlot slot) {
    setState(() {
      _detailLoading = true;
      _selectedGroupIndex = 0;
      _hasChanges = false;
    });
    // Clear old controllers
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _editedSettings = Map<String, String>.from(slot.settings);
    _initSegmentTypes();
    setState(() => _detailLoading = false);
  }

  void _selectVersion(String key, String alias, bool isRemote) {
    if (_selectedVersionKey == key &&
        _selectedAlias == alias &&
        _selectedIsRemote == isRemote)
      return;
    setState(() {
      _selectedVersionKey = key;
      _selectedAlias = alias;
      _selectedIsRemote = isRemote;
    });
    final slot = _selectedSlot;
    if (slot != null) {
      _loadDetailFor(slot);
    }
  }

  void _showStatus(String msg, {bool error = false}) {
    _toastEntry?.remove();
    _toastEntry = null;

    final entry = OverlayEntry(
      builder: (context) => _ToastOverlay(message: msg, isError: error),
    );
    _toastEntry = entry;

    Overlay.of(context, rootOverlay: true).insert(entry);

    Future.delayed(const Duration(seconds: 4), () {
      entry.remove();
      if (_toastEntry == entry) _toastEntry = null;
    });
  }

  // ── Segment / detail helpers ─────────────────────────────────

  void _initSegmentTypes() {
    _segmentTypes.clear();
    for (final key in _editedSettings.keys) {
      if ((key.startsWith('FileCustomize') &&
              key != 'FileCustomizeIndex' &&
              key != 'FileCustomizeSelectedIndex2') ||
          (key.startsWith('FolderCustomize') &&
              key != 'FolderCustomizeIndex' &&
              key != 'FolderCustomizeSelectedIndex2')) {
        final val = _editedSettings[key] ?? '';
        final segments = _parseSegments(val);
        _segmentTypes[key] = List.generate(6, (i) {
          final seg = segments[i];
          if (seg.isEmpty) return '';
          if (seg.startsWith('<') && seg.endsWith('>')) return seg;
          return 'custom';
        });
      }
    }
  }

  List<String> _parseSegments(String value) {
    final list = value.split('|');
    while (list.length < 6) {
      list.add('');
    }
    return list.take(6).toList();
  }

  String _reconstructCustomizeValue(List<String> segments) {
    return segments.join('|') + '|';
  }

  void _checkForChanges() {
    final slot = _selectedSlot;
    if (slot == null) return;
    bool changes = false;
    for (final k in slot.settings.keys) {
      if (_editedSettings[k] != slot.settings[k]) {
        changes = true;
        break;
      }
    }
    if (_editedSettings.length != slot.settings.length) changes = true;
    setState(() => _hasChanges = changes);
  }

  TextEditingController _getController(String key, String initialValue) {
    if (!_controllers.containsKey(key)) {
      _controllers[key] = TextEditingController(text: initialValue);
    }
    return _controllers[key]!;
  }

  void _discardChanges() {
    final slot = _selectedSlot;
    if (slot == null) return;
    setState(() {
      _editedSettings = Map<String, String>.from(slot.settings);
      _initSegmentTypes();
      _controllers.forEach((k, ctrl) {
        if (_editedSettings.containsKey(k)) ctrl.text = _editedSettings[k]!;
        if (k.contains('_seg_')) {
          final parts = k.split('_seg_');
          final baseKey = parts[0];
          final idx = int.tryParse(parts[1]) ?? 0;
          final origSeg = _parseSegments(slot.settings[baseKey] ?? '')[idx];
          final isTag = origSeg.startsWith('<') && origSeg.endsWith('>');
          ctrl.text = isTag ? '' : origSeg;
        }
      });
      _hasChanges = false;
    });
  }

  Future<void> _saveChanges() async {
    if (_selectedVersionKey == null) return;
    setState(() => _detailLoading = true);

    final version = _versions.firstWhere(
      (v) => v.key == _selectedVersionKey && v.alias == _selectedAlias,
    );
    final now = DateTime.now();

    if (_selectedIsRemote) {
      version.remoteSettings = Map<String, String>.from(_editedSettings);
      version.remoteLastModified = now;
      try {
        final driveFolder = version.alias == 'active'
            ? version.key
            : '${version.key}\\${version.alias}';
        await _service.uploadSettingsToDrive(
          settings: _editedSettings,
          driveBase: _driveBase,
          appFilter: driveFolder,
        );
        _showStatus('Saved & Uploaded to Drive!');
      } catch (e) {
        _showStatus('Save to Drive failed: $e', error: true);
      }
    } else {
      version.localSettings = Map<String, String>.from(_editedSettings);
      version.localLastModified = now;
      try {
        await _service.applySettings(
          settings: _editedSettings,
          localBase: _localBase,
          appFilter: version.key,
          alias: version.alias,
        );

        if (_autoPush) {
          version.remoteSettings = Map<String, String>.from(_editedSettings);
          version.remoteLastModified = now;
          final driveFolder = version.alias == 'active'
              ? version.key
              : '${version.key}\\${version.alias}';
          await _service.uploadSettingsToDrive(
            settings: _editedSettings,
            driveBase: _driveBase,
            appFilter: driveFolder,
          );
          _showStatus('Saved & Synced to PC & Drive!');
        } else {
          _showStatus('Saved & Applied to PC!');
        }
      } catch (e) {
        _showStatus('Save failed: $e', error: true);
      }
    }

    setState(() {
      _hasChanges = false;
      _detailLoading = false;
    });
  }

  Future<void> _pushVersion(VersionState version) async {
    if (version.localSettings == null) return;
    setState(() => _loading = true);
    try {
      final driveFolder = version.alias == 'active'
          ? version.key
          : '${version.key}_${version.alias}';
      await _service.uploadSettingsToDrive(
        settings: version.localSettings!,
        driveBase: _driveBase,
        appFilter: driveFolder,
      );
      await _loadAll();
      _showStatus(
        'Pushed "${version.displayName} (${version.branchName})" to Drive!',
      );
    } catch (e) {
      _showStatus('Push failed: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _pullVersion(VersionState version) async {
    if (version.remoteSettings == null) return;
    setState(() => _loading = true);
    try {
      final path = await _getOrCreateLocalPath(version.key, version.alias);
      await _service.applySettings(
        settings: version.remoteSettings!,
        localBase: _localBase,
        appFilter: version.key,
        alias: version.alias,
        fallbackPath: path,
      );
      await _loadAll();
      _showStatus(
        'Pulled "${version.displayName} (${version.branchName})" & applied to PC!',
      );
    } catch (e) {
      _showStatus('Pull failed: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _checkoutBranch(VersionState version) async {
    if (version.alias == 'active') return;
    if (version.localPath == null) return;

    setState(() => _loading = true);
    try {
      final baseDir = File(version.localPath!).parent.parent;
      final activeFile = File('${baseDir.path}\\user.config');

      final branchFile = File(version.localPath!);
      await branchFile.copy(activeFile.path);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('active_alias_${version.key}', version.alias);
      _activeAliases[version.key] = version.alias;

      _showStatus('Checked out branch "${version.alias}" successfully!');

      _selectedVersionKey = version.key;
      _selectedAlias = 'active';
      _selectedIsRemote = false;

      await _loadAll();
    } catch (e) {
      _showStatus('Checkout failed: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteLocalBranch(VersionState version) async {
    if (version.alias == 'active') return;
    if (version.localPath == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Delete local branch',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Are you sure you want to delete local branch "${version.alias}" for ${version.displayName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    try {
      final file = File(version.localPath!);
      if (file.existsSync()) {
        final parentDir = file.parent;
        if (version.alias != 'active' && parentDir.existsSync()) {
          parentDir.deleteSync(recursive: true);
        } else {
          file.deleteSync();
        }
      }
      _showStatus('Deleted local branch "${version.alias}"!');
      if (_activeAliases[version.key] == version.alias) {
        _activeAliases.remove(version.key);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('active_alias_${version.key}');
      }
      if (_selectedVersionKey == version.key &&
          _selectedAlias == version.alias) {
        _selectedAlias = 'active';
      }
      await _loadAll();
    } catch (e) {
      _showStatus('Failed to delete branch: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteRemoteBranchConfirm(VersionState version) async {
    if (version.remotePath == null) return;

    final isAlias = version.alias != 'active';
    final titleText = isAlias ? 'Delete remote branch' : 'Delete remote config';
    final contentText = isAlias
        ? 'Are you sure you want to delete remote branch "${version.alias}" for ${version.displayName} from Google Drive?'
        : 'Are you sure you want to delete the active remote config for ${version.displayName} from Google Drive?';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          titleText,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(contentText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    try {
      final file = File(version.remotePath!);
      if (file.existsSync()) {
        final parentDir = file.parent;
        if (isAlias && parentDir.existsSync()) {
          parentDir.deleteSync(recursive: true);
        } else {
          file.deleteSync();
          if (parentDir.existsSync() && parentDir.listSync().isEmpty) {
            parentDir.deleteSync();
          }
        }
      }
      _showStatus(
        isAlias
            ? 'Deleted remote branch "${version.alias}"!'
            : 'Deleted remote config!',
      );

      if (_selectedVersionKey == version.key &&
          _selectedAlias == version.alias &&
          _selectedIsRemote == true) {
        _selectedVersionKey = null;
        _selectedAlias = 'active';
      }
      await _loadAll();
    } catch (e) {
      _showStatus('Failed to delete: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteLocalConfigConfirm(VersionState version) async {
    if (version.localPath == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Delete local config',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Are you sure you want to delete the active local config file for ${version.displayName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    try {
      final file = File(version.localPath!);
      if (file.existsSync()) {
        file.deleteSync();
      }
      _showStatus('Deleted local active config!');
      if (_selectedVersionKey == version.key &&
          _selectedAlias == version.alias &&
          _selectedIsRemote == false) {
        _selectedVersionKey = null;
        _selectedAlias = 'active';
      }
      await _loadAll();
    } catch (e) {
      _showStatus('Failed to delete: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _renameAlias(VersionState version) async {
    if (version.alias == 'active') return;
    if (version.localPath == null) return;

    final controller = TextEditingController(text: version.alias);
    final isRemoteActive = version.remoteExists && version.remotePath != null;

    final renameAction = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        String? selectedAction = isRemoteActive ? 'both' : 'local';
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.border),
              ),
              title: const Row(
                children: [
                  Icon(Icons.edit_road_rounded, color: AppTheme.accent),
                  SizedBox(width: 8),
                  Text(
                    'Rename Alias',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter new alias name:',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. 5d2_backup',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      filled: true,
                      fillColor: AppTheme.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.accent),
                      ),
                    ),
                  ),
                  if (isRemoteActive) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Remote Sync Option:',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    RadioListTile<String>(
                      title: const Text(
                        'Rename both Local & Google Drive',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      value: 'both',
                      groupValue: selectedAction,
                      activeColor: AppTheme.accent,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) =>
                          setStateDialog(() => selectedAction = val),
                    ),
                    RadioListTile<String>(
                      title: const Text(
                        'Rename Local only (treat as new local alias)',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      value: 'local',
                      groupValue: selectedAction,
                      activeColor: AppTheme.accent,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) =>
                          setStateDialog(() => selectedAction = val),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, selectedAction),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Confirm',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (renameAction == null) return;

    final newName = controller.text
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    if (newName.isEmpty) {
      _showStatus('Alias name cannot be empty', error: true);
      return;
    }
    if (newName == version.alias) return;

    setState(() => _loading = true);
    try {
      // 1. Rename Local path
      final localFile = File(version.localPath!);
      if (localFile.existsSync()) {
        final parentDir = localFile.parent;
        final baseParent = parentDir.parent;
        final newLocalPath =
            '${baseParent.path}${Platform.pathSeparator}$newName';

        final targetDir = Directory(newLocalPath);
        if (targetDir.existsSync()) {
          throw 'Local branch with name "$newName" already exists!';
        }
        await parentDir.rename(newLocalPath);
      }

      // 2. Rename Remote if requested
      if (isRemoteActive && renameAction == 'both') {
        final driveFile = File(version.remotePath!);
        if (driveFile.existsSync()) {
          final driveParent = driveFile.parent;
          final oldDirName = driveParent.path
              .split(Platform.pathSeparator)
              .last;

          String newDirName;
          if (oldDirName.startsWith('${version.key}_')) {
            newDirName = '${version.key}_$newName';
          } else {
            newDirName = newName;
          }

          final String newRemotePath =
              '${driveParent.parent.path}${Platform.pathSeparator}$newDirName';
          final targetRemoteDir = Directory(newRemotePath);
          if (targetRemoteDir.existsSync()) {
            throw 'Remote folder with name "$newDirName" already exists on Drive!';
          }
          await driveParent.rename(newRemotePath);
        }
      }

      _showStatus(
        'Successfully renamed alias from "${version.alias}" to "$newName"!',
      );

      _selectedVersionKey = version.key;
      _selectedAlias = newName;

      await _loadAll();
    } catch (e) {
      _showStatus('Failed to rename alias: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  List<Widget> _buildRowMenuChildren(VersionState version, bool isRemote) {
    final menuButtonStyle = ButtonStyle(
      foregroundColor: MaterialStateProperty.all(AppTheme.textPrimary),
      backgroundColor: MaterialStateProperty.resolveWith<Color?>((states) {
        if (states.contains(MaterialState.hovered)) {
          return AppTheme.accentSoft.withOpacity(0.3);
        }
        return Colors.transparent;
      }),
      padding: MaterialStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      minimumSize: MaterialStateProperty.all(const Size(180, 40)),
      overlayColor: MaterialStateProperty.all(Colors.transparent),
    );

    if (isRemote) {
      if (version.alias != 'active') {
        return [
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.delete_forever_rounded,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => _deleteRemoteBranchConfirm(version),
            child: const Text(
              'Delete branch from Drive',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ];
      } else {
        return [
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.delete_outline_rounded,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => _deleteRemoteBranchConfirm(version),
            child: const Text(
              'Delete active config from Drive',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ];
      }
    } else {
      if (version.alias != 'active') {
        return [
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.play_circle_outline_rounded,
              color: AppTheme.accent,
              size: 18,
            ),
            onPressed: () => _checkoutBranch(version),
            child: const Text(
              'Make Active (Checkout)',
              style: TextStyle(fontSize: 13),
            ),
          ),
          SubmenuButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.merge_type_rounded,
              color: AppTheme.accent,
              size: 18,
            ),
            alignmentOffset: const Offset(10, 10),
            menuStyle: MenuStyle(
              backgroundColor: MaterialStateProperty.all(AppTheme.surface),
              surfaceTintColor: MaterialStateProperty.all(Colors.transparent),
              shadowColor: MaterialStateProperty.all(
                Colors.black.withOpacity(0.2),
              ),
              elevation: MaterialStateProperty.all(8),
              shape: MaterialStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppTheme.border),
                ),
              ),
            ),
            menuChildren: _buildSyncSourcesMenu(version, menuButtonStyle),
            child: const Text(
              'Sync configuration from...',
              style: TextStyle(fontSize: 13),
            ),
          ),
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.edit_rounded,
              color: Colors.blueAccent,
              size: 18,
            ),
            onPressed: () => _renameAlias(version),
            child: const Text('Rename Alias', style: TextStyle(fontSize: 13)),
          ),
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.delete_rounded,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => _deleteLocalBranch(version),
            child: const Text(
              'Delete branch from local',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ];
      } else {
        return [
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.bookmark_add_outlined,
              color: AppTheme.accent,
              size: 18,
            ),
            onPressed: () => _createBranch(version),
            child: const Text(
              'Create Branch/Alias',
              style: TextStyle(fontSize: 13),
            ),
          ),
          SubmenuButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.merge_type_rounded,
              color: AppTheme.accent,
              size: 18,
            ),
            alignmentOffset: const Offset(10, 10),
            menuStyle: MenuStyle(
              backgroundColor: MaterialStateProperty.all(AppTheme.surface),
              surfaceTintColor: MaterialStateProperty.all(Colors.transparent),
              shadowColor: MaterialStateProperty.all(
                Colors.black.withOpacity(0.2),
              ),
              elevation: MaterialStateProperty.all(8),
              shape: MaterialStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppTheme.border),
                ),
              ),
            ),
            menuChildren: _buildSyncSourcesMenu(version, menuButtonStyle),
            child: const Text(
              'Sync configuration from...',
              style: TextStyle(fontSize: 13),
            ),
          ),
          MenuItemButton(
            style: menuButtonStyle,
            leadingIcon: const Icon(
              Icons.delete_outline_rounded,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => _deleteLocalConfigConfirm(version),
            child: const Text(
              'Delete active config from local',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ];
      }
    }
  }

  List<Widget> _buildSyncSourcesMenu(
    VersionState targetVersion,
    ButtonStyle menuButtonStyle,
  ) {
    final targetSettings =
        targetVersion.localSettings ?? targetVersion.remoteSettings ?? {};
    final targetCount =
        int.tryParse(targetSettings['FileNameNumber'] ?? '0') ?? 0;
    final targetPrefix = targetSettings['FileNamePrefix'] ?? 'IMG';

    // Helper: get clean app name
    String cleanName(String key) {
      if (key == 'EOS_Utility') return 'EOS Utility';
      if (key == 'EOS_Utility_2') return 'EOS Utility 2';
      if (key == 'EOS_Utility_3') return 'EOS Utility 3';
      return key;
    }

    // Helper: build list of detail strings relative to target
    List<String> buildDetails(Map<String, String> sourceSettings) {
      final details = <String>[];
      final sourceCount =
          int.tryParse(sourceSettings['FileNameNumber'] ?? '0') ?? 0;
      final sourcePrefix = sourceSettings['FileNamePrefix'] ?? 'IMG';
      if (sourceCount != targetCount) details.add('Count: $sourceCount');
      if (sourcePrefix != targetPrefix && sourcePrefix != 'IMG') {
        details.add('Prefix: $sourcePrefix');
      }
      for (final custKey in [
        'FileCustomize1',
        'FileCustomize2',
        'FileCustomize3',
      ]) {
        final srcText = _extractCustomText(sourceSettings[custKey]);
        final tgtText = _extractCustomText(targetSettings[custKey]);
        if (srcText.isNotEmpty && srcText != tgtText) {
          details.add(srcText);
          break;
        }
      }
      return details;
    }

    // Build rich menu item widget
    Widget buildItem({
      required String appKey,
      required String alias,
      required bool isLocal,
      required Map<String, String> settings,
      required List<String> details,
      required bool isCurrentlyActive,
      required VoidCallback? onPressed,
    }) {
      return MenuItemButton(
        style: menuButtonStyle,
        onPressed: onPressed,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              isLocal
                  ? Icons.insert_drive_file_outlined
                  : Icons.cloud_queue_rounded,
              size: 16,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        cleanName(appKey),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (alias != 'active') ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 5),
                          child: Text(
                            '|',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentSoft,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: AppTheme.accent.withOpacity(0.25),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            alias,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (isCurrentlyActive) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (details.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        details.join('  ·  '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final items = <Widget>[];
    bool hadAny = false;

    for (final v in _versions) {
      if (v.key == targetVersion.key && v.alias == targetVersion.alias)
        continue;

      final isActiveBranch =
          _activeAliases[v.key] == v.alias ||
          (v.alias == 'active' && _activeAliases[v.key] == null);

      if (v.localExists) {
        hadAny = true;
        final settings = v.localSettings ?? {};
        final details = buildDetails(settings);
        items.add(
          buildItem(
            appKey: v.key,
            alias: v.alias,
            isLocal: true,
            settings: settings,
            details: details,
            isCurrentlyActive: isActiveBranch,
            onPressed: () async {
              setState(() => _loading = true);
              try {
                final path = await _getOrCreateLocalPath(
                  targetVersion.key,
                  targetVersion.alias,
                );
                await _service.applySettings(
                  settings: settings,
                  localBase: _localBase,
                  appFilter: targetVersion.key,
                  alias: targetVersion.alias,
                  fallbackPath: path,
                );
                final lbl = '${cleanName(v.key)} (${v.branchName}) [Local]';
                _showStatus(
                  'Synced from "$lbl" into "${targetVersion.alias}"!',
                );
                await _loadAll();
              } catch (e) {
                _showStatus('Failed to sync config: $e', error: true);
              } finally {
                setState(() => _loading = false);
              }
            },
          ),
        );
      }

      if (v.remoteExists) {
        hadAny = true;
        final settings = v.remoteSettings ?? {};
        final details = buildDetails(settings);
        items.add(
          buildItem(
            appKey: v.key,
            alias: v.alias,
            isLocal: false,
            settings: settings,
            details: details,
            isCurrentlyActive: false,
            onPressed: () async {
              setState(() => _loading = true);
              try {
                final path = await _getOrCreateLocalPath(
                  targetVersion.key,
                  targetVersion.alias,
                );
                await _service.applySettings(
                  settings: settings,
                  localBase: _localBase,
                  appFilter: targetVersion.key,
                  alias: targetVersion.alias,
                  fallbackPath: path,
                );
                final lbl = '${cleanName(v.key)} (${v.branchName}) [Drive]';
                _showStatus(
                  'Synced from "$lbl" into "${targetVersion.alias}"!',
                );
                await _loadAll();
              } catch (e) {
                _showStatus('Failed to sync config: $e', error: true);
              } finally {
                setState(() => _loading = false);
              }
            },
          ),
        );
      }
    }

    if (!hadAny) {
      return [
        MenuItemButton(
          style: menuButtonStyle,
          onPressed: null,
          child: const Text(
            'No other sources available',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontStyle: FontStyle.italic,
              fontSize: 13,
            ),
          ),
        ),
      ];
    }

    return items;
  }

  Future<void> _createBranch(VersionState baseVersion) async {
    final activeSettings = baseVersion.localExists
        ? baseVersion.localSettings
        : baseVersion.remoteSettings;
    if (activeSettings == null) {
      _showStatus('No setting source to create branch from.', error: true);
      return;
    }

    final aliasController = TextEditingController();
    bool createLocal = true;
    bool createRemote = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.border),
              ),
              title: Row(
                children: [
                  const Icon(Icons.alt_route_rounded, color: AppTheme.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Create Branch / Alias',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter new branch name (alias), e.g. "5d2" or "6d":',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: aliasController,
                    autofocus: true,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. 5d2',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixText: '${baseVersion.key}_',
                      prefixStyle: const TextStyle(color: AppTheme.textMuted),
                      filled: true,
                      fillColor: AppTheme.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.accent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Create Options:',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  CheckboxListTile(
                    value: createLocal,
                    title: const Text(
                      'Save Local (as alias config on PC)',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    activeColor: AppTheme.accent,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) =>
                        setStateDialog(() => createLocal = val ?? false),
                  ),
                  CheckboxListTile(
                    value: createRemote,
                    title: const Text(
                      'Save Remote (upload folder on Google Drive)',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    activeColor: AppTheme.accent,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) =>
                        setStateDialog(() => createRemote = val ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Create',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true) return;

    final alias = aliasController.text
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    if (alias.isEmpty) {
      _showStatus('Branch name cannot be empty', error: true);
      return;
    }

    setState(() => _loading = true);
    try {
      if (createLocal) {
        final path = await _getOrCreateLocalPath(baseVersion.key, alias);
        final aliasFile = File(path);

        if (!aliasFile.parent.existsSync()) {
          aliasFile.parent.createSync(recursive: true);
        }

        final xml = _service.buildMinimalXml(activeSettings);
        await aliasFile.writeAsString(xml);
      }

      if (createRemote) {
        final driveFolder = '${baseVersion.key}\\$alias';
        await _service.uploadSettingsToDrive(
          settings: activeSettings,
          driveBase: _driveBase,
          appFilter: driveFolder,
        );
      }

      _showStatus('Created branch "$alias" successfully!');

      _selectedVersionKey = baseVersion.key;
      _selectedAlias = alias;
      _selectedIsRemote = createRemote && !createLocal;

      await _loadAll();
    } catch (e) {
      _showStatus('Failed to create branch: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _showVersionCompareDialog(VersionState version) async {
    if (version.localSettings == null || version.remoteSettings == null) return;

    final local = version.localSettings!;
    final remote = version.remoteSettings!;
    final allKeys = {...local.keys, ...remote.keys};

    final diffs = <VersionDiff>[];
    for (final key in allKeys) {
      final lVal = local[key] ?? '';
      final rVal = remote[key] ?? '';
      if (lVal != rVal) {
        diffs.add(VersionDiff(key: key, localValue: lVal, remoteValue: rVal));
      }
    }

    if (diffs.isEmpty) {
      _showStatus('No differences found between Local and Remote.');
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final allSelected = diffs.every((d) => d.selected);
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.border),
              ),
              title: Row(
                children: [
                  const Icon(
                    Icons.compare_arrows_rounded,
                    color: AppTheme.accent,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Compare & Sync: ${version.displayName} (${version.branchName})',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 720,
                height: 540,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Differences found between your PC and Google Drive. Select the settings you wish to sync.',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: allSelected,
                      title: const Text(
                        'Select All Differences',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      activeColor: AppTheme.accent,
                      checkColor: Colors.white,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (val) => setStateDialog(() {
                        for (final d in diffs) d.selected = val ?? false;
                      }),
                    ),
                    const Divider(color: AppTheme.border, height: 1),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: diffs.length,
                        itemBuilder: (context, index) {
                          final diff = diffs[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Checkbox(
                                  value: diff.selected,
                                  activeColor: AppTheme.accent,
                                  checkColor: Colors.white,
                                  onChanged: (val) => setStateDialog(
                                    () => diff.selected = val ?? false,
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _formatKey(diff.key),
                                        style: const TextStyle(
                                          color: AppTheme.textPrimary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 8,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withOpacity(
                                                  0.06,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: Colors.green
                                                      .withOpacity(0.12),
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                    'PC (Local)',
                                                    style: TextStyle(
                                                      color: Colors.green,
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    ConfigSlot.formatSettingValue(
                                                      diff.key,
                                                      diff.localValue,
                                                    ),
                                                    style: const TextStyle(
                                                      color: AppTheme
                                                          .textSecondary,
                                                      fontSize: 11,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Icon(
                                              Icons.arrow_forward_rounded,
                                              size: 14,
                                              color: AppTheme.textSecondary,
                                            ),
                                          ),
                                          Expanded(
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 8,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.orange
                                                    .withOpacity(0.06),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: Colors.orange
                                                      .withOpacity(0.12),
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                    'Drive (Remote)',
                                                    style: TextStyle(
                                                      color: Colors.orange,
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    ConfigSlot.formatSettingValue(
                                                      diff.key,
                                                      diff.remoteValue,
                                                    ),
                                                    style: const TextStyle(
                                                      color: AppTheme
                                                          .textSecondary,
                                                      fontSize: 11,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: diffs.any((d) => d.selected)
                      ? () => Navigator.pop(ctx, {
                          'action': 'pull',
                          'diffs': diffs,
                        })
                      : null,
                  icon: const Icon(Icons.cloud_download_rounded, size: 16),
                  label: const Text('Pull Selected'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: diffs.any((d) => d.selected)
                      ? () => Navigator.pop(ctx, {
                          'action': 'push',
                          'diffs': diffs,
                        })
                      : null,
                  icon: const Icon(Icons.cloud_upload_rounded, size: 16),
                  label: const Text('Push Selected'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;

    final action = result['action'] as String;
    final selectedDiffs = (result['diffs'] as List<VersionDiff>)
        .where((d) => d.selected)
        .toList();
    if (selectedDiffs.isEmpty) return;

    setState(() => _loading = true);
    try {
      if (action == 'pull') {
        final mergedSettings = Map<String, String>.from(version.localSettings!);
        for (final diff in selectedDiffs) {
          mergedSettings[diff.key] = diff.remoteValue;
        }

        final path = await _getOrCreateLocalPath(version.key);
        await _service.applySettings(
          settings: mergedSettings,
          localBase: _localBase,
          appFilter: version.key,
          fallbackPath: path,
        );
        await _loadAll();
        _showStatus('Successfully merged selected values from Drive to PC!');
      } else if (action == 'push') {
        final mergedSettings = Map<String, String>.from(
          version.remoteSettings!,
        );
        for (final diff in selectedDiffs) {
          mergedSettings[diff.key] = diff.localValue;
        }

        await _service.uploadSettingsToDrive(
          settings: mergedSettings,
          driveBase: _driveBase,
          appFilter: version.key,
        );
        await _loadAll();
        _showStatus('Successfully merged selected values from PC to Drive!');
      }
    } catch (e) {
      _showStatus('Sync failed: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<String> _getOrCreateLocalPath(
    String appFilter, [
    String? alias,
  ]) async {
    final targetAlias = alias ?? 'active';
    final configs = await _service.scanLocalConfigs(_localBase);
    final match = configs.firstWhere(
      (e) =>
          e['appDir']!.split('.exe').first == appFilter &&
          e['alias'] == targetAlias,
      orElse: () => {},
    );
    if (match.isNotEmpty) {
      return match['path']!;
    }

    final baseDir = Directory(_localBase);
    if (baseDir.existsSync()) {
      for (final appDir in baseDir.listSync().whereType<Directory>()) {
        final appName = appDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (appName.split('.exe').first == appFilter) {
          final versionDirs = appDir.listSync().whereType<Directory>().toList();
          if (versionDirs.isNotEmpty) {
            final parentPath = versionDirs.first.path;
            if (targetAlias == 'active') {
              return '$parentPath\\user.config';
            } else {
              return '$parentPath\\$targetAlias\\user.config';
            }
          } else {
            final parentPath = '${appDir.path}\\1.0.0.0';
            if (targetAlias == 'active') {
              return '$parentPath\\user.config';
            } else {
              return '$parentPath\\$targetAlias\\user.config';
            }
          }
        }
      }
    }

    final parentPath = '$_localBase\\${appFilter}.exe_Url_default\\1.0.0.0';
    if (targetAlias == 'active') {
      return '$parentPath\\user.config';
    } else {
      return '$parentPath\\$targetAlias\\user.config';
    }
  }

  Future<void> _openSettings() async {
    final localCtrl = TextEditingController(text: _localBase);
    final driveCtrl = TextEditingController(text: _driveBase);
    bool localAutoPush = _autoPush;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 17),
        ),
        content: SizedBox(
          width: 480,
          child: StatefulBuilder(
            builder: (ctx2, setStateDialog) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Local Canon_INC Path',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: localCtrl,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.folder_open,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () async {
                          final result = await FilePicker.platform
                              .getDirectoryPath(
                                dialogTitle: 'Select Canon_INC folder',
                              );
                          if (result != null) localCtrl.text = result;
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Drive / Cloud Sync Path',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: driveCtrl,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.folder_open,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () async {
                          final result = await FilePicker.platform
                              .getDirectoryPath(
                                dialogTitle: 'Select Drive Sync folder',
                              );
                          if (result != null) driveCtrl.text = result;
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    title: const Text(
                      'Auto push active slot changes to Google Drive',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: const Text(
                      'Automatically upload slot settings when local config files are updated (e.g. shutter count increments)',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    value: localAutoPush,
                    activeColor: AppTheme.accent,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) {
                      setStateDialog(() {
                        localAutoPush = val ?? false;
                      });
                    },
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _service.setLocalBasePath(localCtrl.text.trim());
              await _service.setDriveBasePath(driveCtrl.text.trim());
              await _service.setAutoPush(localAutoPush);
              setState(() {
                _localBase = localCtrl.text.trim();
                _driveBase = driveCtrl.text.trim();
                _autoPush = localAutoPush;
              });
              await _loadAll();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── Fetch & Sync ─────────────────────────────────────────────

  Future<void> _fetchFromDrive() async {
    setState(() => _loading = true);
    try {
      await _loadAll();
      _showStatus('Fetched latest local & remote configurations.');
    } catch (e) {
      _showStatus('Fetch failed: $e', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ── Field builders (inlined from SlotDetailScreen) ───────────

  bool _isBooleanKey(String key) {
    final lower = key.toLowerCase();
    return lower.startsWith('is') ||
        lower.startsWith('notify') ||
        lower.startsWith('launchaction') ||
        (lower.contains('download') && lower.startsWith('subfolder')) ||
        (lower.contains('capture') && lower.startsWith('subfolder')) ||
        (lower.contains('folderwatcher') && lower.startsWith('subfolder')) ||
        key == 'OnlyTransferJpeg' ||
        key == 'SaveCF' ||
        key == 'AutoPowerOFF' ||
        key == 'Rotate' ||
        key == 'MouseWheelInhibit' ||
        key == 'TimeWarning' ||
        key == 'TimeSyncPC' ||
        key == 'TimeNone' ||
        key == 'AutoLaunchQuickPreview' ||
        key == 'LvFitHideControlPanel' ||
        key == 'LvLinkWB';
  }

  bool _hasDropdownOptions(String key) {
    return key == 'FileNameSeparator' ||
        key == 'FolderNameSeparator' ||
        key == 'FileNameFigure' ||
        key == 'FileCustomizeIndex' ||
        key == 'FileCustomizeSelectedIndex2' ||
        key == 'FolderCustomizeIndex' ||
        key == 'FolderCustomizeSelectedIndex2' ||
        key == 'FolderDateOrder' ||
        key == 'FolderDateFormat' ||
        key == 'DownloadSource' ||
        key == 'LvRotateType' ||
        key == 'LvGridLineNum';
  }

  Map<String, String> _getDropdownOptions(String key) {
    switch (key) {
      case 'FileNameSeparator':
      case 'FolderNameSeparator':
        return {'0': 'Underbar (_)', '1': 'Hyphen (-)', '2': 'None'};
      case 'FileNameFigure':
        return {
          '3': '3 Digits',
          '4': '4 Digits',
          '5': '5 Digits',
          '6': '6 Digits',
        };
      case 'FileCustomizeIndex':
      case 'FileCustomizeSelectedIndex2':
        return {
          '0': 'Prefix + Sequential Number',
          '1': 'Prefix + Shooting Date + Sequential Number',
          '2': 'Prefix + Shooting Time + Sequential Number',
          '3': 'Camera Settings',
          '4': 'User Settings',
          '5': 'Custom Rule 1',
          '6': 'Custom Rule 2',
          '7': 'Custom Rule 3',
        };
      case 'FolderCustomizeIndex':
      case 'FolderCustomizeSelectedIndex2':
        return {
          '0': 'Default Folder',
          '1': 'Camera Name',
          '2': 'Shooting Date',
          '5': 'Custom Folder Rule 1',
          '6': 'Custom Folder Rule 2',
        };
      case 'FolderDateOrder':
        return {
          '0': 'Year / Month / Day',
          '1': 'Month / Day / Year',
          '2': 'Day / Month / Year',
        };
      case 'FolderDateFormat':
        return {
          '0': 'YYYYMMDD',
          '1': 'YYYY_MM_DD',
          '2': 'YYMMDD',
          '3': 'YY_MM_DD',
        };
      case 'DownloadSource':
        return {'0': 'All Images', '1': 'Selected Images'};
      case 'LvRotateType':
        return {'0': '0°', '1': '90° right', '2': '180°', '3': '90° left'};
      case 'LvGridLineNum':
        return {'0': 'Grid Off', '1': '3x3 Grid', '2': '5x5 Grid'};
      default:
        return {};
    }
  }

  Widget _buildRowWrapper({required String labelText, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                labelText,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(flex: 5, child: child),
        ],
      ),
    );
  }

  Widget _buildSettingField(String key, String value) {
    final isCustomizeRule =
        (key.startsWith('FileCustomize') &&
            key != 'FileCustomizeIndex' &&
            key != 'FileCustomizeSelectedIndex2') ||
        (key.startsWith('FolderCustomize') &&
            key != 'FolderCustomizeIndex' &&
            key != 'FolderCustomizeSelectedIndex2');
    final isBool = value == 'True' || value == 'False' || _isBooleanKey(key);
    final isFolder = key == 'SaveFolder';
    final isAppPath = key == 'LinkedApp';
    final isDropdown = _hasDropdownOptions(key);

    if (isCustomizeRule) return _buildCustomizeNameBuilder(key, value);
    if (isBool) return _buildCheckboxField(key, value);
    if (isFolder) return _buildFolderPickerField(key, value);
    if (isAppPath) return _buildAppPickerField(key, value);
    if (isDropdown) return _buildDropdownField(key, value);
    return _buildTextField(key, value);
  }

  Widget _buildCustomizeNameBuilder(String key, String value) {
    final segments = _parseSegments(value);
    final segTypes = _segmentTypes[key] ?? List.filled(6, '');
    final tagOptions = {
      '': '(None)',
      'custom': '[Custom Text...]',
      '<18>': '<Shooting Date>',
      '<4>': '<Shooting Year (Last Two Digits)>',
      '<5>': '<Shooting Year>',
      '<6>': '<Shooting Month>',
      '<7>': '<Shooting Day>',
      '<8>': '<Shooting Time>',
      '<9>': '<Download Time>',
      '<10>': '<Folder Number>',
      '<11>': '<Image Number>',
      '<12>': '<Prefix>',
      '<13>': "<Owner's Name>",
      '<14>': '<ISO>',
      '<15>': '<Camera Body No.>',
      '<16>': '<Camera Model>',
      '<17>': '<Sequential Number>',
      '<1>': '<Shooting Date yy/mm/dd>',
      '<2>': '<Shooting Date mm/dd/yy>',
      '<3>': '<Shooting Date dd/mm/yy>',
    };

    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.accentSoft,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.accent.withAlpha(50)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Preview Custom Name:',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ConfigSlot.formatSettingValue(key, value).isEmpty
                      ? '(Empty)'
                      : ConfigSlot.formatSettingValue(key, value),
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...List.generate(6, (index) {
            final selectedType = segTypes[index];
            final segVal = segments[index];
            final controllerKey = '${key}_seg_${index}';
            final controller = _getController(
              controllerKey,
              selectedType == 'custom' ? segVal : '',
            );
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceAlt,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: tagOptions.containsKey(selectedType)
                          ? selectedType
                          : 'custom',
                      dropdownColor: AppTheme.surface,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                      ),
                      items: tagOptions.entries
                          .map(
                            (e) => DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(
                                e.value,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            segTypes[index] = val;
                            segments[index] = val == 'custom'
                                ? controller.text
                                : val;
                            _editedSettings[key] = _reconstructCustomizeValue(
                              segments,
                            );
                            _checkForChanges();
                          });
                        }
                      },
                    ),
                  ),
                  if (selectedType == 'custom') ...[
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: controller,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Custom text...',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                        onChanged: (newVal) {
                          setState(() {
                            segments[index] = newVal;
                            _editedSettings[key] = _reconstructCustomizeValue(
                              segments,
                            );
                            _checkForChanges();
                          });
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCheckboxField(String key, String value) {
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Switch(
          value: value == 'True',
          activeColor: AppTheme.accent,
          onChanged: (val) => setState(() {
            _editedSettings[key] = (val == true) ? 'True' : 'False';
            _checkForChanges();
          }),
        ),
      ),
    );
  }

  Widget _buildFolderPickerField(String key, String value) {
    final controller = _getController(key, value);
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              onChanged: (newVal) {
                _editedSettings[key] = newVal;
                _checkForChanges();
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(
              Icons.folder_open,
              color: AppTheme.accent,
              size: 20,
            ),
            onPressed: () async {
              final result = await FilePicker.platform.getDirectoryPath(
                dialogTitle: 'Select Save Folder',
              );
              if (result != null) {
                setState(() {
                  _editedSettings[key] = result;
                  controller.text = result;
                  _checkForChanges();
                });
              }
            },
            tooltip: 'Browse Folder',
          ),
        ],
      ),
    );
  }

  Widget _buildAppPickerField(String key, String value) {
    final controller = _getController(key, value);
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              onChanged: (newVal) {
                _editedSettings[key] = newVal;
                _checkForChanges();
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(
              Icons.open_in_new,
              color: AppTheme.accent,
              size: 20,
            ),
            onPressed: () async {
              final result = await FilePicker.platform.pickFiles(
                dialogTitle: 'Select Linked Application',
                type: FileType.custom,
                allowedExtensions: ['exe', 'bat', 'cmd', 'lnk'],
              );
              if (result != null && result.files.single.path != null) {
                final path = result.files.single.path!;
                setState(() {
                  _editedSettings[key] = path;
                  controller.text = path;
                  _checkForChanges();
                });
              }
            },
            tooltip: 'Select Executable',
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownField(String key, String value) {
    final options = _getDropdownOptions(key);
    if (!options.containsKey(value)) options[value] = value;
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: DropdownButtonFormField<String>(
        value: value,
        dropdownColor: AppTheme.surface,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        items: options.entries
            .map(
              (e) => DropdownMenuItem<String>(
                value: e.key,
                child: Text(e.value, style: const TextStyle(fontSize: 13)),
              ),
            )
            .toList(),
        onChanged: (val) {
          if (val != null)
            setState(() {
              _editedSettings[key] = val;
              _checkForChanges();
            });
        },
      ),
    );
  }

  Widget _buildTextField(String key, String value) {
    final controller = _getController(key, value);
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        onChanged: (newVal) {
          _editedSettings[key] = newVal;
          _checkForChanges();
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pcName = Platform.localHostname;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          Row(
            children: [
              // ── LEFT SIDE: Version Control panel ───────────────
              Container(
                width: 440,
                color: Colors.transparent,
                child: Column(
                  children: [
                    _buildHeader(pcName),
                    Expanded(child: _buildVcPanel()),
                  ],
                ),
              ),

              // Thin visual divider
              VerticalDivider(
                width: 1,
                color: AppTheme.border.withOpacity(0.5),
              ),

              // ── RIGHT SIDE: Form Editor ───────────────────────
              Expanded(child: _buildRightEditorPanel()),
            ],
          ),

          // Global loading overlay
          if (_loading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: AppTheme.accent),
              ),
            ),
        ],
      ),
    );
  }

  // ── UI Components ──────────────────────────────────────────

  Widget _buildHeader(String pcName) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pcName.toUpperCase(),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const Text(
                  'Canon Sync Manager',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          _buildToolIcon(
            Icons.cloud_download_outlined,
            'Fetch from Drive',
            _fetchFromDrive,
          ),
          const SizedBox(width: 4),
          _buildToolIcon(Icons.settings_outlined, 'Settings', _openSettings),
        ],
      ),
    );
  }

  Widget _buildToolIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        child: IconButton(
          icon: Icon(icon, color: AppTheme.textSecondary, size: 20),
          onPressed: onTap,
          splashRadius: 20,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
        ),
      ),
    );
  }

  Widget _buildVcPanel() {
    final Map<String, List<VersionState>> localGroups = {};
    final Map<String, List<VersionState>> remoteGroups = {};
    for (final pkgKey in ['EOS_Utility', 'EOS_Utility_2', 'EOS_Utility_3']) {
      localGroups[pkgKey] = _versions
          .where((v) => v.key == pkgKey && v.localExists)
          .toList();
      remoteGroups[pkgKey] = _versions
          .where((v) => v.key == pkgKey && v.remoteExists)
          .toList();
    }

    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Panel Header
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.accentSoft.withOpacity(0.3),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: AppTheme.accentSoft,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.account_tree_rounded,
                        color: AppTheme.accent,
                        size: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Version Control System',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Local config folders vs Drive cloud slots',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: 'Scan & Refresh configurations',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () async {
                          setState(() => _loading = true);
                          await _loadAll();
                          setState(() => _loading = false);
                        },
                        borderRadius: BorderRadius.circular(100),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppTheme.border, height: 1),

            // Directory Tree
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                children: [
                  // 1. Local Branch Folder
                  _buildTreeHeader(
                    'Local',
                    Icons.laptop_chromebook_rounded,
                    _localTreeExpanded,
                    () => setState(
                      () => _localTreeExpanded = !_localTreeExpanded,
                    ),
                  ),
                  if (_localTreeExpanded) ...[
                    for (final pkgKey in [
                      'EOS_Utility',
                      'EOS_Utility_2',
                      'EOS_Utility_3',
                    ]) ...[
                      if ((localGroups[pkgKey] ?? []).isNotEmpty) ...[
                        _buildVersionRow(
                          localGroups[pkgKey]!.firstWhere(
                            (v) => v.alias == 'active',
                          ),
                          false,
                          hasAliases: localGroups[pkgKey]!.any(
                            (v) => v.alias != 'active',
                          ),
                          isExpanded: _localSubExpanded[pkgKey] ?? true,
                          onExpandToggle: () => setState(
                            () => _localSubExpanded[pkgKey] =
                                !(_localSubExpanded[pkgKey] ?? true),
                          ),
                        ),
                        if (_localSubExpanded[pkgKey] ?? true)
                          ...localGroups[pkgKey]!
                              .where((v) => v.alias != 'active')
                              .map(
                                (v) => Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: _buildVersionRow(v, false),
                                ),
                              ),
                      ],
                    ],
                    if (_versions.every((v) => !v.localExists))
                      const Padding(
                        padding: EdgeInsets.only(left: 38, top: 8, bottom: 8),
                        child: Text(
                          'No local configurations found',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],

                  const SizedBox(height: 12),

                  // 2. Remote Branch Folder
                  _buildTreeHeader(
                    'Remote (Google Drive)',
                    Icons.cloud_done_outlined,
                    _remoteTreeExpanded,
                    () => setState(
                      () => _remoteTreeExpanded = !_remoteTreeExpanded,
                    ),
                  ),
                  if (_remoteTreeExpanded) ...[
                    for (final pkgKey in [
                      'EOS_Utility',
                      'EOS_Utility_2',
                      'EOS_Utility_3',
                    ]) ...[
                      if ((remoteGroups[pkgKey] ?? []).isNotEmpty) ...[
                        _buildVersionRow(
                          remoteGroups[pkgKey]!.firstWhere(
                            (v) => v.alias == 'active',
                          ),
                          true,
                          hasAliases: remoteGroups[pkgKey]!.any(
                            (v) => v.alias != 'active',
                          ),
                          isExpanded: _remoteSubExpanded[pkgKey] ?? true,
                          onExpandToggle: () => setState(
                            () => _remoteSubExpanded[pkgKey] =
                                !(_remoteSubExpanded[pkgKey] ?? true),
                          ),
                        ),
                        if (_remoteSubExpanded[pkgKey] ?? true)
                          ...remoteGroups[pkgKey]!
                              .where((v) => v.alias != 'active')
                              .map(
                                (v) => Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: _buildVersionRow(v, true),
                                ),
                              ),
                      ],
                    ],
                    if (_versions.every((v) => !v.remoteExists))
                      const Padding(
                        padding: EdgeInsets.only(left: 38, top: 8, bottom: 8),
                        child: Text(
                          'No remote configurations found on Drive',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTreeHeader(
    String title,
    IconData icon,
    bool expanded,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              color: AppTheme.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 4),
            Icon(icon, color: AppTheme.accent, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionRow(
    VersionState version,
    bool isRemote, {
    bool hasAliases = false,
    bool isExpanded = false,
    VoidCallback? onExpandToggle,
  }) {
    final exists = isRemote ? version.remoteExists : version.localExists;
    final isSelected =
        _selectedVersionKey == version.key &&
        _selectedAlias == version.alias &&
        _selectedIsRemote == isRemote;

    final settings = isRemote ? version.remoteSettings : version.localSettings;
    final modTime = isRemote
        ? version.remoteLastModified
        : version.localLastModified;

    String subtitle = 'No config found';
    if (exists && settings != null) {
      final seq = settings['FileNameNumber'] ?? '0';
      final modText = modTime != null
          ? DateFormat('HH:mm dd/MM').format(modTime)
          : 'N/A';
      subtitle = 'Shutter/Seq: $seq | Modified: $modText';
    }

    Widget? actionWidget;
    Widget statusBadge = const SizedBox();

    if (hasAliases) {
      statusBadge = const SizedBox();
      actionWidget = null;
    } else if (!isRemote) {
      final List<Widget> actionButtons = [];

      if (version.localExists && version.remoteExists) {
        if (version.isSynced) {
          statusBadge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Synced',
              style: TextStyle(
                color: Colors.blue,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        } else if (version.isLocalAhead) {
          statusBadge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Local Ahead',
              style: TextStyle(
                color: Colors.green,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
          actionButtons.add(
            Tooltip(
              message: 'Compare & Pick updates',
              child: IconButton(
                icon: const Icon(
                  Icons.compare_arrows_rounded,
                  color: AppTheme.textSecondary,
                  size: 18,
                ),
                onPressed: () => _showVersionCompareDialog(version),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ),
          );
          actionButtons.add(const SizedBox(width: 4));
          actionButtons.add(
            Tooltip(
              message: 'Push all changes to Drive',
              child: IconButton(
                icon: const Icon(
                  Icons.cloud_upload_rounded,
                  color: Colors.green,
                  size: 18,
                ),
                onPressed: () => _pushVersion(version),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ),
          );
        } else if (version.isRemoteAhead) {
          statusBadge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Behind',
              style: TextStyle(
                color: Colors.orange,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
          actionButtons.add(
            Tooltip(
              message: 'Compare & Pick updates',
              child: IconButton(
                icon: const Icon(
                  Icons.compare_arrows_rounded,
                  color: AppTheme.textSecondary,
                  size: 18,
                ),
                onPressed: () => _showVersionCompareDialog(version),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ),
          );
          actionButtons.add(const SizedBox(width: 4));
          actionButtons.add(
            Tooltip(
              message: 'Pull all changes to PC',
              child: IconButton(
                icon: const Icon(
                  Icons.cloud_download_rounded,
                  color: Colors.orange,
                  size: 18,
                ),
                onPressed: () => _pullVersion(version),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ),
          );
        }
      } else if (version.localExists && !version.remoteExists) {
        statusBadge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.purple.withOpacity(0.08),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'Untracked',
            style: TextStyle(
              color: Colors.purple,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        actionButtons.add(
          Tooltip(
            message: 'Push local version to Drive config slot',
            child: IconButton(
              icon: const Icon(
                Icons.cloud_upload_rounded,
                color: Colors.purple,
                size: 18,
              ),
              onPressed: () => _pushVersion(version),
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),
          ),
        );
      }

      if (actionButtons.isNotEmpty) {
        actionWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: actionButtons,
        );
      }
    } else {
      if (!version.localExists) {
        statusBadge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.08),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'Remote Only',
            style: TextStyle(
              color: Colors.red,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        actionWidget = Tooltip(
          message: 'Pull and create local user.config',
          child: IconButton(
            icon: const Icon(
              Icons.cloud_download_rounded,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => _pullVersion(version),
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
          ),
        );
      } else {
        statusBadge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.accentGlow,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'Remote',
            style: TextStyle(
              color: AppTheme.accent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    }

    final rowContent = InkWell(
      onTap: hasAliases
          ? onExpandToggle
          : (exists
                ? () => _selectVersion(version.key, version.alias, isRemote)
                : null),
      child: Container(
        margin: const EdgeInsets.only(left: 20, right: 8, top: 2, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentGlow.withOpacity(0.4)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppTheme.accent.withOpacity(0.3)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isRemote
                  ? Icons.cloud_queue_rounded
                  : Icons.insert_drive_file_outlined,
              color: exists ? AppTheme.textSecondary : AppTheme.textMuted,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        version.alias == 'active'
                            ? version.displayName
                            : version.alias,
                        style: TextStyle(
                          color: exists
                              ? AppTheme.textPrimary
                              : AppTheme.textMuted,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500,
                          fontSize: 13,
                          decoration: exists
                              ? null
                              : TextDecoration.lineThrough,
                        ),
                      ),
                      if (version.alias != 'active' &&
                          _activeAliases[version.key] == version.alias) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: AppTheme.accent.withOpacity(0.25),
                              width: 0.8,
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_rounded,
                                size: 10,
                                color: AppTheme.accent,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'ACTIVE',
                                style: TextStyle(
                                  color: AppTheme.accent,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      statusBadge,
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: exists
                          ? AppTheme.textSecondary
                          : AppTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (actionWidget != null) actionWidget,
            if (hasAliases && onExpandToggle != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                onPressed: onExpandToggle,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ],
          ],
        ),
      ),
    );

    if (hasAliases) {
      return rowContent;
    }

    return MenuAnchor(
      style: MenuStyle(
        alignment: Alignment.topLeft,
        backgroundColor: MaterialStateProperty.all(AppTheme.surface),
        surfaceTintColor: MaterialStateProperty.all(Colors.transparent),
        shadowColor: MaterialStateProperty.all(Colors.black.withOpacity(0.2)),
        elevation: MaterialStateProperty.all(8),
        shape: MaterialStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.border),
          ),
        ),
      ),
      menuChildren: _buildRowMenuChildren(version, isRemote),
      builder: (context, controller, child) {
        return GestureDetector(
          onSecondaryTapDown: (details) {
            controller.open(position: details.localPosition);
          },
          child: rowContent,
        );
      },
    );
  }

  Widget _buildRightEditorPanel() {
    final slot = _selectedSlot;
    if (slot == null) {
      return Container(
        color: AppTheme.bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  color: AppTheme.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    Icons.settings_suggest_rounded,
                    size: 44,
                    color: AppTheme.accent,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'No configuration selected',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Select a configuration slot from the left to edit settings.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final activeGroup = kSettingGroups[_selectedGroupIndex];
    final relevantKeys = activeGroup.keys
        .where((k) => _editedSettings.containsKey(k))
        .toList();

    return Container(
      color: AppTheme.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        slot.name,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Editing: ${activeGroup.title}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hasChanges) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Discard'),
                    onPressed: _discardChanges,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      minimumSize: const Size(0, 36),
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 16),
                    label: const Text('Save'),
                    onPressed: _saveChanges,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      minimumSize: const Size(0, 36),
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Row(
              children: List.generate(kSettingGroups.length, (idx) {
                final group = kSettingGroups[idx];
                final isSelected = idx == _selectedGroupIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(group.title),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _selectedGroupIndex = idx;
                        });
                      }
                    },
                    selectedColor: AppTheme.accentSoft,
                    backgroundColor: Colors.white,
                    labelStyle: TextStyle(
                      color: isSelected
                          ? AppTheme.accent
                          : AppTheme.textSecondary,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      fontSize: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(100),
                      side: BorderSide(
                        color: isSelected ? AppTheme.accent : AppTheme.border,
                        width: 1.5,
                      ),
                    ),
                    showCheckmark: false,
                    elevation: 0,
                    pressElevation: 0,
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _detailLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.accent),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Card(
                      color: Colors.white,
                      elevation: 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                            child: Text(
                              'Configure preferences for ${activeGroup.title.toLowerCase()}',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Divider(color: AppTheme.border, height: 1),
                          Expanded(
                            child: relevantKeys.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No settings configured in this group.',
                                      style: TextStyle(
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  )
                                : SingleChildScrollView(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    child: Column(
                                      children: relevantKeys.map((key) {
                                        final value =
                                            _editedSettings[key] ?? '';
                                        return _buildSettingField(key, value);
                                      }).toList(),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _formatKey(String key) =>
      key.replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}').trim();
}

// ── Toast Overlay ─────────────────────────────────────────────────

class _ToastOverlay extends StatefulWidget {
  final String message;
  final bool isError;

  const _ToastOverlay({required this.message, required this.isError});

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    _ctrl.forward();

    // Begin fade-out 700ms before removal
    Future.delayed(const Duration(milliseconds: 3300), () {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isError = widget.isError;
    final bgColor = isError ? const Color(0xFFFFEDED) : const Color(0xFFE8F5E9);
    final borderColor = isError
        ? const Color(0xFFEF5350)
        : const Color(0xFF43A047);
    final iconColor = isError
        ? const Color(0xFFEF5350)
        : const Color(0xFF43A047);
    final textColor = isError
        ? const Color(0xFFC62828)
        : const Color(0xFF2E7D32);

    return Positioned(
      top: 24,
      left: 0,
      right: 0,
      child: SafeArea(
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 540),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: borderColor.withOpacity(0.5),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: iconColor.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isError
                            ? Icons.error_rounded
                            : Icons.check_circle_rounded,
                        size: 18,
                        color: iconColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── VersionDiff ──────────────────────────────────────────────────

class VersionDiff {
  final String key;
  final String localValue;
  final String remoteValue;
  bool selected;

  VersionDiff({
    required this.key,
    required this.localValue,
    required this.remoteValue,
    this.selected = true,
  });
}
