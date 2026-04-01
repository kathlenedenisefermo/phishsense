import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'services/sms_service.dart';
import 'services/phishing_indicators.dart';

/// Reusable confirmation dialog. Returns true when the user taps the confirm button.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required Color confirmColor,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: confirmColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

class SpamFolderPage extends StatefulWidget {
  final List<SmsMessage> spamMessages;
  final Map<String, String> contactNames;
  final Future<void> Function(SmsMessage) onRestore;
  final Future<void> Function(SmsMessage) onReport;
  final Future<void> Function(SmsMessage) onDelete;
  final Future<void> Function() onDeleteAll;

  const SpamFolderPage({
    super.key,
    required this.spamMessages,
    required this.contactNames,
    required this.onRestore,
    required this.onReport,
    required this.onDelete,
    required this.onDeleteAll,
  });

  @override
  State<SpamFolderPage> createState() => _SpamFolderPageState();
}

class _SpamFolderPageState extends State<SpamFolderPage> {
  String _selectedPeriod = "7 days";
  late List<SmsMessage> _allMessages;
  List<List<SmsMessage>> _groups = [];

  @override
  void initState() {
    super.initState();
    _allMessages = List.from(widget.spamMessages);
    _buildGroups();
  }

  void _buildGroups() {
    final map = <int, List<SmsMessage>>{};
    for (final msg in _allMessages) {
      map.putIfAbsent(msg.threadId ?? 0, () => []).add(msg);
    }
    _groups = map.values.map((msgs) {
      return msgs..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    }).toList()
      ..sort((a, b) => b.first.timestamp.compareTo(a.first.timestamp));
  }

  bool _sameMessage(SmsMessage a, SmsMessage b) =>
      a.id != null ? a.id == b.id : (a.timestamp == b.timestamp && a.sender == b.sender && a.body == b.body);

  void _removeMessage(SmsMessage msg) {
    setState(() {
      _allMessages.removeWhere((m) => _sameMessage(m, msg));
      _buildGroups();
    });
  }

  void _removeAllMessages() {
    setState(() {
      _allMessages.clear();
      _groups.clear();
    });
  }

  int get _totalMessages => _groups.fold(0, (sum, g) => sum + g.length);

  String _displayName(String sender) =>
      widget.contactNames[sender] ?? sender;

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('MMM d').format(dt);
  }

  Future<void> _confirmDeleteAll() async {
    if (_groups.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Delete All Spam'),
        content: Text(
            'Are you sure you want to permanently delete all $_totalMessages spam '
            'message${_totalMessages == 1 ? '' : 's'}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF2554F),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.onDeleteAll();
    if (mounted) _removeAllMessages();
  }

  void _openSenderMessages(List<SmsMessage> group) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SenderMessagesPage(
          senderName: _displayName(group.first.sender),
          messages: List.from(group),
          onRestore: (msg) async {
            await widget.onRestore(msg);
            if (mounted) _removeMessage(msg);
          },
          onReport: (msg) async {
            await widget.onReport(msg);
            if (mounted) _removeMessage(msg);
          },
          onDelete: (msg) async {
            await widget.onDelete(msg);
            if (mounted) _removeMessage(msg);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Column(
          children: [
            _TopHeader(onClose: () => Navigator.pop(context)),

            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Spam Folder',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _groups.isEmpty
                        ? 'No detected smishing messages'
                        : '$_totalMessages smishing message${_totalMessages == 1 ? '' : 's'} '
                          'from ${_groups.length} sender${_groups.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Auto-delete settings card
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3EEE4),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.timer_outlined,
                            size: 16, color: Color(0xFF1A7A72)),
                        const SizedBox(width: 8),
                        const Text(
                          'Auto-delete after',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF555555),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A7A72),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedPeriod,
                              dropdownColor: const Color(0xFF1A7A72),
                              iconEnabledColor: Colors.white,
                              isDense: true,
                              borderRadius: BorderRadius.circular(10),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: '2 days', child: Text('2 days')),
                                DropdownMenuItem(
                                    value: '7 days', child: Text('7 days')),
                                DropdownMenuItem(
                                    value: '30 days',
                                    child: Text('30 days')),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _selectedPeriod = v);
                                }
                              },
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _confirmDeleteAll,
                          icon: const Icon(Icons.delete_outline,
                              size: 15, color: Color(0xFFF2554F)),
                          label: const Text(
                            'Delete all',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFF2554F),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // Sender list or empty state
            Expanded(
              child: _groups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline,
                              size: 60,
                              color: const Color(0xFF1A7A72).withOpacity(.5)),
                          const SizedBox(height: 12),
                          const Text(
                            'No spam messages',
                            style: TextStyle(
                              fontSize: 16,
                              color: Color(0xFF888888),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: _groups.length,
                      separatorBuilder: (_, __) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 26),
                        height: 1,
                        color: Colors.black.withOpacity(.06),
                      ),
                      itemBuilder: (context, index) {
                        final group = _groups[index];
                        return _SenderRow(
                          senderName: _displayName(group.first.sender),
                          messageCount: group.length,
                          latestTime: _formatTime(group.first.timestamp),
                          onTap: () => _openSenderMessages(group),
                        );
                      },
                    ),
            ),

            Container(
              height: 20,
              width: double.infinity,
              color: const Color(0xFF1A7A72),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Top header ────────────────────────────────────────────────────────────────

class _TopHeader extends StatelessWidget {
  final VoidCallback onClose;
  const _TopHeader({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A7A72),
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
      child: Row(
        children: [
          const Icon(Icons.phishing, color: Color(0xFF888880), size: 28),
          const SizedBox(width: 6),
          const Text(
            'Phish',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
              ],
            ),
          ),
          const Text(
            'Sense',
            style: TextStyle(
              color: Color(0xFFE0A800),
              fontSize: 28,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close),
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}

// ── Sender row (main list) ────────────────────────────────────────────────────

class _SenderRow extends StatelessWidget {
  final String senderName;
  final int messageCount;
  final String latestTime;
  final VoidCallback onTap;

  const _SenderRow({
    required this.senderName,
    required this.messageCount,
    required this.latestTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(
          children: [
            // Avatar circle
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFFE8E0D0),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFF2554F).withOpacity(.4),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  senderName.isNotEmpty
                      ? senderName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A5A5A),
                  ),
                ),
              ),
            ),

            const SizedBox(width: 14),

            // Name + "X phishing messages"
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    senderName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$messageCount phishing message${messageCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFF2554F),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            // Time + chevron
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  latestTime,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
                ),
                const SizedBox(height: 4),
                const Icon(Icons.chevron_right,
                    size: 18, color: Color(0xFFAAAAAA)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sender messages page ──────────────────────────────────────────────────────

class _SenderMessagesPage extends StatefulWidget {
  final String senderName;
  final List<SmsMessage> messages;
  final Future<void> Function(SmsMessage) onRestore;
  final Future<void> Function(SmsMessage) onReport;
  final Future<void> Function(SmsMessage) onDelete;

  const _SenderMessagesPage({
    required this.senderName,
    required this.messages,
    required this.onRestore,
    required this.onReport,
    required this.onDelete,
  });

  @override
  State<_SenderMessagesPage> createState() => _SenderMessagesPageState();
}

class _SenderMessagesPageState extends State<_SenderMessagesPage> {
  late List<SmsMessage> _messages;

  @override
  void initState() {
    super.initState();
    _messages = List.from(widget.messages);
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return DateFormat('EEE, h:mm a').format(dt);
    return DateFormat('MMM d, h:mm a').format(dt);
  }

  Future<void> _handleRestore(SmsMessage msg) async {
    await widget.onRestore(msg);
    if (!mounted) return;
    setState(() => _messages.removeWhere((m) => _same(m, msg)));
    if (_messages.isEmpty && mounted) Navigator.pop(context);
  }

  Future<void> _handleDelete(SmsMessage msg) async {
    await widget.onDelete(msg);
    if (!mounted) return;
    setState(() => _messages.removeWhere((m) => _same(m, msg)));
    if (_messages.isEmpty && mounted) Navigator.pop(context);
  }

  Future<void> _handleReport(SmsMessage msg) async {
    await widget.onReport(msg);
    if (!mounted) return;
    setState(() => _messages.removeWhere((m) => _same(m, msg)));
    if (_messages.isEmpty && mounted) Navigator.pop(context);
  }

  bool _same(SmsMessage a, SmsMessage b) =>
      a.id != null ? a.id == b.id : (a.timestamp == b.timestamp && a.sender == b.sender && a.body == b.body);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color: const Color(0xFF1A7A72),
              padding: const EdgeInsets.fromLTRB(8, 12, 22, 16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.senderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_messages.length} phishing message${_messages.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Message cards
            Expanded(
              child: _messages.isEmpty
                  ? const Center(
                      child: Text(
                        'No messages',
                        style: TextStyle(color: Color(0xFF888888)),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      itemCount: _messages.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        return _SpamMessageCard(
                          message: msg,
                          time: _formatTime(msg.timestamp),
                          onTap: () => _openMessageDetail(msg),
                          onRestore: () => _handleRestore(msg),
                          onReport: () => _handleReport(msg),
                          onDelete: () => _handleDelete(msg),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMessageDetail(SmsMessage msg) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _MessageDetailPage(
          senderName: widget.senderName,
          message: msg,
          time: _formatTime(msg.timestamp),
          onRestore: () => _handleRestore(msg),
          onReport: () => _handleReport(msg),
          onDelete: () => _handleDelete(msg),
        ),
      ),
    );
  }
}

// ── Individual spam message card ──────────────────────────────────────────────

class _SpamMessageCard extends StatelessWidget {
  final SmsMessage message;
  final String time;
  final VoidCallback onTap;
  final VoidCallback onRestore;
  final VoidCallback onReport;
  final VoidCallback onDelete;

  const _SpamMessageCard({
    required this.message,
    required this.time,
    required this.onTap,
    required this.onRestore,
    required this.onReport,
    required this.onDelete,
  });

  List<String> _reasons() {
    const emojiMap = <String, String>{
      'Suspicious URL': '🔗',
      'Threatening language': '⚠️',
      'Fear-based language': '😨',
      'Sensitive info request': '🔑',
      'Account update lure': '📝',
      'Urgency tactics': '⏰',
      'Bank / e-wallet spoof': '🏦',
      'Gov. agency spoof': '🏛️',
      'Delivery service spoof': '📦',
      'Trusted entity spoof': '🏢',
      'Fake prize / giveaway': '🎁',
      'Link / download bait': '👆',
      'SIM reg scam': '📱',
      'Suspicious content': '⚠️',
    };
    final indicators = PhishingIndicatorDetector.detect(message.body, maxCount: 4);
    if (indicators.isEmpty) return ['⚠️ Suspicious content'];
    return indicators
        .map((i) => '${emojiMap[i.label] ?? '⚠️'} ${i.label}')
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    const badgeColor = Color(0xFFF2554F);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF3EEE4),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.05),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Red accent bar
                    Container(width: 8, color: badgeColor),

                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Message preview + time + open hint
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    message.body,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.45,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      time,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF666666),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Tap to view',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF1A7A72),
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 10),

                            // Why flagged
                            const Text(
                              'Why this was flagged:',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 5),
                            ..._reasons().map(
                              (reason) => Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  reason,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF444444),
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 12),

                            // Action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      final ok = await _confirm(
                                        context,
                                        title: 'Restore message?',
                                        body:
                                            'This message will be moved back to your inbox. '
                                            'It will keep its Phishing label.',
                                        confirmLabel: 'Restore',
                                        confirmColor: const Color(0xFF06C85E),
                                      );
                                      if (ok) onRestore();
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF06C85E),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                    ),
                                    child: const Text('Restore',
                                        style: TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      final ok = await _confirm(
                                        context,
                                        title: 'Delete message?',
                                        body:
                                            'This message will be permanently deleted '
                                            'and cannot be recovered.',
                                        confirmLabel: 'Delete',
                                        confirmColor: badgeColor,
                                      );
                                      if (ok) onDelete();
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: badgeColor,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                    ),
                                    child: const Text('Delete',
                                        style: TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final ok = await _confirm(
                                    context,
                                    title: 'Report as Inaccurate?',
                                    body:
                                        'Report this message as incorrectly flagged? '
                                        'It will be marked as safe and moved back to your inbox.',
                                    confirmLabel: 'Report',
                                    confirmColor: const Color(0xFF1A7A72),
                                  );
                                  if (ok) onReport();
                                },
                                icon: const Icon(Icons.flag_outlined, size: 14),
                                label: const Text(
                                  'Report as Inaccurate',
                                  style: TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1A7A72),
                                  side: const BorderSide(
                                      color: Color(0xFF1A7A72), width: 1.2),
                                  padding: const EdgeInsets.symmetric(vertical: 9),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Full message detail page ──────────────────────────────────────────────────

class _MessageDetailPage extends StatelessWidget {
  final String senderName;
  final SmsMessage message;
  final String time;
  final VoidCallback onRestore;
  final VoidCallback onReport;
  final VoidCallback onDelete;

  const _MessageDetailPage({
    required this.senderName,
    required this.message,
    required this.time,
    required this.onRestore,
    required this.onReport,
    required this.onDelete,
  });

  List<String> _reasons() {
    const emojiMap = <String, String>{
      'Suspicious URL': '🔗',
      'Threatening language': '⚠️',
      'Fear-based language': '😨',
      'Sensitive info request': '🔑',
      'Account update lure': '📝',
      'Urgency tactics': '⏰',
      'Bank / e-wallet spoof': '🏦',
      'Gov. agency spoof': '🏛️',
      'Delivery service spoof': '📦',
      'Trusted entity spoof': '🏢',
      'Fake prize / giveaway': '🎁',
      'Link / download bait': '👆',
      'SIM reg scam': '📱',
      'Suspicious content': '⚠️',
    };
    final indicators = PhishingIndicatorDetector.detect(message.body, maxCount: 8);
    if (indicators.isEmpty) return ['⚠️ Suspicious content'];
    return indicators.map((i) => '${emojiMap[i.label] ?? '⚠️'} ${i.label}').toList();
  }

  @override
  Widget build(BuildContext context) {
    const badgeColor = Color(0xFFF2554F);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color: const Color(0xFF1A7A72),
              padding: const EdgeInsets.fromLTRB(8, 12, 22, 16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          senderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          time,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Phishing badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      message.confidence != null && message.confidence! > 0
                          ? 'Phishing (${(message.confidence! * 100).toStringAsFixed(0)}%)'
                          : 'Phishing Detected',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Full message body
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3EEE4),
                        borderRadius: BorderRadius.circular(16),
                        border: Border(
                          left: BorderSide(color: badgeColor, width: 4),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(.05),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        message.body,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: Colors.black87,
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Why flagged section
                    const Text(
                      'Why this was flagged:',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.6),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.black.withOpacity(.06),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _reasons()
                            .map(
                              (r) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  r,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Color(0xFF333333),
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final ok = await _confirm(
                                context,
                                title: 'Restore message?',
                                body:
                                    'This message will be moved back to your inbox. '
                                    'It will keep its Phishing label.',
                                confirmLabel: 'Restore',
                                confirmColor: const Color(0xFF06C85E),
                              );
                              if (ok) {
                                onRestore();
                                if (context.mounted) Navigator.pop(context);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF06C85E),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            child: const Text('Restore',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final ok = await _confirm(
                                context,
                                title: 'Delete message?',
                                body:
                                    'This message will be permanently deleted '
                                    'and cannot be recovered.',
                                confirmLabel: 'Delete',
                                confirmColor: badgeColor,
                              );
                              if (ok) {
                                onDelete();
                                if (context.mounted) Navigator.pop(context);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: badgeColor,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            child: const Text('Delete',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await _confirm(
                            context,
                            title: 'Report as Inaccurate?',
                            body:
                                'Report this message as incorrectly flagged? '
                                'It will be marked as safe and moved back to your inbox.',
                            confirmLabel: 'Report',
                            confirmColor: const Color(0xFF1A7A72),
                          );
                          if (ok) {
                            onReport();
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                        icon: const Icon(Icons.flag_outlined, size: 16),
                        label: const Text(
                          'Report as Inaccurate',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1A7A72),
                          side: const BorderSide(
                              color: Color(0xFF1A7A72), width: 1.2),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
