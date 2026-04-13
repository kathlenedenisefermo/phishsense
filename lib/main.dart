import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'welcome.dart';
import 'notice.dart';
import 'name_page.dart';
import 'ios_messages.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhishSense',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A7A72),
          primary: const Color(0xFF1A7A72),
          secondary: const Color(0xFFE0A800),
        ),
        useMaterial3: true,
        fontFamily: 'Inter',
      ),
      home: const AppFlow(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppFlow  —  welcome → notice/accept → name → ios_messages
// ─────────────────────────────────────────────────────────────────────────────

class AppFlow extends StatefulWidget {
  const AppFlow({super.key});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

class _AppFlowState extends State<AppFlow> {
  bool   _loading     = true;
  int    _step        = 0; // 0=welcome  1=notice  2=name  3=messages
  String _userName    = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs    = await SharedPreferences.getInstance();
    final complete = prefs.getBool('setup_complete') ?? false;
    if (!mounted) return;
    setState(() {
      if (complete) {
        _userName = prefs.getString('user_name') ?? '';
        _step = 3;
      }
      _loading = false;
    });
  }

  Future<void> _saveComplete(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_complete', true);
    await prefs.setString('user_name', name);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6F4EC),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72))),
      );
    }

    switch (_step) {
      // ── Welcome ────────────────────────────────────────────────────────────
      case 0:
        return WelcomePage(
          setupCompleted: false,
          onGetStarted: () {
            // show notice dialog, then advance to name
            NoticeDialog.show(
              context,
              onAccept: () {
                Navigator.pop(context);
                setState(() => _step = 2);
              },
              onClose: () => Navigator.pop(context),
            );
          },
          onGoToProfile: () {},
        );

      // ── Name ───────────────────────────────────────────────────────────────
      case 2:
        return NamePage(
          onContinue: (name) async {
            setState(() => _userName = name);
            await _saveComplete(name);
            if (mounted) setState(() => _step = 3);
          },
        );

      // ── Main app ───────────────────────────────────────────────────────────
      case 3:
        return IOSMessagesPage(name: _userName);

      default:
        return const Scaffold(
          body: Center(child: Text("Something went wrong.")),
        );
    }
  }
}
