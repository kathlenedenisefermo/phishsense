import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Privacy policy ───────────────────────────────────────────────────────────

const String _kPrivacyPolicyText = '''Your privacy matters to us. PhishSense is designed to protect you without collecting unnecessary data.

1. What We Collect
We only analyze the message text you provide.
We do not access your SMS inbox, contacts, location, or personal data.

2. How Your Data Is Used
Messages are securely sent for classification (phishing or safe).
They are not stored after the result is returned.

3. Stored on Your Device
Scan history, spam messages, and reports are saved locally.
This data never leaves your device.

4. Optional Feedback
You may send anonymous feedback to improve detection.
No personal data is included.

5. Spam Folder
Phishing messages may be stored locally in your Spam Folder.

6. Security
All communication uses HTTPS/TLS encryption.

7. No Ads. No Data Selling
We do not sell, rent, or share your data.

8. Children's Privacy
PhishSense is not intended for users under 13.

9. Updates
Policy updates will be shown in the app.''';

// ─── How It Works ─────────────────────────────────────────────────────────────

const String _kHowItWorksText = '''PhishSense helps you identify phishing SMS messages using AI — fast, simple, and secure.

Scan a Message
Tap "Scan Message" and paste any suspicious text.
Adding the sender is optional.
Tap "Scan" to analyse.

Results appear instantly:
• Phishing — red warning
• Safe — green label
Additional tags may explain why it was flagged.

Your Inbox
Messages are grouped by sender into conversations.
Each thread shows the sender, preview, result, and time.

Swipe left to delete. Tap to open.

Spam Folder
When enabled, phishing messages are moved automatically.

Inside Spam:
• Tap to read
• Long-press for options:
  Move to Inbox
  Report Inaccurate Detection
  Delete

Auto-delete can be set to 7, 14, 30 days, or Never.

Move to Inbox
If a message is safe, you can restore it anytime.
Long-press and tap "Move to Inbox".
It will appear immediately.

Reporting
If a result seems wrong, tap "Report Inaccurate Detection" or "Report as Phishing".

The message will show "Verification in Progress" while under review.

Review Result
After review:
• Verified — label corrected
• Rejected — original result confirmed

The message updates automatically and moves to the correct folder immediately.

Settings
Use "Spam Folder Management" in your profile to enable or disable filtering.

Your Privacy
Messages are only used for scanning.
All data stays on your device.''';



class ProfilePage extends StatefulWidget {
  final String name;
  final bool   spamFolderEnabled;
  final void Function(bool) onSpamToggled;

  const ProfilePage({
    super.key,
    required this.name,
    required this.spamFolderEnabled,
    required this.onSpamToggled,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late String _name;
  String?     _imagePath;
  String      _avatar          = '👨‍💻';
  DateTime?   _lastUpdate;
  late bool   _spamEnabled;
  bool        _privacyExpanded = false;
  bool        _howItExpanded   = false;

  final List<String> _avatars = [
    '👨‍💻', '👩‍💻', '👨‍⚕️', '👩‍⚕️',
    '👨‍🏫', '👩‍🏫', '👨‍🍳', '👩‍🍳',
    '👨‍🔬', '👩‍🔬', '👨‍🎨', '👩‍🎨',
    '👨‍🚀', '👩‍🚀', '👨‍✈️', '👩‍✈️',
  ];

  @override
  void initState() {
    super.initState();
    _name        = widget.name;
    _spamEnabled = widget.spamFolderEnabled;
  }

  bool get _canEdit =>
      _lastUpdate == null ||
      DateTime.now().difference(_lastUpdate!) >= const Duration(days: 7);

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1A7A72),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        content: Text(body, style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Confirm')),
        ],
      ),
    );
    return r ?? false;
  }

  void _editName() {
    if (!_canEdit) { _toast('You can update your name again in 7 days.'); return; }
    final ctrl = TextEditingController(text: _name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Edit Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        content: TextField(controller: ctrl,
            decoration: const InputDecoration(hintText: 'Enter your name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
          ElevatedButton(
            onPressed: () async {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) {
                setState(() { _name = v; _lastUpdate = DateTime.now(); });
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('user_name', v);
              }
              if (mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource src) async {
    Navigator.pop(context);
    final p = await ImagePicker().pickImage(source: src, imageQuality: 85);
    if (p != null && mounted) setState(() => _imagePath = p.path);
  }

  void _showAvatarGrid() {
    showModalBottomSheet(
      context: context, useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => GridView.builder(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 20 + MediaQuery.of(ctx).padding.bottom),
        shrinkWrap: true, itemCount: _avatars.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4, mainAxisSpacing: 16, crossAxisSpacing: 16),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () { setState(() { _avatar = _avatars[i]; _imagePath = null; }); Navigator.pop(ctx); },
          child: CircleAvatar(radius: 30,
              backgroundColor: const Color(0xFF1A7A72).withOpacity(.12),
              child: Text(_avatars[i], style: const TextStyle(fontSize: 28)))),
      ),
    );
  }

  void _editAvatar() {
    showModalBottomSheet(
      context: context, useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
        ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.camera_alt_outlined, color: Color(0xFF1A7A72))),
            title: const Text('Take a Photo'),
            onTap: () => _pickImage(ImageSource.camera)),
        ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.photo_library_outlined, color: Color(0xFF1A7A72))),
            title: const Text('Choose from Gallery'),
            onTap: () => _pickImage(ImageSource.gallery)),
        ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.emoji_emotions_outlined, color: Color(0xFF1A7A72))),
            title: const Text('Choose an Avatar'),
            onTap: () { Navigator.pop(ctx); _showAvatarGrid(); }),
        SizedBox(height: 8 + MediaQuery.of(ctx).padding.bottom),
      ]),
    );
  }

  Widget _settingRow({
    required IconData icon, required String title, String? subtitle, required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 42, height: 42,
            decoration: BoxDecoration(color: const Color(0xFF1A7A72), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: Colors.white)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
          ],
        ])),
        const SizedBox(width: 8),
        trailing,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH   = MediaQuery.of(context).size.height;
    final cardBodyH = ((screenH - 260) / 2).clamp(200.0, 420.0);

    return Drawer(
      backgroundColor: const Color(0xFFF6F4EC),
      child: Stack(children: [
        const Positioned.fill(child: _SidebarSoftBackground()),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 0),
              child: Column(children: [
                Stack(alignment: Alignment.bottomRight, children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: const Color(0xFF1A7A72).withOpacity(.15),
                    backgroundImage: _imagePath != null ? FileImage(File(_imagePath!)) : null,
                    child: _imagePath == null ? Text(_avatar, style: const TextStyle(fontSize: 40)) : null,
                  ),
                  GestureDetector(
                    onTap: _editAvatar,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(color: Color(0xFFE0A800), shape: BoxShape.circle),
                      child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: Text(_name, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                  const SizedBox(width: 6),
                  GestureDetector(onTap: _editName,
                      child: const Icon(Icons.edit, size: 18, color: Color(0xFF1A7A72))),
                ]),
                const SizedBox(height: 28),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(alignment: Alignment.centerLeft,
                      child: Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                ),
                _settingRow(
                  icon: Icons.folder_special_outlined,
                  title: 'Spam Folder Management',
                  subtitle: 'Move detected phishing messages to the spam folder',
                  trailing: Switch(
                    value: _spamEnabled, activeColor: const Color(0xFF1A7A72),
                    onChanged: (v) { setState(() => _spamEnabled = v); widget.onSpamToggled(v); },
                  ),
                ),
                const SizedBox(height: 24),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _ExpandableCard(
                  icon: Icons.description_outlined,
                  title: 'Privacy Policy',
                  subtitle: 'Last updated: April 2026',
                  expanded: _privacyExpanded,
                  bodyHeight: cardBodyH,
                  onToggle: () => setState(() {
                    _privacyExpanded = !_privacyExpanded;
                    if (_privacyExpanded) _howItExpanded = false;
                  }),
                  bodyText: _kPrivacyPolicyText,
                ),
                const SizedBox(height: 12),
                _ExpandableCard(
                  icon: Icons.info_outline,
                  title: 'How It Works',
                  expanded: _howItExpanded,
                  bodyHeight: cardBodyH,
                  onToggle: () => setState(() {
                    _howItExpanded = !_howItExpanded;
                    if (_howItExpanded) _privacyExpanded = false;
                  }),
                  bodyText: _kHowItWorksText,
                ),
                const SizedBox(height: 24),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expandable card widget
// ─────────────────────────────────────────────────────────────────────────────

class _ExpandableCard extends StatefulWidget {
  final IconData     icon;
  final String       title;
  final String?      subtitle;
  final bool         expanded;
  final double       bodyHeight;
  final VoidCallback onToggle;
  final String       bodyText;

  const _ExpandableCard({
    required this.icon, required this.title, this.subtitle,
    required this.expanded, required this.bodyHeight,
    required this.onToggle, required this.bodyText,
  });

  @override
  State<_ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<_ExpandableCard> {
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDDD8CE), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(widget.icon, size: 16, color: const Color(0xFF1A7A72)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A7A72))),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(widget.subtitle!,
                            style: const TextStyle(
                                fontSize: 10.5, color: Color(0xFFAAAAAA))),
                      ],
                    ],
                  ),
                ),
                Icon(
                  widget.expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: const Color(0xFF1A7A72),
                ),
              ]),
            ),
          ),
          if (widget.expanded) ...[
            const Divider(height: 1, color: Color(0xFFE0DDD5)),
            SizedBox(
              height: widget.bodyHeight,
              child: RawScrollbar(
                controller: _scrollCtrl,
                thumbVisibility: true,
                trackVisibility: true,
                thumbColor: const Color(0xFF1A7A72).withOpacity(.55),
                trackColor: const Color(0xFF1A7A72).withOpacity(.08),
                trackBorderColor: Colors.transparent,
                thickness: 5,
                radius: const Radius.circular(8),
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 12, 26, 16),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                        height: 1.65,
                      ),
                      children: _buildStyledSpans(widget.bodyText),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── TEXT STYLING ──────────────────────────────────────────────────────────

  // Single flat set — no duplicates, no spread conflicts.
  static const _sectionTitles = <String>{
    // Privacy Policy numbered + titled headings
    '1. What We Collect',
    '2. How Your Data Is Used',
    '3. Stored on Your Device',
    '4. Optional Feedback',
    '5. Spam Folder',
    '6. Security',
    '7. No Ads. No Data Selling',
    "8. Children's Privacy",
    '9. Updates',
    // How It Works titles
    'Scan a Message',
    'Your Inbox',
    'Spam Folder',
    'Move to Inbox',
    'Reporting',
    'Review Result',
    'Settings',
    'Your Privacy',
  };

  List<TextSpan> _buildStyledSpans(String text) {
    final lines = text.split('\n');
    return List.generate(lines.length, (i) {
      final line    = lines[i];
      final trimmed = line.trim();

      // A line is a section title only when:
      //  1. It matches a known title
      //  2. It is not indented (rules out list-item occurrences)
      //  3. It is preceded by a blank line (rules out mid-paragraph matches)
      final bool isSectionTitle = _sectionTitles.contains(trimmed) &&
          !line.startsWith(' ') &&
          !line.startsWith('\t') &&
          _precededByBlankLine(lines, i);

      return TextSpan(
        text: '$line\n',
        style: isSectionTitle
            ? const TextStyle(
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
                decorationColor: Color(0xFF1A7A72),
                decorationThickness: 1.2,
                color: Color(0xFF1A7A72),
              )
            : null,
      );
    });
  }

  bool _precededByBlankLine(List<String> lines, int i) {
    if (i == 0) return true;
    for (int j = i - 1; j >= 0; j--) {
      if (lines[j].trim().isEmpty) return true;
      return false;
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Soft background
// ─────────────────────────────────────────────────────────────────────────────

class _SidebarSoftBackground extends StatelessWidget {
  const _SidebarSoftBackground();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: _SoftTexturePainter()),
    );
  }
}

class _SoftTexturePainter extends CustomPainter {
  const _SoftTexturePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final teal = const Color(0xFF1A7A72).withOpacity(0.05);
    final gold = const Color(0xFFE0A800).withOpacity(0.035);
    void blob(Offset c, double r, Color col, double b) => canvas.drawCircle(c, r,
        Paint()..color = col..maskFilter = MaskFilter.blur(BlurStyle.normal, b));
    blob(Offset(size.width * 0.15, size.height * 0.22), size.width * 0.20, teal, 30);
    blob(Offset(size.width * 0.82, size.height * 0.18), size.width * 0.16, gold, 28);
    blob(Offset(size.width * 0.72, size.height * 0.62), size.width * 0.24, teal, 36);
    blob(Offset(size.width * 0.28, size.height * 0.82), size.width * 0.22, gold, 34);
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}
