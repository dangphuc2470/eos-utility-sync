import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/config_slot.dart';
import '../services/config_service.dart';
import '../theme/app_theme.dart';

class SlotDetailScreen extends StatefulWidget {
  final ConfigSlot slot;

  const SlotDetailScreen({super.key, required this.slot});

  @override
  State<SlotDetailScreen> createState() => _SlotDetailScreenState();
}

class _SlotDetailScreenState extends State<SlotDetailScreen> {
  final _service = ConfigService();
  
  int _selectedGroupIndex = 0;
  Map<String, String> _editedSettings = {};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, List<String>> _segmentTypes = {};
  
  List<ConfigSlot> _allSlots = [];
  String _localBase = ConfigService.defaultLocalBase;
  bool _hasChanges = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadSlotData();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSlotData() async {
    setState(() => _loading = true);
    _editedSettings = Map<String, String>.from(widget.slot.settings);
    _initSegmentTypes();
    _allSlots = await _service.loadSlots();
    _localBase = await _service.getLocalBasePath();
    setState(() => _loading = false);
  }

  void _initSegmentTypes() {
    _segmentTypes.clear();
    for (final key in _editedSettings.keys) {
      if ((key.startsWith('FileCustomize') && key != 'FileCustomizeIndex' && key != 'FileCustomizeSelectedIndex2') ||
          (key.startsWith('FolderCustomize') && key != 'FolderCustomizeIndex' && key != 'FolderCustomizeSelectedIndex2')) {
        final val = _editedSettings[key] ?? '';
        final segments = parseSegments(val);
        _segmentTypes[key] = List.generate(6, (i) {
          final seg = segments[i];
          if (seg.isEmpty) return '';
          if (seg.startsWith('<') && seg.endsWith('>')) return seg;
          return 'custom';
        });
      }
    }
  }

  List<String> parseSegments(String value) {
    final list = value.split('|');
    while (list.length < 6) {
      list.add('');
    }
    return list.take(6).toList();
  }

  String reconstructCustomizeValue(List<String> segments) {
    return '${segments.join('|')}|';
  }

  void _checkForChanges() {
    bool changes = false;
    for (final k in widget.slot.settings.keys) {
      if (_editedSettings[k] != widget.slot.settings[k]) {
        changes = true;
        break;
      }
    }
    if (_editedSettings.length != widget.slot.settings.length) {
      changes = true;
    }
    setState(() {
      _hasChanges = changes;
    });
  }

  TextEditingController _getController(String key, String initialValue) {
    if (!_controllers.containsKey(key)) {
      _controllers[key] = TextEditingController(text: initialValue);
    }
    return _controllers[key]!;
  }

  void _discardChanges() {
    setState(() {
      _editedSettings = Map<String, String>.from(widget.slot.settings);
      _initSegmentTypes();
      _controllers.forEach((k, ctrl) {
        if (_editedSettings.containsKey(k)) {
          ctrl.text = _editedSettings[k]!;
        }
        if (k.contains('_seg_')) {
          final parts = k.split('_seg_');
          final key = parts[0];
          final idx = int.tryParse(parts[1]) ?? 0;
          final originalSegments = parseSegments(widget.slot.settings[key] ?? '');
          final origVal = originalSegments[idx];
          final origIsTag = origVal.startsWith('<') && origVal.endsWith('>');
          ctrl.text = origIsTag ? '' : origVal;
        }
      });
      _checkForChanges();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Changes discarded.'),
        backgroundColor: AppTheme.textSecondary,
      ),
    );
  }

  Future<void> _saveChanges() async {
    setState(() => _loading = true);
    
    // Update the slot object in memory
    widget.slot.settings = Map<String, String>.from(_editedSettings);
    widget.slot.lastModified = DateTime.now();

    final idx = _allSlots.indexWhere((s) => s.id == widget.slot.id);
    if (idx != -1) {
      _allSlots[idx] = widget.slot;
    } else {
      _allSlots.add(widget.slot);
    }

    // Save slots
    await _service.saveSlots(_allSlots);

    // Apply immediate sync to PC if this is the active slot
    final activeId = await _service.getActiveSlotId();
    if (activeId == widget.slot.id) {
      final path = widget.slot.sourcePath;
      String selectedApp = 'EOS_Utility_3';
      if (path != null) {
        if (path.contains('EOS_Utility_3')) {
          selectedApp = 'EOS_Utility_3';
        } else if (path.contains('EOS_Utility_2')) selectedApp = 'EOS_Utility_2';
        else if (path.contains('EOS_Utility')) selectedApp = 'EOS_Utility';
      }
      
      await _service.applySlot(
        slot: widget.slot,
        localBase: _localBase,
        appFilter: selectedApp,
      );
    }

    setState(() {
      _hasChanges = false;
      _loading = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved & synced successfully!'),
          backgroundColor: AppTheme.accent,
        ),
      );
    }
  }

  Future<void> _pickFolder(String key) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Save Folder',
    );
    if (result != null) {
      setState(() {
        _editedSettings[key] = result;
        _controllers[key]?.text = result;
        _checkForChanges();
      });
    }
  }

  Future<void> _pickApp(String key) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select Linked Application',
      type: FileType.custom,
      allowedExtensions: ['exe', 'bat', 'cmd', 'lnk'],
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      setState(() {
        _editedSettings[key] = path;
        _controllers[key]?.text = path;
        _checkForChanges();
      });
    }
  }

  // ── Field rendering ─────────────────────────────────────────

  bool _isBooleanKey(String key) {
    final lower = key.toLowerCase();
    return lower.startsWith('is') || 
           lower.startsWith('notify') || 
           lower.startsWith('launchaction') || 
           lower.contains('download') && lower.startsWith('subfolder') || 
           lower.contains('capture') && lower.startsWith('subfolder') ||
           lower.contains('folderwatcher') && lower.startsWith('subfolder') ||
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
        return {
          '0': 'Underbar (_)',
          '1': 'Hyphen (-)',
          '2': 'None',
        };
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
        return {
          '0': 'All Images',
          '1': 'Selected Images',
        };
      case 'LvRotateType':
        return {
          '0': '0°',
          '1': '90° right',
          '2': '180°',
          '3': '90° left',
        };
      case 'LvGridLineNum':
        return {
          '0': 'Grid Off',
          '1': '3x3 Grid',
          '2': '5x5 Grid',
        };
      default:
        return {};
    }
  }

  Widget _buildRowWrapper({
    required String labelText,
    required Widget child,
  }) {
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
          Expanded(
            flex: 5,
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingField(String key, String value) {
    final isCustomizeRule = (key.startsWith('FileCustomize') && key != 'FileCustomizeIndex' && key != 'FileCustomizeSelectedIndex2') ||
                            (key.startsWith('FolderCustomize') && key != 'FolderCustomizeIndex' && key != 'FolderCustomizeSelectedIndex2');
    final isBool = value == 'True' || value == 'False' || _isBooleanKey(key);
    final isFolder = key == 'SaveFolder';
    final isAppPath = key == 'LinkedApp';
    final isDropdown = _hasDropdownOptions(key);

    if (isCustomizeRule) {
      return _buildCustomizeNameBuilder(key, value);
    } else if (isBool) {
      return _buildCheckboxField(key, value);
    } else if (isFolder) {
      return _buildFolderPickerField(key, value);
    } else if (isAppPath) {
      return _buildAppPickerField(key, value);
    } else if (isDropdown) {
      return _buildDropdownField(key, value);
    } else {
      return _buildTextField(key, value);
    }
  }

  Widget _buildCustomizeNameBuilder(String key, String value) {
    final segments = parseSegments(value);
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
      '<13>': '<Owner\'s Name>',
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
          // Live Preview Box
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
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w500),
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
          // List of 6 Custom Slots
          ...List.generate(6, (index) {
            final selectedType = segTypes[index];
            final segVal = segments[index];

            final controllerKey = '${key}_seg_$index';
            final controller = _getController(controllerKey, selectedType == 'custom' ? segVal : '');

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
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      initialValue: tagOptions.containsKey(selectedType) ? selectedType : 'custom',
                      dropdownColor: AppTheme.surface,
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      items: tagOptions.entries.map((e) {
                        return DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(e.value, style: const TextStyle(fontSize: 12)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            segTypes[index] = val;
                            if (val == 'custom') {
                              segments[index] = controller.text;
                            } else {
                              segments[index] = val;
                            }
                            _editedSettings[key] = reconstructCustomizeValue(segments);
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
                        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: 'Custom text...',
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        ),
                        onChanged: (newVal) {
                          setState(() {
                            segments[index] = newVal;
                            _editedSettings[key] = reconstructCustomizeValue(segments);
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
    final isTrue = value == 'True';
    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Checkbox(
          value: isTrue,
          activeColor: AppTheme.accent,
          checkColor: Colors.white,
          onChanged: (val) {
            setState(() {
              _editedSettings[key] = (val == true) ? 'True' : 'False';
              _checkForChanges();
            });
          },
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
            icon: const Icon(Icons.folder_open, color: AppTheme.accent, size: 20),
            onPressed: () => _pickFolder(key),
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
            icon: const Icon(Icons.open_in_new, color: AppTheme.accent, size: 20),
            onPressed: () => _pickApp(key),
            tooltip: 'Select Executable',
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownField(String key, String value) {
    final options = _getDropdownOptions(key);
    if (!options.containsKey(value)) {
      options[value] = value;
    }

    return _buildRowWrapper(
      labelText: _formatKey(key),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        dropdownColor: AppTheme.surface,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        items: options.entries.map((e) {
          return DropdownMenuItem<String>(
            value: e.key,
            child: Text(e.value, style: const TextStyle(fontSize: 13)),
          );
        }).toList(),
        onChanged: (val) {
          if (val != null) {
            setState(() {
              _editedSettings[key] = val;
              _checkForChanges();
            });
          }
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

  String _formatKey(String key) {
    return key
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final activeGroup = kSettingGroups[_selectedGroupIndex];
    final relevantKeys = activeGroup.keys
        .where((k) => _editedSettings.containsKey(k))
        .toList();

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(widget.slot.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_hasChanges) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Discard'),
              onPressed: _discardChanges,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                side: const BorderSide(color: AppTheme.border),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.check_rounded, size: 16),
              label: const Text('Save Changes'),
              onPressed: _saveChanges,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ],
      ),
      body: Row(
        children: [
          // Sidebar (Left panel navigation)
          Container(
            width: 240,
            decoration: const BoxDecoration(
              color: AppTheme.surfaceAlt,
              border: Border(right: BorderSide(color: AppTheme.border, width: 1)),
            ),
            child: ListView.builder(
              itemCount: kSettingGroups.length,
              itemBuilder: (context, idx) {
                final group = kSettingGroups[idx];
                final isSelected = idx == _selectedGroupIndex;
                return InkWell(
                  onTap: () => setState(() => _selectedGroupIndex = idx),
                  child: Container(
                    color: isSelected ? AppTheme.accentGlow.withAlpha(150) : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Icon(group.icon, size: 18, color: isSelected ? AppTheme.accent : AppTheme.textSecondary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            group.title,
                            style: TextStyle(
                              color: isSelected ? AppTheme.accent : AppTheme.textSecondary,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          
          // Form (Right panel editor)
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
                : Container(
                    color: AppTheme.surface,
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Group title header
                        Text(
                          activeGroup.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accent,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Configure preferences for ${activeGroup.title.toLowerCase()}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Divider(color: AppTheme.border, height: 1),
                        const SizedBox(height: 16),
                        
                        // Scrollable fields form list
                        Expanded(
                          child: relevantKeys.isEmpty
                              ? const Center(
                                  child: Text(
                                    'No settings configured in this group.',
                                    style: TextStyle(color: AppTheme.textMuted),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: relevantKeys.length,
                                  itemBuilder: (context, fIdx) {
                                    final key = relevantKeys[fIdx];
                                    final value = _editedSettings[key] ?? '';
                                    return _buildSettingField(key, value);
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
