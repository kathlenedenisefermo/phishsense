import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'privacy_policy.dart';

class ProfileSidebar extends StatefulWidget {
  final int defaultSmsIndex;
  final bool notificationPermission;
  final bool spamFolderEnabled;
  final bool shareAnonymousData;
  final bool showDetectionPopup;

  final Function(int) onChangeDefaultSms;
  final Function(bool) onChangeNotificationPermission;
  final Function(bool) onChangeSpamFolder;
  final Function(bool) onChangeShareAnonymousData;
  final Function(bool) onChangeShowDetectionPopup;

  final String name;

  const ProfileSidebar({
    super.key,
    required this.defaultSmsIndex,
    required this.notificationPermission,
    required this.spamFolderEnabled,
    required this.onChangeDefaultSms,
    required this.onChangeNotificationPermission,
    required this.onChangeSpamFolder,
    required this.name,
    required this.shareAnonymousData,
    required this.showDetectionPopup,
    required this.onChangeShareAnonymousData,
    required this.onChangeShowDetectionPopup,
  });

  @override
  State<ProfileSidebar> createState() => _ProfileSidebarState();
}

class _ProfileSidebarState extends State<ProfileSidebar> {
  late String _name;
  String _avatar = "👨‍💻";
  String? _imagePath;
  DateTime? _lastUpdate;

  final List<String> _avatars = [
    "👨‍💻", "👩‍💻", "👨‍⚕️", "👩‍⚕️",
    "👨‍🏫", "👩‍🏫", "👨‍🍳", "👩‍🍳",
    "👨‍🔬", "👩‍🔬", "👨‍🎨", "👩‍🎨",
    "👨‍🚀", "👩‍🚀", "👨‍✈️", "👩‍✈️",
  ];

  bool _shareData = false;
  late bool _notificationPermission;
  late bool _showDetectionPopup;

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    _notificationPermission = widget.notificationPermission;
    _showDetectionPopup = widget.showDetectionPopup;
    _shareData = widget.shareAnonymousData;
  }

  bool get _isIOS => !kIsWeb && Platform.isIOS;

  String get _notificationTitle =>
      _isIOS ? "PhishSense Alerts" : "Notification Permission";

  String get _notificationSubtitle =>
      _isIOS ? "Allow PhishSense protection alerts" : "Allow phishing alerts";

  String get _spamTitle =>
      _isIOS ? "iOS Message Filtering" : "Spam Management";

  String get _spamSubtitle => _isIOS
      ? "Use iOS filtering for suspicious messages from unknown senders"
      : "Move detected messages to spam folder";

  String get _shareDataSubtitle => _isIOS
      ? "Help improve message filtering accuracy"
      : "Help improve phishing detection accuracy";

  String get _popupSubtitle => _isIOS
      ? "Show safe/phishing analysis card again"
      : "Show phishing/safe detection card again";

  bool get _canEdit {
    if (_lastUpdate == null) return true;
    return DateTime.now().difference(_lastUpdate!) >= const Duration(days: 7);
  }

  void _showCenterNote(String message) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(.15),
      builder: (_) {
        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.12),
                  offset: const Offset(0, 4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Color(0xFF1A7A72),
                  size: 22,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFF333333),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).maybePop();
    });
  }

  void _closeSidebarThenShowNote(String message) {
    Navigator.pop(context);
    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _showCenterNote(message);
    });
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Confirm"),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _editName() {
    if (!_canEdit) {
      _showCenterNote("You can update your profile again in 7 days.");
      return;
    }

    final controller = TextEditingController(text: _name);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Edit Name"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "Enter your name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _name = controller.text.trim().isEmpty
                    ? _name
                    : controller.text.trim();
                _lastUpdate = DateTime.now();
              });
              Navigator.pop(context);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context);
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85);
    if (picked != null && mounted) {
      setState(() => _imagePath = picked.path);
    }
  }

  void _showAvatarGrid() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).padding.bottom;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 20 + bottomInset),
          shrinkWrap: true,
          itemCount: _avatars.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
          ),
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
              child: Text(_avatars[i], style: const TextStyle(fontSize: 28)),
            ),
          ),
        );
      },
    );
  }

  void _editAvatar() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).padding.bottom;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36,
              height: 4,
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
                child: Icon(Icons.photo_library_outlined, color: Color(0xFF1A7A72)),
              ),
              title: const Text('Choose from Gallery'),
              onTap: () => _pickImage(ImageSource.gallery),
            ),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFE8F5E9),
                child: Icon(Icons.emoji_emotions_outlined, color: Color(0xFF1A7A72)),
              ),
              title: const Text('Choose an Avatar'),
              onTap: () {
                Navigator.pop(ctx);
                _showAvatarGrid();
              },
            ),
            SizedBox(height: 8 + bottomInset),
          ],
        );
      },
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF1A7A72),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                      height: 1.15,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF444444),
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: trailing ?? const SizedBox(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.of(context).size.width * .88,
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFF6F4EC),
              Color(0xFFF2ECE1),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
          child: Stack(
            children: [
              const Positioned.fill(
                child: _SidebarSoftBackground(),
              ),
              SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Center(
                            child: Text(
                              "Profile",
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                        child: Column(
                          children: [
                            Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                CircleAvatar(
                                  radius: 50,
                                  backgroundColor: const Color(0xFF1A7A72).withOpacity(.15),
                                  backgroundImage: _imagePath != null
                                      ? FileImage(File(_imagePath!))
                                      : null,
                                  child: _imagePath == null
                                      ? Text(
                                          _avatar,
                                          style: const TextStyle(fontSize: 40),
                                        )
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
                                    child: const Icon(
                                      Icons.edit,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    _name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: _editName,
                                  child: const Icon(
                                    Icons.edit,
                                    size: 18,
                                    color: Color(0xFF1A7A72),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  "Settings",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ),
                            _row(
                              icon: Icons.notifications_active,
                              title: _notificationTitle,
                              subtitle: _notificationSubtitle,
                              trailing: Switch(
                                value: _notificationPermission,
                                activeColor: const Color(0xFF1A7A72),
                                onChanged: (v) async {
                                  final ok = await _confirm(
                                    v ? "Turn On Notifications" : "Turn Off Notifications",
                                    v
                                        ? (_isIOS
                                            ? "Are you sure you want to turn on PhishSense protection alerts on iOS?"
                                            : "Are you sure you want to turn on phishing alert notifications?")
                                        : (_isIOS
                                            ? "Are you sure you want to turn off PhishSense protection alerts on iOS?"
                                            : "Are you sure you want to turn off phishing alert notifications?"),
                                  );

                                  if (!ok) return;

                                  setState(() {
                                    _notificationPermission = v;
                                  });
                                  widget.onChangeNotificationPermission(v);
                                },
                              ),
                            ),
                            _row(
                              icon: Icons.mobile_screen_share_outlined,
                              title: _isIOS ? "Improve Message Filtering" : "Share Anonymous Data",
                              subtitle: _shareDataSubtitle,
                              trailing: Switch(
                                value: _shareData,
                                activeColor: const Color(0xFF1A7A72),
                                onChanged: (v) {
                                  setState(() => _shareData = v);
                                  widget.onChangeShareAnonymousData(v);
                                },
                              ),
                            ),
                            _row(
                              icon: Icons.folder,
                              title: _spamTitle,
                              subtitle: _spamSubtitle,
                              trailing: Switch(
                                value: widget.spamFolderEnabled,
                                activeColor: const Color(0xFF1A7A72),
                                onChanged: (v) async {
                                  if (v) {
                                    final ok = await _confirm(
                                      _isIOS ? "Enable Message Filtering" : "Enable Spam Folder",
                                      _isIOS
                                          ? "Suspicious messages from unknown senders will be handled through iOS message filtering."
                                          : "Detected phishing messages will appear in the Spam Folder.",
                                    );
                                    if (!ok) return;
                                    widget.onChangeSpamFolder(true);
                                    _closeSidebarThenShowNote(
                                      _isIOS ? "Message filtering enabled." : "Spam Folder enabled.",
                                    );
                                  } else {
                                    final ok = await _confirm(
                                      _isIOS ? "Disable Message Filtering" : "Disable Spam Folder",
                                      _isIOS
                                          ? "Are you sure you want to turn off iOS message filtering support?"
                                          : "Are you sure you want to turn off Spam Folder?",
                                    );
                                    if (!ok) return;
                                    widget.onChangeSpamFolder(false);
                                    _closeSidebarThenShowNote(
                                      _isIOS ? "Message filtering disabled." : "Spam Folder disabled.",
                                    );
                                  }
                                },
                              ),
                            ),
                            _row(
                              icon: Icons.visibility,
                              title: _isIOS ? "Show Message Analysis" : "Show Detection Popup",
                              subtitle: _popupSubtitle,
                              trailing: Switch(
                                value: _showDetectionPopup,
                                activeColor: const Color(0xFF1A7A72),
                                onChanged: (v) async {
                                  final ok = await _confirm(
                                    v ? "Turn On Detection Popup" : "Turn Off Detection Popup",
                                    v
                                        ? (_isIOS
                                            ? "Are you sure you want to show the safe/phishing analysis popup again on iOS?"
                                            : "Are you sure you want to turn on the phishing/safe detection popup again?")
                                        : (_isIOS
                                            ? "Are you sure you want to hide the safe/phishing analysis popup on iOS?"
                                            : "Are you sure you want to turn off the phishing/safe detection popup?"),
                                  );

                                  if (!ok) return;

                                  setState(() {
                                    _showDetectionPopup = v;
                                  });
                                  widget.onChangeShowDetectionPopup(v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom + 20,
                      ),
                      child: GestureDetector(
                        onTap: () {
                          PrivacyPolicyDialog.show(context);
                        },
                        child: const Text(
                          "Privacy & Policy",
                          style: TextStyle(
                            color: Colors.grey,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

    void drawBlurBlob({
      required Offset center,
      required double radius,
      required Color color,
      required double blur,
    }) {
      final paint = Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);

      canvas.drawCircle(center, radius, paint);
    }

    void drawSoftArc({
      required Rect rect,
      required double startAngle,
      required double sweepAngle,
      required Color color,
      required double strokeWidth,
      required double blur,
    }) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);

      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
    }

    drawBlurBlob(
      center: Offset(size.width * 0.15, size.height * 0.22),
      radius: size.width * 0.20,
      color: teal,
      blur: 30,
    );

    drawBlurBlob(
      center: Offset(size.width * 0.82, size.height * 0.18),
      radius: size.width * 0.16,
      color: gold,
      blur: 28,
    );

    drawBlurBlob(
      center: Offset(size.width * 0.72, size.height * 0.62),
      radius: size.width * 0.24,
      color: teal,
      blur: 36,
    );

    drawBlurBlob(
      center: Offset(size.width * 0.28, size.height * 0.82),
      radius: size.width * 0.22,
      color: gold,
      blur: 34,
    );

    drawSoftArc(
      rect: Rect.fromCircle(
        center: Offset(size.width * 0.92, size.height * 0.92),
        radius: size.width * 0.42,
      ),
      startAngle: 3.7,
      sweepAngle: 1.6,
      color: teal.withOpacity(0.08),
      strokeWidth: 28,
      blur: 14,
    );

    drawSoftArc(
      rect: Rect.fromCircle(
        center: Offset(size.width * 0.95, size.height * 0.95),
        radius: size.width * 0.30,
      ),
      startAngle: 3.9,
      sweepAngle: 1.45,
      color: gold.withOpacity(0.06),
      strokeWidth: 18,
      blur: 10,
    );

    drawSoftArc(
      rect: Rect.fromCircle(
        center: Offset(size.width * 0.05, size.height * 0.10),
        radius: size.width * 0.35,
      ),
      startAngle: 5.2,
      sweepAngle: 1.2,
      color: teal.withOpacity(0.05),
      strokeWidth: 22,
      blur: 12,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
