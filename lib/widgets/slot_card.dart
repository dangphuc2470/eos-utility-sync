import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/config_slot.dart';
import '../theme/app_theme.dart';

class SlotCard extends StatelessWidget {
  final ConfigSlot slot;
  final bool isActive;
  final VoidCallback onApply;
  final VoidCallback onUpload;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  const SlotCard({
    super.key,
    required this.slot,
    required this.isActive,
    required this.onApply,
    required this.onUpload,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.accentSoft : AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? AppTheme.accent : AppTheme.border,
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  // Active indicator
                  if (isActive) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.accent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'ACTIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      slot.name,
                      style: TextStyle(
                        color: isActive
                            ? AppTheme.textPrimary
                            : AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Context menu
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz,
                        color: AppTheme.textSecondary, size: 20),
                    color: AppTheme.surfaceAlt,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    onSelected: (v) {
                      if (v == 'rename') onRename();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Row(children: [
                          Icon(Icons.edit, size: 16, color: AppTheme.textSecondary),
                          SizedBox(width: 8),
                          Text('Rename', style: TextStyle(color: AppTheme.textPrimary)),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.redAccent)),
                        ]),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Key info chips
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _InfoChip(
                    icon: Icons.tag,
                    label: 'Seq #${slot.fileNameNumber}',
                    highlight: true,
                  ),
                  _InfoChip(
                    icon: Icons.text_fields,
                    label: slot.fileNamePrefix,
                  ),
                  _InfoChip(
                    icon: Icons.folder_outlined,
                    label: _shortenPath(slot.saveFolder),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              const Divider(color: AppTheme.border, height: 1),
              const SizedBox(height: 12),

              // Footer: timestamp + actions
              Row(
                children: [
                  Icon(Icons.access_time,
                      size: 13, color: AppTheme.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    DateFormat('dd/MM/yyyy HH:mm').format(slot.lastModified),
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  // Upload button
                  _ActionButton(
                    icon: Icons.cloud_upload_outlined,
                    label: 'Upload',
                    color: AppTheme.textSecondary,
                    onTap: onUpload,
                  ),
                  const SizedBox(width: 8),
                  // Apply button
                  _ActionButton(
                    icon: Icons.download_done_rounded,
                    label: 'Apply',
                    color: isActive ? AppTheme.textMuted : AppTheme.green,
                    onTap: isActive ? null : onApply,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _shortenPath(String path) {
    if (path.isEmpty) return 'Not set';
    final parts = path.replaceAll('\\', '/').split('/');
    if (parts.length <= 2) return path;
    return '.../${parts[parts.length - 2]}/${parts.last}';
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool highlight;

  const _InfoChip({
    required this.icon,
    required this.label,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.accentGlow : AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight ? AppTheme.accent.withAlpha(80) : AppTheme.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 12,
              color: highlight ? AppTheme.accent : AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: highlight ? AppTheme.accent : AppTheme.textSecondary,
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: onTap == null ? 0.4 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withAlpha(25),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withAlpha(60)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
