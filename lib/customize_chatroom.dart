import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Customize Chatroom Page
// ─────────────────────────────────────────────────────────────────────────────

/// Default preview messages shown in the Customize Chatroom screen.
/// These are always the same regardless of which conversation you're customizing.
const _kPreviewMessages = [
  {
    'sender': 'them',
    'text': 'Your OTP code is 482910. Valid for 5 mins.',
    'time': '10:31 AM',
    'label': 'Safe',
  },
  {
    'sender': 'me',
    'text': 'Thanks! Got it.',
    'time': '10:32 AM',
    'label': null,
  },
  {
    'sender': 'them',
    'text': 'URGENT: Click here to claim your prize now! bit.ly/win999',
    'time': '10:31 AM',
    'label': 'Phishing',
  },
];

// ── Wallpaper options ─────────────────────────────────────────────────────────
const _kWallpapers = [
  _WallpaperOption(key: 'default', label: 'Default', color: Color(0xFFF0EDE6), isDefault: true),
  _WallpaperOption(key: 'white',   label: 'White',   color: Colors.white),
  _WallpaperOption(key: 'grey',    label: 'Grey',    color: Color(0xFFE0DDD8)),
  _WallpaperOption(key: 'mint',    label: 'Mint',    color: Color(0xFFD4EDE6)),
  _WallpaperOption(key: 'sky',     label: 'Sky',     color: Color(0xFFD4E8F5)),
  _WallpaperOption(key: 'lavender',label: 'Lavender',color: Color(0xFFEBDFF5)),
  _WallpaperOption(key: 'peach',   label: 'Peach',   color: Color(0xFFFAE3C8)),
  _WallpaperOption(key: 'green',   label: 'Green',   color: Color(0xFFD4EDD4)),
  _WallpaperOption(key: 'pink',    label: 'Pink',    color: Color(0xFFF5D4DC)),
  _WallpaperOption(key: 'steel',   label: 'Steel',   color: Color(0xFFD8DDE5)),
];

// ── Theme (accent) options ────────────────────────────────────────────────────
const _kThemes = [
  _ThemeOption(key: 'teal',    label: 'Teal',    color: Color(0xFF1A7A72)),
  _ThemeOption(key: 'blue',    label: 'Blue',    color: Color(0xFF2979FF)),
  _ThemeOption(key: 'purple',  label: 'Purple',  color: Color(0xFF7B1FA2)),
  _ThemeOption(key: 'rose',    label: 'Rose',    color: Color(0xFFC62828)),
  _ThemeOption(key: 'forest',  label: 'Forest',  color: Color(0xFF2E7D32)),
  _ThemeOption(key: 'slate',   label: 'Slate',   color: Color(0xFF37474F)),
  _ThemeOption(key: 'ember',   label: 'Ember',   color: Color(0xFFBF360C)),
  _ThemeOption(key: 'indigo',  label: 'Indigo',  color: Color(0xFF283593)),
  _ThemeOption(key: 'emerald', label: 'Emerald', color: Color(0xFF00695C)),
  _ThemeOption(key: 'amber',   label: 'Amber',   color: Color(0xFFE65100)),
  _ThemeOption(key: 'violet',  label: 'Violet',  color: Color(0xFF4527A0)),
  _ThemeOption(key: 'pine',    label: 'Pine',    color: Color(0xFF1B5E20)),
];

@immutable
class _WallpaperOption {
  final String key;
  final String label;
  final Color color;
  final bool isDefault;
  const _WallpaperOption({
    required this.key,
    required this.label,
    required this.color,
    this.isDefault = false,
  });
}

@immutable
class _ThemeOption {
  final String key;
  final String label;
  final Color color;
  const _ThemeOption({required this.key, required this.label, required this.color});
}

// ─────────────────────────────────────────────────────────────────────────────

class CustomizeChatroomPage extends StatefulWidget {
  /// The conversation name / sender this page was opened from.
  /// It's passed for context but the preview is always the default messages.
  final String senderName;

  /// Called when the user taps "Apply to This Conversation".
  final void Function(String wallpaperKey, String themeKey)? onApplyToThis;

  /// Called when the user taps "Apply to All Conversations".
  final void Function(String wallpaperKey, String themeKey)? onApplyToAll;

  const CustomizeChatroomPage({
    super.key,
    required this.senderName,
    this.onApplyToThis,
    this.onApplyToAll,
  });

  @override
  State<CustomizeChatroomPage> createState() => _CustomizeChatroomPageState();
}

class _CustomizeChatroomPageState extends State<CustomizeChatroomPage> {
  // ── Saved (applied) values ──────────────────────────────────────────────
  String _savedWallpaper = 'default';
  String _savedTheme     = 'teal';

  // ── Current (unsaved) selections ────────────────────────────────────────
  String _selectedWallpaper = 'default';
  String _selectedTheme     = 'teal';

  bool get _hasUnsavedChanges =>
      _selectedWallpaper != _savedWallpaper ||
          _selectedTheme != _savedTheme;

  // ── Helpers ─────────────────────────────────────────────────────────────

  Color get _currentThemeColor =>
      _kThemes.firstWhere((t) => t.key == _selectedTheme).color;

  Color get _currentWallpaperColor =>
      _kWallpapers.firstWhere((w) => w.key == _selectedWallpaper).color;

  void _applyToThis() {
    setState(() {
      _savedWallpaper = _selectedWallpaper;
      _savedTheme     = _selectedTheme;
    });
    widget.onApplyToThis?.call(_selectedWallpaper, _selectedTheme);
    Navigator.of(context).pop();
  }

  void _applyToAll() {
    setState(() {
      _savedWallpaper = _selectedWallpaper;
      _savedTheme     = _selectedTheme;
    });
    widget.onApplyToAll?.call(_selectedWallpaper, _selectedTheme);
    Navigator.of(context).pop();
  }

  Future<bool> _onWillPop() async {
    if (!_hasUnsavedChanges) return true;
    final result = await _showUnsavedDialog();
    if (result == null) return false;  // Cancel → stay
    if (result == false) return true;  // Discard → leave without saving
    return true;                       // Save → leave after saving
  }

  /// Returns:
  ///   null  → cancelled (stay on page, keep edits)
  ///   false → disregard (leave without saving)
  ///   true  → saved (leave after saving)
  Future<bool?> _showUnsavedDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Save changes?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        content: const Text('You have unsaved customizations.',
            style: TextStyle(fontSize: 15, color: Color(0xFF555555))),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null), // stay
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF1A7A72), fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false), // discard
            child: const Text('Discard',
                style: TextStyle(color: Color(0xFFF2554F), fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _savedWallpaper = _selectedWallpaper;
                _savedTheme     = _selectedTheme;
              });
              Navigator.of(ctx).pop(true); // saved
            },
            child: Text('Save',
                style: TextStyle(color: _currentThemeColor, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F4EC),
        appBar: AppBar(
          backgroundColor: _currentThemeColor,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final canPop = await _onWillPop();
              if (canPop && context.mounted) Navigator.of(context).pop();
            },
          ),
          title: const Text('Customize Chatroom',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        ),
        body: Column(children: [
          // ── Preview area ──────────────────────────────────────────────
          _buildPreview(),

          // ── Message input bar (static, visual only) ───────────────────
          _buildInputBar(),

          // ── Settings panels ───────────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _buildWallpaperSection(),
                _buildThemeSection(),
                const SizedBox(height: 16),
                _buildApplyButtons(),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  // ── Preview ──────────────────────────────────────────────────────────────

  Widget _buildPreview() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: _currentWallpaperColor,
      padding: const EdgeInsets.fromLTRB(12,120,12,8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _kPreviewMessages.map((msg) {
          final isMe     = msg['sender'] == 'me';
          final label    = msg['label'] as String?;
          final isPhish  = label == 'Phishing';
          final isSafe   = label == 'Safe';

          final bubbleColor = isMe
              ? _currentThemeColor   // only the "me" bubble uses theme color
              : isPhish
              ? const Color(0xFFFFE8E8)   // phishing always red tint
              : const Color(0xFFD6F0E8);  // safe always green tint

          final textColor = isMe ? Colors.white : Colors.black87;

          return Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.72),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: isMe
                    ? const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                )
                    : const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(msg['text'] as String,
                        style: TextStyle(
                            fontSize: 13,
                            color: textColor,
                            height: 1.4)),
                    const SizedBox(height: 4),
                    Text(msg['time'] as String,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                            isMe ? Colors.white70 : const Color(0xFF999999))),
                    if (label != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isPhish
                              ? const Color(0xFFF2554F)
                              : const Color(0xFF06C85E),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            isPhish
                                ? Icons.warning_rounded
                                : Icons.shield_outlined,
                            size: 11,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isPhish ? 'Phishing Detected' : 'Safe',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                        ]),
                      ),
                    ],
                  ]),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Input bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      color: _currentWallpaperColor,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(children: [
        Expanded(
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFDDD8CE)),
            ),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: const Text('Type a message...',
                style: TextStyle(
                    color: Color(0xFFAAAAAA), fontSize: 14)),
          ),
        ),
        const SizedBox(width: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _currentThemeColor,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.send_rounded,
              color: Colors.white, size: 20),
        ),
      ]),
    );
  }

  // ── Wallpaper section ─────────────────────────────────────────────────────

  Widget _buildWallpaperSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
        child: Text('Wallpaper',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),

      // Import from Gallery tile
      InkWell(
        onTap: () {}, // placeholder
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDE6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFDDD8CE)),
              ),
              child: const Icon(Icons.add_photo_alternate_outlined,
                  color: Color(0xFF888888), size: 26),
            ),
            const SizedBox(width: 14),
            const Text('Import from Gallery',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),

      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text('Or choose a color:',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
      ),

      // Color grid
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: _kWallpapers.map((opt) {
            final isSelected = _selectedWallpaper == opt.key;
            return GestureDetector(
              onTap: () => setState(() => _selectedWallpaper = opt.key),
              child: Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: opt.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? _currentThemeColor
                          : const Color(0xFFCCCCCC),
                      width: isSelected ? 2.5 : 1.5,
                    ),
                    boxShadow: isSelected
                        ? [
                      BoxShadow(
                          color: _currentThemeColor.withOpacity(.3),
                          blurRadius: 8)
                    ]
                        : [],
                  ),
                  child: isSelected
                      ? Icon(Icons.check,
                      size: 22,
                      color: opt.isDefault
                          ? const Color(0xFF666666)
                          : _contrastColor(opt.color))
                      : null,
                ),
                const SizedBox(height: 5),
                Text(opt.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: isSelected
                            ? _currentThemeColor
                            : const Color(0xFF888888),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal)),
              ]),
            );
          }).toList(),
        ),
      ),
    ]);
  }

  // ── Theme section ─────────────────────────────────────────────────────────

  Widget _buildThemeSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text('Chat Theme',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text('Applies to app bar, bubbles, and send button.',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: _kThemes.map((opt) {
            final isSelected = _selectedTheme == opt.key;
            return GestureDetector(
              onTap: () => setState(() => _selectedTheme = opt.key),
              child: Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: opt.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? Colors.black38
                          : Colors.transparent,
                      width: isSelected ? 2.5 : 0,
                    ),
                    boxShadow: isSelected
                        ? [
                      BoxShadow(
                          color: opt.color.withOpacity(.4),
                          blurRadius: 10,
                          spreadRadius: 1)
                    ]
                        : [],
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 22, color: Colors.white)
                      : null,
                ),
                const SizedBox(height: 5),
                Text(opt.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: isSelected
                            ? _currentThemeColor
                            : const Color(0xFF888888),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal)),
              ]),
            );
          }).toList(),
        ),
      ),
    ]);
  }

  // ── Apply buttons ─────────────────────────────────────────────────────────

  Widget _buildApplyButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _applyToThis,
            style: ElevatedButton.styleFrom(
              backgroundColor: _currentThemeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text('Apply to This Conversation',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton(
            onPressed: _applyToAll,
            style: OutlinedButton.styleFrom(
              foregroundColor: _currentThemeColor,
              side: BorderSide(color: _currentThemeColor, width: 1.5),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Apply to All Conversations',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
      ]),
    );
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  Color _contrastColor(Color bg) {
    final luminance = bg.computeLuminance();
    return luminance > 0.5 ? const Color(0xFF333333) : Colors.white;
  }
}