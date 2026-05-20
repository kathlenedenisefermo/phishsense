import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Persistence helpers
// ─────────────────────────────────────────────────────────────────────────────

const String kGlobalWallpaperKey = 'chatroom_wallpaper_global';
const String kGlobalThemeKey     = 'chatroom_theme_global';

String _wallpaperKeyFor(String sender) =>
    'chatroom_wallpaper_${sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

String _themeKeyFor(String sender) =>
    'chatroom_theme_${sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

/// Loads the persisted wallpaper + theme for [sender].
/// Falls back to the global setting, then to built-in defaults.
Future<({String wallpaper, String theme})> loadChatroomPrefs(
    String sender) async {
  final p = await SharedPreferences.getInstance();
  final wallpaper = p.getString(_wallpaperKeyFor(sender)) ??
      p.getString(kGlobalWallpaperKey) ??
      'background';
  final theme = p.getString(_themeKeyFor(sender)) ??
      p.getString(kGlobalThemeKey) ??
      'teal';
  return (wallpaper: wallpaper, theme: theme);
}

/// Saves [wallpaper] + [theme] for a single conversation only.
Future<void> saveChatroomPrefsForSender(
    String sender, String wallpaper, String theme) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_wallpaperKeyFor(sender), wallpaper);
  await p.setString(_themeKeyFor(sender), theme);
}

/// Saves [wallpaper] + [theme] as the global default AND overwrites every
/// existing per-conversation key so ALL chats immediately reflect the change.
Future<void> saveChatroomPrefsGlobal(String wallpaper, String theme) async {
  final p = await SharedPreferences.getInstance();

  // Write the global fallback used by new/not-yet-customised conversations.
  await p.setString(kGlobalWallpaperKey, wallpaper);
  await p.setString(kGlobalThemeKey, theme);

  // Overwrite every per-sender key that was already written.
  for (final key in List<String>.from(p.getKeys())) {
    if (key.startsWith('chatroom_wallpaper_') &&
        key != kGlobalWallpaperKey) {
      await p.setString(key, wallpaper);
    }
    if (key.startsWith('chatroom_theme_') && key != kGlobalThemeKey) {
      await p.setString(key, theme);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Customize Chatroom Page
// ─────────────────────────────────────────────────────────────────────────────

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

// ── Wallpaper image options ───────────────────────────────────────────────────
const kWallpaperImages = [
  'background', '10', '11', '12', '13', '14', '15', '16',
  '1', '2', '3', '4', '5', '6', '7', '8',
];

/// Default wallpaper key used by the spam folder conversations.
const kSpamWallpaperDefault = '8';

// ── Wallpaper color options ───────────────────────────────────────────────────
const kWallpapers = [
  _WallpaperOption(key: 'default',  label: 'Default',  color: Color(0xFFF0EDE6), isDefault: true),
  _WallpaperOption(key: 'white',    label: 'White',    color: Colors.white),
  _WallpaperOption(key: 'grey',     label: 'Grey',     color: Color(0xFFE0DDD8)),
  _WallpaperOption(key: 'mint',     label: 'Mint',     color: Color(0xFFD4EDE6)),
  _WallpaperOption(key: 'sky',      label: 'Sky',      color: Color(0xFFD4E8F5)),
  _WallpaperOption(key: 'lavender', label: 'Lavender', color: Color(0xFFEBDFF5)),
  _WallpaperOption(key: 'peach',    label: 'Peach',    color: Color(0xFFFAE3C8)),
  _WallpaperOption(key: 'green',    label: 'Green',    color: Color(0xFFD4EDD4)),
  _WallpaperOption(key: 'pink',     label: 'Pink',     color: Color(0xFFF5D4DC)),
  _WallpaperOption(key: 'steel',    label: 'Steel',    color: Color(0xFFD8DDE5)),
];

// ── Theme (accent) options ────────────────────────────────────────────────────
const kThemes = [
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
  const _ThemeOption({
    required this.key,
    required this.label,
    required this.color,
  });
}

// ─────────────────────────────────────────────────────────────────────────────

class CustomizeChatroomPage extends StatefulWidget {
  final String senderName;
  final void Function(String wallpaperKey, String themeKey)? onApplyToThis;
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
  // ── State ─────────────────────────────────────────────────────────────────

  String _savedWallpaper    = 'background';
  String _savedTheme        = 'teal';
  String _selectedWallpaper = 'background';
  String _selectedTheme     = 'teal';
  bool   _loadingPrefs      = true;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadPersistedPrefs();
  }

  /// Reads SharedPreferences and seeds both the "saved" baseline and the
  /// "selected" (working) values so the UI starts on whatever was last saved.
  Future<void> _loadPersistedPrefs() async {
    final prefs = await loadChatroomPrefs(widget.senderName);
    if (mounted) {
      setState(() {
        _savedWallpaper    = prefs.wallpaper;
        _savedTheme        = prefs.theme;
        _selectedWallpaper = prefs.wallpaper;
        _selectedTheme     = prefs.theme;
        _loadingPrefs      = false;
      });
    }
  }

  // ── Derived helpers ───────────────────────────────────────────────────────

  static const _kGalleryPrefix = 'gallery_file:';

  bool get _hasUnsavedChanges =>
      _selectedWallpaper != _savedWallpaper ||
          _selectedTheme     != _savedTheme;

  Color get _currentThemeColor =>
      kThemes.firstWhere((t) => t.key == _selectedTheme).color;

  bool get _isGalleryWallpaper =>
      _selectedWallpaper.startsWith(_kGalleryPrefix);

  String? get _galleryFilePath => _isGalleryWallpaper
      ? _selectedWallpaper.substring(_kGalleryPrefix.length)
      : null;

  String? get _currentWallpaperAsset =>
      kWallpaperImages.contains(_selectedWallpaper)
          ? 'assets/images/$_selectedWallpaper.png'
          : null;

  Color get _currentWallpaperColor {
    final match = kWallpapers.where((w) => w.key == _selectedWallpaper);
    return match.isNotEmpty ? match.first.color : const Color(0xFFF0EDE6);
  }

  // ── Gallery picker ────────────────────────────────────────────────────────

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    // Copy to app documents so the path stays valid across sessions.
    final docsDir  = await getApplicationDocumentsDirectory();
    final wallDir  = Directory('${docsDir.path}/wallpapers');
    if (!wallDir.existsSync()) wallDir.createSync(recursive: true);
    final fileName = 'wallpaper_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final permanent = await File(picked.path).copy('${wallDir.path}/$fileName');

    if (mounted) {
      setState(() => _selectedWallpaper = '$_kGalleryPrefix${permanent.path}');
    }
  }

  // ── Apply: this conversation ──────────────────────────────────────────────

  Future<void> _applyToThis() async {
    final confirmed = await _showConfirmDialog(
      title: 'Apply to This Conversation',
      message:
      'The wallpaper and theme will be saved for your conversation '
          'with "${widget.senderName}" only. Other conversations are not affected.',
      confirmLabel: 'Apply',
    );
    if (!confirmed || !mounted) return;

    await saveChatroomPrefsForSender(
      widget.senderName,
      _selectedWallpaper,
      _selectedTheme,
    );
    setState(() {
      _savedWallpaper = _selectedWallpaper;
      _savedTheme     = _selectedTheme;
    });
    widget.onApplyToThis?.call(_selectedWallpaper, _selectedTheme);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Apply: all conversations ──────────────────────────────────────────────

  Future<void> _applyToAll() async {
    final confirmed = await _showConfirmDialog(
      title: 'Apply to All Conversations',
      message:
      'This will update the wallpaper and theme for every conversation, '
          'including future ones. You can still customize individual '
          'conversations separately afterwards.',
      confirmLabel: 'Apply to All',
    );
    if (!confirmed || !mounted) return;

    await saveChatroomPrefsGlobal(_selectedWallpaper, _selectedTheme);
    setState(() {
      _savedWallpaper = _selectedWallpaper;
      _savedTheme     = _selectedTheme;
    });
    widget.onApplyToAll?.call(_selectedWallpaper, _selectedTheme);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Confirmation dialog ───────────────────────────────────────────────────

  /// Returns `true` if the user confirmed, `false` if they cancelled.
  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700)),
        content: Text(message,
            style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF555555),
                height: 1.5)),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 12, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(
                    color: Color(0xFF888888),
                    fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _currentThemeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 10),
            ),
            child: Text(confirmLabel,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ── Back / unsaved-changes guard ──────────────────────────────────────────

  Future<bool> _onWillPop() async {
    if (!_hasUnsavedChanges) return true;
    final result = await _showUnsavedDialog();
    return result != null;
  }

  /// Returns:
  ///   null  → Cancel (stay on page)
  ///   false → Discard
  ///   true  → Saved and leave
  Future<bool?> _showUnsavedDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Save changes?',
            style:
            TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        content: const Text('You have unsaved customizations.',
            style: TextStyle(
                fontSize: 15, color: Color(0xFF555555))),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel',
                style: TextStyle(
                    color: Color(0xFF1A7A72),
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Discard',
                style: TextStyle(
                    color: Color(0xFFF2554F),
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () async {
              await saveChatroomPrefsForSender(
                widget.senderName,
                _selectedWallpaper,
                _selectedTheme,
              );
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: Text('Save',
                style: TextStyle(
                    color: _currentThemeColor,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loadingPrefs) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6F4EC),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF1A7A72)),
        ),
      );
    }

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
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 17)),
        ),
        body: Column(children: [
          _buildPreview(),
          _buildInputBar(),
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

  // ── Preview ───────────────────────────────────────────────────────────────

  Widget _buildPreview() {
    final asset = _currentWallpaperAsset;
    return SizedBox(
      height: 450,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_galleryFilePath != null)
            Image.file(File(_galleryFilePath!), fit: BoxFit.cover)
          else if (asset != null)
            Image.asset(asset, fit: BoxFit.cover)
          else
            ColoredBox(color: _currentWallpaperColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _kPreviewMessages.map((msg) {
                final isMe    = msg['sender'] == 'me';
                final label   = msg['label'] as String?;
                final isPhish = label == 'Phishing';

                final bubbleColor = isMe
                    ? _currentThemeColor
                    : isPhish
                    ? const Color(0xFFFFE8E8)
                    : const Color(0xFFD6F0E8);
                final textColor =
                isMe ? Colors.white : Colors.black87;

                return Align(
                  alignment: isMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    constraints: BoxConstraints(
                        maxWidth:
                        MediaQuery.of(context).size.width *
                            0.72),
                    padding:
                    const EdgeInsets.fromLTRB(12, 10, 12, 8),
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
                                color: isMe
                                    ? Colors.white70
                                    : const Color(0xFF999999))),
                        if (label != null) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isPhish
                                  ? const Color(0xFFF2554F)
                                  : const Color(0xFF06C85E),
                              borderRadius:
                              BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isPhish
                                      ? Icons.warning_rounded
                                      : Icons.shield_outlined,
                                  size: 11,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isPhish
                                      ? 'Phishing Detected'
                                      : 'Safe',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                      fontWeight:
                                      FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Input bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      color: const Color(0xFFF6F4EC),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700)),
      ),

      // Import from Gallery
      InkWell(
        onTap: _pickFromGallery,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDE6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isGalleryWallpaper
                      ? _currentThemeColor
                      : const Color(0xFFDDD8CE),
                  width: _isGalleryWallpaper ? 2.5 : 1,
                ),
              ),
              child: _isGalleryWallpaper
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(_galleryFilePath!),
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined,
                      color: Color(0xFF888888), size: 26),
            ),
            const SizedBox(width: 14),
            const Text('Import from Gallery',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),

      // Remove Image — shown only when a gallery image is active
      if (_isGalleryWallpaper)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: GestureDetector(
            onTap: () => setState(() => _selectedWallpaper = 'background'),
            child: const Text(
              'Remove Image',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFFE53935),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        )
      else
        const SizedBox(height: 12),

      // Image designs
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text('Or choose a design:',
            style: TextStyle(
                fontSize: 13, color: Color(0xFF888888))),
      ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.75,
          ),
          itemCount: kWallpaperImages.length,
          itemBuilder: (_, i) {
            final key        = kWallpaperImages[i];
            final isSelected = _selectedWallpaper == key;
            return GestureDetector(
              onTap: () =>
                  setState(() => _selectedWallpaper = key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? _currentThemeColor
                        : Colors.transparent,
                    width: 2.5,
                  ),
                  boxShadow: isSelected
                      ? [
                    BoxShadow(
                      color: _currentThemeColor
                          .withOpacity(.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset('assets/images/$key.png',
                          fit: BoxFit.cover),
                      if (isSelected)
                        Container(
                          color: Colors.black.withOpacity(.25),
                          child: Center(
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: _currentThemeColor,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),

      const SizedBox(height: 8),
    ]);
  }

  // ── Theme section ─────────────────────────────────────────────────────────

  Widget _buildThemeSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text('Chat Theme',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text('Applies to app bar, bubbles, and send button.',
            style: TextStyle(
                fontSize: 13, color: Color(0xFF888888))),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: kThemes.map((opt) {
            final isSelected = _selectedTheme == opt.key;
            return GestureDetector(
              onTap: () =>
                  setState(() => _selectedTheme = opt.key),
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
                        spreadRadius: 1,
                      )
                    ]
                        : [],
                  ),
                  child: isSelected
                      ? const Icon(Icons.check,
                      size: 22, color: Colors.white)
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
        // ── Apply to This Conversation ──────────────────────────────
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
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),

        const SizedBox(height: 12),

        // ── Apply to All Conversations ──────────────────────────────
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton(
            onPressed: _applyToAll,
            style: OutlinedButton.styleFrom(
              foregroundColor: _currentThemeColor,
              side: BorderSide(
                  color: _currentThemeColor, width: 1.5),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Apply to All Conversations',
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
      ]),
    );
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  Color _contrastColor(Color bg) {
    final luminance = bg.computeLuminance();
    return luminance > 0.5
        ? const Color(0xFF333333)
        : Colors.white;
  }
}