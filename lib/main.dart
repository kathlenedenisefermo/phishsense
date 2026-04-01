import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'welcome.dart';
import 'notice.dart';
import 'step1.dart';
import 'step2.dart';
import 'step3.dart';
import 'permission.dart';
import 'default_sms.dart';
import 'name_page.dart';
import 'messages.dart';
import 'error.dart';
import 'sync.dart';

void main() {
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

class AppFlow extends StatefulWidget {
  const AppFlow({super.key});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

class _AppFlowState extends State<AppFlow> {
  bool _loading = true;
  int _currentStep = 0;
  int _defaultSmsIndex = 1;

  bool _setupCompleted = false;
  bool _smsPermission = false;
  bool _notificationPermission = false;
  bool _contactsPermission = false;
  bool _spamFolderEnabled = false;
  bool _shareAnonymousData = false;
  bool _showDetectionPopup = true;

  String _userName = "";

  @override
  void initState() {
    super.initState();
    _loadSetupState();
  }

  Future<void> _loadSetupState() async {
    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool('setup_complete') ?? false;
    setState(() {
      if (complete) {
        _userName = prefs.getString('user_name') ?? '';
        _smsPermission = prefs.getBool('sms_permission') ?? false;
        _notificationPermission = prefs.getBool('notification_permission') ?? false;
        _contactsPermission = prefs.getBool('contacts_permission') ?? false;
        _setupCompleted = true;
        _currentStep = 7;
      }
      _loading = false;
    });
  }

  Future<void> _saveSetupState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_complete', true);
    await prefs.setString('user_name', _userName);
    await prefs.setBool('sms_permission', _smsPermission);
    await prefs.setBool('notification_permission', _notificationPermission);
    await prefs.setBool('contacts_permission', _contactsPermission);
  }

  void _nextStep() {
    setState(() => _currentStep++);
  }

  void _resetFlow() {
    setState(() {
      _currentStep = 0;
      _defaultSmsIndex = 1;
      _setupCompleted = false;
      _smsPermission = false;
      _notificationPermission = false;
      _contactsPermission = false;
      _spamFolderEnabled = false;
      _userName = "";
    });
  }

  void _showNotice() {
    NoticeDialog.show(
      context,
      onAccept: () {
        Navigator.pop(context);
        _nextStep();
      },
      onClose: () {
        Navigator.pop(context);
        _resetFlow();
      },
    );
  }

  void _showSmsError() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      ErrorPage.show(
        context,
        title: "SMS Access Required",
        message:
            "You cannot continue unless SMS access is allowed because PhishSense needs to scan messages for phishing.",
      );
    });
  }

  void _showContactsError() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      ErrorPage.show(
        context,
        title: "Contacts Access Required",
        message:
            "You cannot continue unless Contacts access is allowed because PhishSense uses trusted contacts to reduce false phishing alerts.",
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6F4EC),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF1A7A72)),
        ),
      );
    }

    switch (_currentStep) {
      case 0:
        return WelcomePage(
          setupCompleted: _setupCompleted,
          onGetStarted: _showNotice,
          onGoToProfile: () {},
        );

      case 1:
        return Step1Page(
          onContinue: () {
            PermissionPage.show(
              context,
              type: PermissionType.sms,
              onAllow: () {
                Permission.sms.request().then((status) {
                  if (status.isGranted) {
                    setState(() => _smsPermission = true);
                    _nextStep();
                  } else {
                    setState(() => _smsPermission = false);
                    _showSmsError();
                  }
                });
              },
              onDeny: () {
                setState(() => _smsPermission = false);
                _showSmsError();
              },
            );
          },
        );

      case 2:
        return Step2Page(
          onContinue: () {
            PermissionPage.show(
              context,
              type: PermissionType.contacts,
              onAllow: () {
                Permission.contacts.request().then((status) {
                  if (status.isGranted) {
                    setState(() => _contactsPermission = true);
                    _nextStep();
                  } else {
                    setState(() => _contactsPermission = false);
                    _showContactsError();
                  }
                });
              },
              onDeny: () {
                setState(() => _contactsPermission = false);
                _showContactsError();
              },
            );
          },
        );

      case 3:
        return Step3Page(
          onAllow: () {
            Permission.notification.request().then((status) {
              setState(() {
                _notificationPermission = status.isGranted;
                _currentStep = 4;
              });
            });
          },
          onSkip: () {
            setState(() {
              _notificationPermission = false;
              _currentStep = 4;
            });
          },
        );

      case 4:
        return NamePage(
          onContinue: (name) {
            setState(() {
              _userName = name;
              _currentStep = 5;
            });
          },
        );

      case 5:
        return DefaultSmsPage(
          initialIndex: _defaultSmsIndex,
          onSetDefault: (index) {
            setState(() {
              _defaultSmsIndex = index;
              _setupCompleted = true;
              _currentStep = 6;
            });
          },
        );

      case 6:
        return SyncPage(
          onDone: () {
            if (!mounted) return;
            _saveSetupState();
            setState(() => _currentStep = 7);
          },
        );

      case 7:
        return MessagesPage(
          name: _userName,
          defaultSmsIndex: _defaultSmsIndex,
          notificationPermission: _notificationPermission,
          spamFolderEnabled: _spamFolderEnabled,
          shareAnonymousData: _shareAnonymousData,
          showDetectionPopup: _showDetectionPopup,
          onChangeShareAnonymousData: (v) {
            setState(() => _shareAnonymousData = v);
          },
          onChangeShowDetectionPopup: (v) {
            setState(() => _showDetectionPopup = v);
          },
        );

      default:
        return const Scaffold(
          body: Center(child: Text("Something went wrong.")),
        );
    }
  }
}
