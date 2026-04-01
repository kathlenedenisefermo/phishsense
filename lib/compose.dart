import 'package:flutter/material.dart';
import 'services/sms_service.dart';

class ComposePage extends StatefulWidget {
  final String? initialRecipient;
  final String? initialBody;

  const ComposePage({super.key, this.initialRecipient, this.initialBody});

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  late final TextEditingController _recipientCtrl;
  late final TextEditingController _bodyCtrl;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _recipientCtrl = TextEditingController(text: widget.initialRecipient ?? '');
    _bodyCtrl = TextEditingController(text: widget.initialBody ?? '');
    _bodyCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final to = _recipientCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (to.isEmpty || body.isEmpty) return;
    setState(() => _sending = true);
    try {
      await SmsService.sendSms(to, body);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickContact() async {
    final contacts = await SmsService.getAllContacts();
    if (!mounted || contacts.isEmpty) return;

    final picked = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        final filtered = ValueNotifier<List<Map<String, String>>>(contacts);
        return AlertDialog(
          title: const Text('Select Contact'),
          contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search contacts…',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    onChanged: (q) {
                      filtered.value = q.isEmpty
                          ? contacts
                          : contacts
                              .where((c) =>
                                  (c['name'] ?? '')
                                      .toLowerCase()
                                      .contains(q.toLowerCase()) ||
                                  (c['number'] ?? '').contains(q))
                              .toList();
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, String>>>(
                    valueListenable: filtered,
                    builder: (_, list, __) => ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) => ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              const Color(0xFF1A7A72).withOpacity(0.12),
                          child: Text(
                            (list[i]['name'] ?? '?')[0].toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFF1A7A72),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(list[i]['name'] ?? ''),
                        subtitle: Text(list[i]['number'] ?? ''),
                        onTap: () => Navigator.pop(ctx, list[i]),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (picked != null) {
      _recipientCtrl.text = picked['number'] ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bodyLength = _bodyCtrl.text.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'New Message',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.send_rounded),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Text(
                  'To: ',
                  style: TextStyle(fontSize: 15, color: Color(0xFF888888)),
                ),
                Expanded(
                  child: TextField(
                    controller: _recipientCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Phone number',
                      hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.contacts_outlined,
                      color: Color(0xFF1A7A72)),
                  onPressed: _pickContact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          Container(height: 1, color: const Color(0xFFE5E2D8)),
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _bodyCtrl,
                maxLines: null,
                expands: true,
                autofocus: widget.initialRecipient != null || widget.initialBody != null,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Type a message…',
                  hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                ),
                textAlignVertical: TextAlignVertical.top,
              ),
            ),
          ),
          if (bodyLength > 0)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  bodyLength > 160
                      ? '$bodyLength (${(bodyLength / 153).ceil()} SMS)'
                      : '$bodyLength/160',
                  style: TextStyle(
                    fontSize: 11,
                    color: bodyLength > 160 ? Colors.orange : const Color(0xFF888888),
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}
