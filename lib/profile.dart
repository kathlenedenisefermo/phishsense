import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Privacy policy — full inline text ───────────────────────────────────────

const String _kPrivacyPolicyText = '''PhishSense ("we", "our", or "us") is committed to protecting your privacy. This policy explains how we collect, use, and safeguard your information when you use the PhishSense application.

1. Information We Collect
We collect only the message text you voluntarily submit for scanning. We do not access your SMS inbox, contacts, or any other personal data without your explicit action.

2. How We Use Your Information
Submitted message text is sent to our classification server solely to determine whether the message is phishing or safe. We do not store message content on our servers beyond the duration required to process and return the result.

3. Anonymous Data Sharing
If you opt in to "Share Anonymous Data", anonymized message samples may be used to improve our detection model. No personally identifiable information is included. You can opt out at any time in Settings.

4. Spam Folder
Messages you flag or that are automatically classified as phishing may be stored locally on your device in a Spam Folder. This data remains on your device and is not transmitted to our servers.

5. Data Security
We use industry-standard encryption (HTTPS/TLS) for all data transmitted between the app and our servers. Local data is stored securely using your device's sandboxed storage.

6. Third-Party Services
PhishSense uses a classification API hosted on Railway. No data is shared with advertising networks or sold to third parties.

7. Children's Privacy
PhishSense is not directed at children under 13. We do not knowingly collect information from children.

8. Changes to This Policy
We may update this policy from time to time. We will notify you of significant changes through the app.

9. Contact Us
If you have questions about this policy, contact us at support@phishsense.app.''';


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
  String      _avatar     = '👨‍💻';
  DateTime?   _lastUpdate;
  late bool   _spamEnabled;

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

  // ── Helpers ────────────────────────────────────────────────────────────────

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
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        content: Text(body,
            style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF1A7A72))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ── Edit name ──────────────────────────────────────────────────────────────

  void _editName() {
    if (!_canEdit) {
      _toast('You can update your name again in 7 days.');
      return;
    }
    final ctrl = TextEditingController(text: _name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Edit Name',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Enter your name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF1A7A72))),
          ),
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
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── Avatar ─────────────────────────────────────────────────────────────────

  Future<void> _pickImage(ImageSource src) async {
    Navigator.pop(context);
    final p = await ImagePicker().pickImage(source: src, imageQuality: 85);
    if (p != null && mounted) setState(() => _imagePath = p.path);
  }

  void _showAvatarGrid() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => GridView.builder(
        padding: EdgeInsets.fromLTRB(
            16, 10, 16, 20 + MediaQuery.of(ctx).padding.bottom),
        shrinkWrap: true,
        itemCount: _avatars.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
        ),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () {
            setState(() { _avatar = _avatars[i]; _imagePath = null; });
            Navigator.pop(ctx);
          },
          child: CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xFF1A7A72).withOpacity(.12),
            child: Text(_avatars[i], style: const TextStyle(fontSize: 28)),
          ),
        ),
      ),
    );
  }

  void _editAvatar() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE8F5E9),
              child: Icon(Icons.camera_alt_outlined, color: Color(0xFF1A7A72)),
            ),
            title: const Text('Take a Photo'),
            onTap: () => _pickImage(ImageSource.camera),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE8F5E9),
              child: Icon(Icons.photo_library_outlined,
                  color: Color(0xFF1A7A72)),
            ),
            title: const Text('Choose from Gallery'),
            onTap: () => _pickImage(ImageSource.gallery),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE8F5E9),
              child: Icon(Icons.emoji_emotions_outlined,
                  color: Color(0xFF1A7A72)),
            ),
            title: const Text('Choose an Avatar'),
            onTap: () {
              Navigator.pop(ctx);
              _showAvatarGrid();
            },
          ),
          SizedBox(height: 8 + MediaQuery.of(ctx).padding.bottom),
        ],
      ),
    );
  }

  // ── Settings row ───────────────────────────────────────────────────────────

  Widget _settingRow({
    required IconData icon,
    required String   title,
    String?           subtitle,
    required Widget   trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF1A7A72),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFF555555))),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFFF6F4EC),
      child: Stack(
        children: [
          const Positioned.fill(child: _SidebarSoftBackground()),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 40),
              child: Column(
                children: [
                  // ── Avatar ────────────────────────────────────────────────
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundColor:
                            const Color(0xFF1A7A72).withOpacity(.15),
                        backgroundImage: _imagePath != null
                            ? FileImage(File(_imagePath!))
                            : null,
                        child: _imagePath == null
                            ? Text(_avatar,
                                style: const TextStyle(fontSize: 40))
                            : null,
                      ),
                      GestureDetector(
                        onTap: _editAvatar,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: Color(0xFFE0A800),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.edit,
                              size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // ── Name ──────────────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          _name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _editName,
                        child: const Icon(Icons.edit,
                            size: 18, color: Color(0xFF1A7A72)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  // ── Settings label ────────────────────────────────────────
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Settings',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  ),

                  // ── Spam Folder Management toggle ─────────────────────────
                  _settingRow(
                    icon: Icons.folder_special_outlined,
                    title: 'Spam Folder Management',
                    subtitle:
                        'Move detected phishing messages to the spam folder',
                    trailing: Switch(
                      value: _spamEnabled,
                      activeColor: const Color(0xFF1A7A72),
                      onChanged: (v) {
                        setState(() => _spamEnabled = v);
                        widget.onSpamToggled(v);
                      },
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ── Privacy Policy — inline note style ────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: const Color(0xFFDDD8CE), width: 0.8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Icon(Icons.description_outlined,
                                  size: 16, color: Color(0xFF1A7A72)),
                              SizedBox(width: 6),
                              Text('Privacy Policy',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1A7A72))),
                              Spacer(),
                              Text('Last updated: April 2025',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFFAAAAAA))),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Divider(
                              height: 1, color: Color(0xFFE0DDD5)),
                          const SizedBox(height: 10),
                          Text(
                            _kPrivacyPolicyText,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF666666),
                              height: 1.65,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Soft background (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

class _SidebarSoftBackground extends StatelessWidget {
  const _SidebarSoftBackground();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SoftTexturePainter(),
      ),
    );
  }
}

class _SoftTexturePainter extends CustomPainter {
  const _SoftTexturePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final teal = const Color(0xFF1A7A72).withOpacity(0.05);
    final gold = const Color(0xFFE0A800).withOpacity(0.035);

    void blob(Offset c, double r, Color col, double b) =>
        canvas.drawCircle(
          c, r,
          Paint()
            ..color = col
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, b),
        );

    blob(Offset(size.width * 0.15, size.height * 0.22),
        size.width * 0.20, teal, 30);
    blob(Offset(size.width * 0.82, size.height * 0.18),
        size.width * 0.16, gold, 28);
    blob(Offset(size.width * 0.72, size.height * 0.62),
        size.width * 0.24, teal, 36);
    blob(Offset(size.width * 0.28, size.height * 0.82),
        size.width * 0.22, gold, 34);
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}
