import 'package:flutter/material.dart';

class PhishingIndicator {
  final String label;
  final IconData icon;
  final Color color;

  const PhishingIndicator({
    required this.label,
    required this.icon,
    required this.color,
  });
}

class PhishingIndicatorDetector {
  /// Returns the most relevant indicators for [body], capped at [maxCount].
  static List<PhishingIndicator> detect(String body, {int maxCount = 4}) {
    final lower = body.toLowerCase();
    final results = <PhishingIndicator>[];

    // ── Tier 1: Highest-confidence indicators ────────────────────────────────

    if (_hasUrl(lower)) {
      results.add(const PhishingIndicator(
        label: 'Suspicious URL',
        icon: Icons.link_rounded,
        color: Color(0xFFD32F2F),
      ));
    }

    if (_hasThreat(lower)) {
      results.add(const PhishingIndicator(
        label: 'Threatening language',
        icon: Icons.gpp_bad_outlined,
        color: Color(0xFFD32F2F),
      ));
    }

    if (_hasFear(lower)) {
      results.add(const PhishingIndicator(
        label: 'Fear-based language',
        icon: Icons.warning_amber_rounded,
        color: Color(0xFFD32F2F),
      ));
    }

    if (_requestsInfo(lower)) {
      results.add(const PhishingIndicator(
        label: 'Sensitive info request',
        icon: Icons.lock_outline_rounded,
        color: Color(0xFFE64A19),
      ));
    }

    if (_hasAccountUpdate(lower)) {
      results.add(const PhishingIndicator(
        label: 'Account update lure',
        icon: Icons.manage_accounts_outlined,
        color: Color(0xFFE64A19),
      ));
    }

    // ── Tier 2: Impersonation ─────────────────────────────────────────────────

    if (_impersonatesBank(lower)) {
      results.add(const PhishingIndicator(
        label: 'Bank / e-wallet spoof',
        icon: Icons.account_balance_outlined,
        color: Color(0xFF7B1FA2),
      ));
    }

    if (_impersonatesGov(lower)) {
      results.add(const PhishingIndicator(
        label: 'Gov. agency spoof',
        icon: Icons.account_balance_wallet_outlined,
        color: Color(0xFF7B1FA2),
      ));
    }

    if (_impersonatesDelivery(lower)) {
      results.add(const PhishingIndicator(
        label: 'Delivery service spoof',
        icon: Icons.local_shipping_outlined,
        color: Color(0xFF7B1FA2),
      ));
    }

    if (_impersonatesOther(lower)) {
      results.add(const PhishingIndicator(
        label: 'Trusted entity spoof',
        icon: Icons.business_outlined,
        color: Color(0xFF7B1FA2),
      ));
    }

    // ── Tier 3: Other tactics ─────────────────────────────────────────────────

    if (_hasUrgency(lower)) {
      results.add(const PhishingIndicator(
        label: 'Urgency tactics',
        icon: Icons.timer_outlined,
        color: Color(0xFFF57C00),
      ));
    }

    if (_hasPrizeLure(lower)) {
      results.add(const PhishingIndicator(
        label: 'Fake prize / giveaway',
        icon: Icons.card_giftcard_outlined,
        color: Color(0xFFF57C00),
      ));
    }

    if (_hasLinkBait(lower)) {
      results.add(const PhishingIndicator(
        label: 'Link / download bait',
        icon: Icons.touch_app_outlined,
        color: Color(0xFFE64A19),
      ));
    }

    if (_hasSimScam(lower)) {
      results.add(const PhishingIndicator(
        label: 'SIM reg scam',
        icon: Icons.sim_card_alert_outlined,
        color: Color(0xFFD32F2F),
      ));
    }

    return results.take(maxCount).toList();
  }

  // ── Rules ──────────────────────────────────────────────────────────────────

  static bool _hasUrl(String lower) => RegExp(
    r'https?://|bit\.ly|tinyurl|goo\.gl|t\.co|ow\.ly|short\.io|cutt\.ly|rb\.gy'
    r'|is\.gd|tiny\.cc|shorte\.st|adf\.ly|linktr\.ee|rebrand\.ly',
  ).hasMatch(lower);

  // Hard threats: legal consequences, account action, crime language
  static bool _hasThreat(String lower) => _anyOf(lower, [
    'suspended', 'suspension', 'blocked', 'deactivated', 'terminated',
    'unauthorized', 'illegal', 'penalty', 'arrest',
    'legal action', 'police', 'court', 'violation', 'warrant',
    'compromised', 'hacked', 'breached',
    'face charges', 'criminal case', 'nbi clearance',
    'last warning', 'failure to comply',
  ]);

  // Softer fear: account closure, freezing, flagging, urgent warnings
  static bool _hasFear(String lower) => _anyOf(lower, [
    'your account will be', 'account will be closed', 'account will be suspended',
    'access will be', 'service will be', 'number will be',
    'frozen', 'flagged', 'put on hold', 'on hold',
    'closure', 'final notice', 'last chance to',
    'will be disabled', 'will be blocked', 'will be deactivated',
    'risk losing', 'lose access', 'no longer available',
    'mawawala ang', 'ibiblock', 'isasara ang',
  ]);

  // Urgency: time pressure to act
  static bool _hasUrgency(String lower) => _anyOf(lower, [
    'urgent', 'immediately', 'expires', 'expiring', 'expire',
    'act now', 'limited time', 'asap', 'right away',
    'deadline', 'today only', 'within 24', 'within 48', 'hours left',
    'respond now', 'reply now', 'do not ignore', 'action required',
    'immediate action', 'without delay', 'as soon as possible',
    // Filipino
    'mag-verify na', 'i-update na', 'mag-claim na', 'mag-redeem na',
    'i-click na', 'kumilos na', 'huwag palampasin',
    'mawawala na', 'mag-register na', 'paki-verify', 'paki-update',
  ]);

  // Requests for sensitive information (credentials, PINs, IDs)
  static bool _requestsInfo(String lower) => _anyOf(lower, [
    'password', 'passcode', 'otp', 'one-time pin', 'one time pin',
    'pin', 'mpin', 'transaction pin',
    'credit card', 'card number', 'cvv', 'expiry date',
    'account number', 'bank account', 'account details',
    'social security', 'sss number', 'tin number', 'philhealth number',
    'pagibig number', 'umid', 'postal id', 'national id',
    'voter id', 'prc id', 'lto license',
    'date of birth', "mother's maiden", 'full name', 'home address',
    'provide your', 'enter your', 'send your', 'submit your',
    'personal information', 'id number',
  ]);

  // Instructions to verify or update account details
  static bool _hasAccountUpdate(String lower) => _anyOf(lower, [
    'verify your account', 'verify your details', 'verify your identity',
    'confirm your account', 'confirm your details', 'confirm your identity',
    'update your account', 'update your details', 'update your information',
    'reactivate your account', 'validate your account', 'authenticate your',
    're-verify', 're-confirm', 're-register',
    'complete your verification', 'finish verification',
    'account verification', 'identity verification',
    'i-verify ang', 'i-update ang', 'kumpirmahin ang',
  ]);

  // ── Impersonation (split by entity type) ──────────────────────────────────

  // Banks, e-wallets, fintech
  static bool _impersonatesBank(String lower) => _anyOf(lower, [
    'bdo', 'bpi', 'metrobank', 'unionbank', 'pnb', 'landbank',
    'rcbc', 'security bank', 'eastwest bank', 'china bank', 'psbank',
    'aub', 'robinsons bank', 'maybank', 'banco de oro',
    'gcash', 'maya', 'paymaya', 'shopeepay', 'grabpay', 'coins.ph',
    'palawanpay', 'bayad', 'mlhuillier', 'cebuana', 'm lhuillier',
    'western union', 'paypal',
    'your bank', 'your e-wallet',
  ]);

  // Government agencies
  static bool _impersonatesGov(String lower) => _anyOf(lower, [
    'sss', 'philhealth', 'pag-ibig', 'pagibig', 'hdmf',
    'bir', 'lto', 'nbi', 'dfa', 'dswd', 'dole', 'psa', 'comelec',
    'philpost', 'pcso', 'pia', 'bsp',
    'government', 'republic of the philippines',
  ]);

  // Delivery and logistics providers
  static bool _impersonatesDelivery(String lower) => _anyOf(lower, [
    'jrs express', 'lbc', 'j&t', 'ninjavan', 'grab express',
    'lalamove', 'flash express', 'spx', 'shopee express',
    'dhl', 'fedex', 'your package', 'your parcel', 'your order',
    'delivery failed', 'delivery attempt', 'unable to deliver',
    'reschedule delivery', 'package on hold', 'customs fee',
    'delivery fee', 'clearance fee', 'tracking number',
  ]);

  // Other trusted entities (telcos, services, brands)
  static bool _impersonatesOther(String lower) => _anyOf(lower, [
    'globe', 'smart', 'dito', 'sun cellular', 'pldt', 'meralco',
    'netflix', 'amazon', 'apple', 'google', 'facebook',
    'instagram', 'microsoft', 'lazada', 'shopee',
    'your provider', 'your network', 'your telco',
  ]);

  // Fake prize, lottery, giveaway, or government subsidy lures
  static bool _hasPrizeLure(String lower) => _anyOf(lower, [
    'you won', 'you have won', 'winner', 'congratulations',
    'prize', 'claim your', 'you have been selected',
    'lucky', 'free gift', 'cash prize', 'raffle', 'lottery',
    'you are our', 'special offer', 'exclusive reward',
    'free load', 'free data', 'free credits',
    'ayuda', 'cash aid', 'cash assistance', 'financial assistance',
    'relief goods', '4ps', 'akap', 'pantawid',
    'nanalo ka', 'ikaw ang nanalo', 'libreng', 'i-claim ang',
  ]);

  // Instructions to click links or download/install content
  static bool _hasLinkBait(String lower) => _anyOf(lower, [
    'click here', 'tap here', 'click the link', 'tap the link',
    'click below', 'tap below', 'visit now', 'open link',
    'follow this link', 'access here', 'go to this link',
    'log in here', 'login here', 'sign in here',
    'download now', 'install now', 'get the app', 'scan the qr',
  ]);

  // SIM registration scams
  static bool _hasSimScam(String lower) => _anyOf(lower, [
    'sim registration', 'register your sim', 'sim card registration',
    'sim expiry', 'sim will be deactivated', 'unregistered sim',
    'ntc', 'national telecommunications',
  ]);

  static bool _anyOf(String text, List<String> keywords) =>
      keywords.any((k) => text.contains(k));
}
