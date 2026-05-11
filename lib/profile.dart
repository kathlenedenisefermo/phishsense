import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── How It Works steps (Android — real-time) ─────────────────────────────────

const List<Map<String, String>> _kHowItWorksAndroid = [
  {
    'title': 'Manual Scanning',
    'body': 'PhishSense analyzes messages manually scanned by the user.',
    'emoji': '📨',
  },
  {
    'title': 'On-Device AI Analysis',
    'body': 'A lightweight ML model runs entirely on your device to detect phishing patterns — no data is sent to the cloud.',
    'emoji': '🤖',
  },
  {
    'title': 'Phishing Alert',
    'body': 'If a message is flagged as phishing, you receive an instant notification.',
    'emoji': '🚨',
  },
  {
    'title': 'Spam Management',
    'body': 'Flagged messages can be automatically moved to your Spam Folder for easy review.',
    'emoji': '📁',
  },
];

// ─── How It Works steps (iOS — manual scanning) ───────────────────────────────

const List<Map<String, String>> _kHowItWorksIOS = [
  {
    'title': 'Open a Message',
    'body': 'Copy any suspicious SMS you received and paste it into the Scan tab.',
    'emoji': '📋',
  },
  {
    'title': 'On-Device AI Analysis',
    'body': 'The same ML model used on Android runs entirely on your device to detect phishing patterns — no data is sent to the cloud.',
    'emoji': '🤖',
  },
  {
    'title': 'Instant Result',
    'body': 'PhishSense tells you whether the message is phishing or safe right away.',
    'emoji': '✅',
  },
  {
    'title': 'Spam Management',
    'body': 'Flagged messages can be saved to your Spam Folder for easy review anytime.',
    'emoji': '📁',
  },
];

// ─────────────────────────────────────────────────────────────────────────────

class ProfilePage extends StatefulWidget {
  final String name;
  final bool spamFolderEnabled;
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
  String? _imagePath;
  String _avatar = '👨‍💻';
  DateTime? _lastUpdate;
  late bool _spamEnabled;
  bool _notifEnabled = true;
  bool _howItExpanded = false;
  bool _reportsExpanded = false;

  // Safe platform check — avoids crash on web
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  final List<String> _avatars = [
    '👨‍💻', '👩‍💻', '👨‍⚕️', '👩‍⚕️',
    '👨‍🏫', '👩‍🏫', '👨‍🍳', '👩‍🍳',
    '👨‍🔬', '👩‍🔬', '👨‍🎨', '👩‍🎨',
    '👨‍🚀', '👩‍🚀', '👨‍✈️', '👩‍✈️',
  ];

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    _spamEnabled = widget.spamFolderEnabled;
  }

  bool get _canEdit =>
      _lastUpdate == null ||
          DateTime.now().difference(_lastUpdate!) >= const Duration(days: 7);

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1A7A72),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

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
            decoration: const InputDecoration(hintText: 'Enter your name')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF1A7A72)))),
          ElevatedButton(
            onPressed: () async {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) {
                setState(() {
                  _name = v;
                  _lastUpdate = DateTime.now();
                });
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('user_name', v);
              }
              if (mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A7A72),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Save'),
          ),
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
            crossAxisCount: 4, mainAxisSpacing: 16, crossAxisSpacing: 16),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () {
            setState(() {
              _avatar = _avatars[i];
              _imagePath = null;
            });
            Navigator.pop(ctx);
          },
          child: CircleAvatar(
              radius: 30,
              backgroundColor: const Color(0xFF1A7A72).withOpacity(.12),
              child: Text(_avatars[i],
                  style: const TextStyle(fontSize: 28))),
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
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2))),
        ListTile(
            leading: const CircleAvatar(
                backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.camera_alt_outlined,
                    color: Color(0xFF1A7A72))),
            title: const Text('Take a Photo'),
            onTap: () => _pickImage(ImageSource.camera)),
        ListTile(
            leading: const CircleAvatar(
                backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.photo_library_outlined,
                    color: Color(0xFF1A7A72))),
            title: const Text('Choose from Gallery'),
            onTap: () => _pickImage(ImageSource.gallery)),
        ListTile(
            leading: const CircleAvatar(
                backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.emoji_emotions_outlined,
                    color: Color(0xFF1A7A72))),
            title: const Text('Choose an Avatar'),
            onTap: () {
              Navigator.pop(ctx);
              _showAvatarGrid();
            }),
        SizedBox(height: 8 + MediaQuery.of(ctx).padding.bottom),
      ]),
    );
  }

  // ── Setting row ──────────────────────────────────────────────────────────────

  Widget _settingRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: const Color(0xFF1A7A72),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: Colors.white)),
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
              ]),
        ),
        const SizedBox(width: 8),
        trailing,
      ]),
    );
  }

  // ── Privacy Policy dialog ─────────────────────────────────────────────────────

  void _showPrivacyPolicy() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFFF0F4F4),
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding:
        const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title
              const Text(
                'Privacy Policy',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A7A72)),
              ),
              const SizedBox(height: 6),
              const Text(
                'PhishSense is built to protect you — not to collect your data.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333)),
              ),
              const SizedBox(height: 4),
              const Text(
                "Here's exactly what happens with your information.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
              const SizedBox(height: 16),

              // Scrollable content
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.52,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Permissions ──────────────────────────────────────
                      _privacyHeading('Permissions We Request'),
                      const SizedBox(height: 6),
                      _permissionRow(Icons.sms_outlined, 'SMS',
                          'Scans incoming messages on your device to detect phishing threats.'),
                      const SizedBox(height: 6),
                      _permissionRow(Icons.contacts_outlined, 'Contacts',
                          'Identifies messages from known contacts for better context.'),
                      const SizedBox(height: 6),
                      _permissionRow(Icons.notifications_outlined, 'Notifications',
                          'Alerts you when a suspicious message is detected.'),
                      const SizedBox(height: 14),

                      // ── On-device scanning ───────────────────────────────
                      _privacySection(
                        icon: Icons.phone_android_outlined,
                        heading: 'All Scanning Stays on Your Device',
                        body: 'PhishSense does not collect, store, or transmit your SMS messages.\n\n'
                            'Every message is scanned locally using an on-device AI model — your conversations never leave your phone.',
                      ),
                      const SizedBox(height: 14),

                      // ── What gets sent ───────────────────────────────────
                      _privacyHeading('What Gets Sent to Our Servers'),
                      const SizedBox(height: 6),
                      _privacyText(
                          'The only data ever sent is feedback you choose to submit by tapping "Report as inaccurate."'),
                      const SizedBox(height: 6),
                      _privacyText('This includes:'),
                      _privacyBullet('The reported message text'),
                      _privacyBullet('The original detection result (phishing or safe)'),
                      _privacyBullet('Your correction and the reason you selected'),
                      const SizedBox(height: 6),
                      _privacyText(
                          'This feedback is voluntary, used only to improve detection accuracy, and is never linked to your identity, phone number, or personal information.'),
                      const SizedBox(height: 14),

                      // ── Your control ─────────────────────────────────────
                      _privacyHeading('Your Control'),
                      const SizedBox(height: 6),
                      _privacyBullet('Manage or revoke any permission at any time through your device settings.'),
                      _privacyBullet('Feedback reports are entirely optional — you are never required to submit one.'),
                      const SizedBox(height: 16),

                      const Text('Thank you for using PhishSense.',
                          style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF1A7A72),
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Close button
              SizedBox(
                width: 160,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A7A72),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30))),
                  child: const Text('Close',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _privacyHeading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF333333))),
  );

  Widget _permissionRow(IconData icon, String name, String desc) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
            color: const Color(0xFF1A7A72).withOpacity(.1),
            borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 15, color: const Color(0xFF1A7A72)),
      ),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF333333))),
        Text(desc, style: const TextStyle(fontSize: 12, color: Color(0xFF666666), height: 1.4)),
      ])),
    ]),
  );

  Widget _privacySection({required IconData icon, required String heading, required String body}) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A7A72).withOpacity(.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF1A7A72).withOpacity(.15)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: const Color(0xFF1A7A72)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(heading, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF1A7A72))),
            const SizedBox(height: 4),
            Text(body, style: const TextStyle(fontSize: 12, color: Color(0xFF555555), height: 1.5)),
          ])),
        ]),
      );

  Widget _privacyText(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text,
        style: const TextStyle(
            fontSize: 12.5, color: Color(0xFF555555), height: 1.6)),
  );

  Widget _privacyBullet(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('• ',
          style:
          TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
      Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF555555),
                  height: 1.6))),
    ]),
  );

  // ── Report section helpers ────────────────────────────────────────────────────

  Widget _reportHeading(String text) => Text(text,
      style: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1A7A72)));

  Widget _reportBody(String text) => Text(text,
      style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555), height: 1.5));

  Widget _reportBullet(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('• ', style: TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
      Expanded(child: Text(text,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555), height: 1.5))),
    ]),
  );

  Widget _badgeItem(Color color, String badge, String desc) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Text(badge,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
      const Text(' — ', style: TextStyle(fontSize: 12.5, color: Color(0xFF888888))),
      Expanded(child: Text(desc,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555)))),
    ],
  );

  void _showSpamToggleConfirmation(bool turningOn) {
    final items = turningOn
        ? [
      (Icons.move_to_inbox_outlined,
      'Messages PhishSense detects as phishing will be automatically moved out of your inbox and into the Spam Folder.'),
      (Icons.folder_outlined,
      'You can open the Spam Folder anytime to review flagged messages.'),
      (Icons.history_outlined,
      'If a message was flagged by mistake, you can restore it back to your inbox.'),
      (Icons.history_outlined,
      'Any messages already flagged as phishing in your inbox will move to the Spam Folder right away.'),
    ]
        : [
      (Icons.inbox_outlined,
      'All messages — including ones currently in the Spam Folder — will appear together in your inbox.'),
      (Icons.label_off_outlined,
      'Phishing labels will still be visible on flagged messages, but nothing will be automatically separated.'),
      (Icons.shield_outlined,
      'PhishSense will continue scanning and detecting phishing messages — only the automatic sorting is turned off.'),
      (Icons.settings_outlined,
      'You can turn the Spam Folder back on at any time from this Settings panel.'),
    ];

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF0F6F5),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8))
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // ── Icon header ──
            const SizedBox(height: 28),
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF1A7A72).withOpacity(.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                turningOn ? Icons.folder_special : Icons.folder_off_outlined,
                color: const Color(0xFF1A7A72),
                size: 32,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              turningOn ? 'Turn On Spam Folder?' : 'Turn Off Spam Folder?',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black87),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                turningOn
                    ? "Here's what will change once you enable it:"
                    : "Here's what will happen when you turn it off:",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
              ),
            ),
            const SizedBox(height: 16),

            // ── Bullet items ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A7A72).withOpacity(.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(item.$1, size: 17, color: const Color(0xFF1A7A72)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(item.$2,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF333333), height: 1.5)),
                    ),
                  ]),
                )).toList(),
              ),
            ),

            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFFDDD8CE)),

            // ── Buttons ──
            Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF888888))),
                ),
              ),
              Container(width: 1, height: 48, color: const Color(0xFFDDD8CE)),
              Expanded(
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() => _spamEnabled = turningOn);
                    widget.onSpamToggled(turningOn);
                  },
                  child: Text(
                    turningOn ? 'Turn On' : 'Turn Off',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: turningOn
                            ? const Color(0xFF1A7A72)
                            : const Color(0xFFF2554F)),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final steps = _isIOS ? _kHowItWorksIOS : _kHowItWorksAndroid;

    return Drawer(
      backgroundColor: const Color(0xFFF6F4EC),
      child: Stack(children: [
        const Positioned.fill(child: _SidebarSoftBackground()),
        SafeArea(
          child: Column(children: [
            // ── Scrollable area ───────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                child: Column(children: [
                  // ── Profile Header ──────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Center(
                          child: Text('Profile',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold)),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            icon: const Icon(Icons.close,
                                color: Color(0xFF1A7A72)),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Avatar & Name ───────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
                    child: Column(children: [
                      Stack(alignment: Alignment.bottomRight, children: [
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
                                shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                                child: Text(_name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold))),
                            const SizedBox(width: 6),
                            GestureDetector(
                                onTap: _editName,
                                child: const Icon(Icons.edit,
                                    size: 18,
                                    color: Color(0xFF1A7A72))),
                          ]),
                      const SizedBox(height: 28),
                    ]),
                  ),

                  // ── Settings label ──────────────────────────────────────
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Settings',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold))),
                  ),

                  // ── Notification Permission (Android only) ──────────────
                  if (!_isIOS) ...[
                    _settingRow(
                      icon: Icons.notifications_active_outlined,
                      title: 'Notification Permission',
                      subtitle: 'Allow phishing alerts',
                      trailing: Switch(
                        value: _notifEnabled,
                        activeColor: const Color(0xFF1A7A72),
                        onChanged: (v) =>
                            setState(() => _notifEnabled = v),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],

                  // ── Spam Management ─────────────────────────────────────
                  _settingRow(
                    icon: Icons.folder_special_outlined,
                    title: 'Spam Management',
                    subtitle: 'Move detected messages to spam folder',
                    trailing: Switch(
                      value: _spamEnabled,
                      activeColor: const Color(0xFF1A7A72),
                      onChanged: (v) => _showSpamToggleConfirmation(v),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── How It Works card ───────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: const Color(0xFFDDD8CE), width: 0.8),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => setState(() =>
                              _howItExpanded = !_howItExpanded),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(children: [
                                  Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                          color: const Color(0xFF1A7A72),
                                          borderRadius:
                                          BorderRadius.circular(10)),
                                      child: const Icon(
                                          Icons.info_outline,
                                          color: Colors.white,
                                          size: 20)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text.rich(
                                        TextSpan(
                                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                                          children: [
                                            const TextSpan(text: 'How '),
                                            const TextSpan(text: 'Phish', style: TextStyle(color: Color(0xFF1A7A72))),
                                            const TextSpan(text: 'Sense', style: TextStyle(color: Color(0xFFE0A800))),
                                            const TextSpan(text: ' Works'),
                                          ],
                                        ),
                                      )),
                                  Icon(
                                    _howItExpanded
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    color: const Color(0xFF1A7A72),
                                  ),
                                ]),
                              ),
                            ),
                            if (_howItExpanded) ...[
                              const Divider(
                                  height: 1,
                                  color: Color(0xFFE0DDD5)),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.8),
                                  borderRadius:
                                  const BorderRadius.vertical(
                                      bottom: Radius.circular(16)),
                                ),
                                child: Column(
                                  children: steps
                                      .map((step) => Padding(
                                    padding: const EdgeInsets
                                        .symmetric(
                                        horizontal: 16,
                                        vertical: 12),
                                    child: Row(
                                        crossAxisAlignment:
                                        CrossAxisAlignment
                                            .start,
                                        children: [
                                          Text(step['emoji']!,
                                              style: const TextStyle(
                                                  fontSize: 28)),
                                          const SizedBox(
                                              width: 12),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                  CrossAxisAlignment
                                                      .start,
                                                  children: [
                                                    Text(
                                                        step[
                                                        'title']!,
                                                        style: const TextStyle(
                                                            fontSize:
                                                            13,
                                                            fontWeight:
                                                            FontWeight
                                                                .w700,
                                                            color: Color(
                                                                0xFF1A7A72))),
                                                    const SizedBox(
                                                        height: 3),
                                                    Text(
                                                        step['body']!,
                                                        style: const TextStyle(
                                                            fontSize:
                                                            12,
                                                            color: Color(
                                                                0xFF555555),
                                                            height:
                                                            1.5)),
                                                  ])),
                                        ]),
                                  ))
                                      .toList(),
                                ),
                              ),
                            ],
                          ]),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ── How Reports Are Handled card ────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: const Color(0xFFDDD8CE), width: 0.8),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => setState(() =>
                              _reportsExpanded = !_reportsExpanded),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(children: [
                                  Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                          color: const Color(0xFF1A7A72),
                                          borderRadius:
                                          BorderRadius.circular(10)),
                                      child: const Icon(
                                          Icons.flag_outlined,
                                          color: Colors.white,
                                          size: 20)),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                      child: Text('How Reports Are Handled',
                                          style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600))),
                                  Icon(
                                    _reportsExpanded
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    color: const Color(0xFF1A7A72),
                                  ),
                                ]),
                              ),
                            ),
                            if (_reportsExpanded) ...[
                              const Divider(height: 1, color: Color(0xFFE0DDD5)),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.8),
                                  borderRadius: const BorderRadius.vertical(
                                      bottom: Radius.circular(16)),
                                ),
                                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _reportHeading('What the Badges Mean'),
                                    const SizedBox(height: 6),
                                    _reportBody('Every scanned message gets a badge:'),
                                    const SizedBox(height: 8),
                                    _badgeItem(const Color(0xFF06C85E), 'Safe', 'AI found no threat'),
                                    const SizedBox(height: 6),
                                    _badgeItem(const Color(0xFFF2554F), 'Phishing Detected', 'AI flagged it as dangerous'),
                                    const SizedBox(height: 6),
                                    _badgeItem(const Color(0xFFAAAAAA), 'Verification in Progress', 'your report is under review'),
                                    const SizedBox(height: 14),

                                    _reportHeading('You Can Report Either Way'),
                                    const SizedBox(height: 6),
                                    _reportBody('Tap any badge to open the report dialog. You can report a "Phishing Detected" message as safe if you think it\'s a false alarm, or report a "Safe" message as phishing if something looks wrong to you.'),
                                    const SizedBox(height: 14),

                                    _reportHeading('Verification in Progress'),
                                    const SizedBox(height: 6),
                                    _reportBody('Once you submit a report, the badge changes to grey and shows "Verification in Progress". This means your report was received and is being reviewed — the message keeps its current label until the review is done.'),
                                    const SizedBox(height: 14),

                                    _reportHeading('Review Takes Time'),
                                    const SizedBox(height: 6),
                                    _reportBody('The reported message is checked to determine the correct label. This process may take a while depending on how many reports are in queue.'),
                                    const SizedBox(height: 14),

                                    _reportHeading('Label Gets Updated'),
                                    const SizedBox(height: 6),
                                    _reportBody('Once the review is complete, the grey badge disappears and the label is updated accordingly.'),
                                    const SizedBox(height: 6),
                                    _reportBullet('If the spam folder feature is enabled and the message is confirmed safe, it is automatically restored to the inbox.'),
                                    _reportBullet('If the message is confirmed as phishing, it remains flagged.'),
                                    const SizedBox(height: 14),

                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1A7A72).withOpacity(.07),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: const Color(0xFF1A7A72).withOpacity(.18)),
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.volunteer_activism_outlined,
                                              size: 18, color: Color(0xFF1A7A72)),
                                          const SizedBox(width: 8),
                                          const Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text('Your Report Matters',
                                                    style: TextStyle(
                                                        fontSize: 12.5,
                                                        fontWeight: FontWeight.w700,
                                                        color: Color(0xFF1A7A72))),
                                                SizedBox(height: 4),
                                                Text(
                                                    'Every report you send — whether correcting a false alarm or catching a missed threat — helps PhishSense become smarter and protects everyone who receives similar messages.',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Color(0xFF555555),
                                                        height: 1.5)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ]),
                    ),
                  ),

                  const SizedBox(height: 16),
                ]),
              ),
            ),

            // ── Privacy & Policy — pinned at very bottom ──────────────────
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: TextButton(
                onPressed: _showPrivacyPolicy,
                child: const Text(
                  'Privacy & Policy',
                  style: TextStyle(
                      color: Color(0xFFAAAAAA),
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFFAAAAAA)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
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
    void blob(Offset c, double r, Color col, double b) => canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = col
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, b));
    blob(Offset(size.width * 0.15, size.height * 0.22), size.width * 0.20, teal, 30);
    blob(Offset(size.width * 0.82, size.height * 0.18), size.width * 0.16, gold, 28);
    blob(Offset(size.width * 0.72, size.height * 0.62), size.width * 0.24, teal, 36);
    blob(Offset(size.width * 0.28, size.height * 0.82), size.width * 0.22, gold, 34);
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}