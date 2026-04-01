import 'package:flutter/material.dart';
import 'services/sms_service.dart';
import 'compose.dart';

class ContactsPage extends StatefulWidget {
  /// When [embedded] is true the widget returns its content directly with no
  /// Scaffold or AppBar — used when hosted inside MessagesPage's IndexedStack.
  final bool embedded;

  const ContactsPage({super.key, this.embedded = false});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  List<Map<String, String>> _contacts = [];
  bool _loading = true;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final contacts = await SmsService.getAllContacts();
    if (!mounted) return;
    contacts.sort((a, b) =>
        (a['name'] ?? '').toLowerCase().compareTo((b['name'] ?? '').toLowerCase()));
    setState(() {
      _contacts = contacts;
      _loading = false;
    });
  }

  List<Map<String, String>> get _filtered {
    if (_searchQuery.isEmpty) return _contacts;
    final q = _searchQuery.toLowerCase();
    return _contacts
        .where((c) =>
            (c['name'] ?? '').toLowerCase().contains(q) ||
            (c['number'] ?? '').contains(q))
        .toList();
  }

  // Returns a flat list of items: String = section header, Map = contact row.
  // When searching, section headers are omitted for a clean flat result.
  List<dynamic> get _items {
    final filtered = _filtered;
    if (_searchQuery.isNotEmpty) return filtered;

    final items = <dynamic>[];
    String? lastLetter;
    for (final contact in filtered) {
      final name = contact['name'] ?? '';
      final letter = name.isNotEmpty ? name[0].toUpperCase() : '#';
      if (letter != lastLetter) {
        items.add(letter);
        lastLetter = letter;
      }
      items.add(contact);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final content = Column(
        children: [
          // ── Search bar ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFFF3EEE4),
                borderRadius: BorderRadius.circular(28),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 22, color: Color(0xFF7A7A7A)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Search contacts…',
                        hintStyle:
                            TextStyle(color: Color(0xFF9C9C9C), fontSize: 15),
                      ),
                      onChanged: (q) => setState(() => _searchQuery = q),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                      child: const Icon(Icons.close,
                          size: 18, color: Color(0xFF7A7A7A)),
                    ),
                ],
              ),
            ),
          ),

          // ── List ────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFF1A7A72)),
                  )
                : items.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.isNotEmpty
                              ? 'No contacts matching "$_searchQuery"'
                              : 'No contacts found.',
                          style: const TextStyle(
                              color: Color(0xFF888888), fontSize: 15),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 32),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final item = items[i];

                          // ── Section header ───────────────────────────
                          if (item is String) {
                            return Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(22, 14, 22, 4),
                              child: Text(
                                item,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A7A72),
                                  letterSpacing: 0.6,
                                ),
                              ),
                            );
                          }

                          // ── Contact row ──────────────────────────────
                          final contact = item as Map<String, String>;
                          final name = contact['name'] ?? '';
                          final number = contact['number'] ?? '';
                          final initial =
                              name.isNotEmpty ? name[0].toUpperCase() : '?';

                          // Don't show a divider before the next section header
                          final nextIsHeader = i + 1 < items.length &&
                              items[i + 1] is String;

                          return Column(
                            children: [
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 4),
                                leading: CircleAvatar(
                                  radius: 22,
                                  backgroundColor: const Color(0xFF1A7A72)
                                      .withOpacity(0.12),
                                  child: Text(
                                    initial,
                                    style: const TextStyle(
                                      color: Color(0xFF1A7A72),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1A1A1A),
                                  ),
                                ),
                                subtitle: Text(
                                  number,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF888888),
                                  ),
                                ),
                                trailing: const Icon(
                                  Icons.message_outlined,
                                  color: Color(0xFF1A7A72),
                                  size: 22,
                                ),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ComposePage(initialRecipient: number),
                                  ),
                                ),
                              ),
                              if (!nextIsHeader)
                                const Divider(
                                  height: 1,
                                  thickness: 1,
                                  indent: 72,
                                  endIndent: 18,
                                  color: Color(0xFFDDD8CE),
                                ),
                            ],
                          );
                        },
                      ),
          ),

          // ── Footer ──────────────────────────────────────────────────────
          if (!_loading && _contacts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '${_contacts.length} contact${_contacts.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
              ),
            ),
        ],
    );

    if (widget.embedded) return content;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Contacts',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      body: content,
    );
  }
}
