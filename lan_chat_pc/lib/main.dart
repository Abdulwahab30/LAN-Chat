import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

// Default gateway IP for the phone when USB-tethering (varies by device;
// check `ipconfig` on Windows for the "UsbNcm"/RNDIS adapter's gateway if
// this doesn't match, e.g. after a reboot or replug).
const defaultHost = '10.86.104.246';
const port = 8787;

const _bg = Color(0xFF0E0E10);
const _accent = Color(0xFFEDEDED);
const _muted = Color(0xFF8A8A8E);

void main() => runApp(const ChatApp());

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(surface: _bg, primary: _accent),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          hintStyle: const TextStyle(color: _muted),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

/// A frame of frosted glass: blurred, tinted, thin border. Same recipe used
/// for the app bar, bubbles and input bar so the whole UI reads as one
/// material.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.opacity = 0.08,
    this.blur = 18,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: opacity),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Background gradient glass sits on top of.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E1B2E), Color(0xFF0E0E10), Color(0xFF122024)],
            ),
          ),
        ),
        Positioned(top: -80, left: -60, child: _blob(const Color(0xFF7C5CFF), 260)),
        Positioned(bottom: -100, right: -80, child: _blob(const Color(0xFF2CD9C5), 300)),
        child,
      ],
    );
  }

  Widget _blob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35)),
    );
  }
}

sealed class ChatMessage {
  final bool mine;
  final DateTime time = DateTime.now();
  ChatMessage(this.mine);
}

class TextMessage extends ChatMessage {
  final String text;
  TextMessage(this.text, super.mine);
}

class FileMessage extends ChatMessage {
  final String name;
  final int size;
  final int id; // matches the offer's id, used to request/serve the actual bytes later
  Uint8List? bytes; // filled in once downloaded (or immediately, for the sender's own copy)
  String? savedPath;
  bool requested = false;
  FileMessage(this.name, this.size, {required this.id, this.bytes, this.savedPath, required bool mine})
      : super(mine);
}

// Wire protocol, all control frames as text JSON:
//   {"type":"file","id":...,"name":...,"size":...}        — a file is available, no bytes sent yet
//   {"type":"file_request","id":...}                      — receiver wants the bytes for that id
//   {"type":"file_data","id":...,"name":...,"size":...}   — followed immediately by one binary
//                                                             frame with the raw file bytes
class _FileHeader {
  final String name;
  final int size;
  final int id;
  _FileHeader(this.name, this.size, this.id);
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  WebSocket? _socket;
  bool _connected = false;
  String _status = 'Disconnected';
  final _messages = <ChatMessage>[];
  final _controller = TextEditingController();
  final _hostController = TextEditingController(text: defaultHost);
  final _scroll = ScrollController();
  _FileHeader? _pendingFile;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _manualDisconnect = false;
  final _offeredFiles = <int, PlatformFile>{}; // files we offered, keyed by id, for serving on request
  final _downloads = <int, FileMessage>{}; // files we requested, keyed by id, awaiting bytes
  int _nextFileId = 0;

  // ponytail: fixed backoff ladder rather than exponential-with-jitter math —
  // plenty for a 2-device LAN link, add jitter if this ever has many peers.
  static const _reconnectDelays = [1, 2, 4, 8, 16, 30];

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    setState(() => _status = 'Connecting…');
    try {
      final socket = await WebSocket.connect('ws://${_hostController.text}:$port');
      _reconnectAttempt = 0;
      setState(() {
        _socket = socket;
        _connected = true;
        _status = _hostController.text;
      });
      socket.listen(
        _handleIncoming,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (e) {
      setState(() {
        _connected = false;
        _status = 'Connection failed';
      });
    }
  }

  // A download in flight when the link drops will never get its bytes —
  // clear the spinner so the user can retry instead of it hanging forever.
  void _clearPendingDownloads() {
    for (final message in _downloads.values) {
      message.requested = false;
    }
    _downloads.clear();
  }

  void _disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _socket?.close();
    setState(() {
      _socket = null;
      _connected = false;
      _pendingFile = null;
      _status = 'Disconnected';
      _clearPendingDownloads();
    });
  }

  void _handleDisconnect() {
    if (_manualDisconnect) {
      _manualDisconnect = false;
      return;
    }
    setState(() {
      _socket = null;
      _connected = false;
      _pendingFile = null;
      _status = 'Reconnecting…';
      _clearPendingDownloads();
    });
    final delay = _reconnectDelays[_reconnectAttempt.clamp(0, _reconnectDelays.length - 1)];
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: delay), _connect);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleIncoming(dynamic data) async {
    if (data is String) {
      if (data.startsWith('{')) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map) {
            switch (decoded['type']) {
              case 'file':
                setState(() => _messages.add(FileMessage(
                      decoded['name'] as String,
                      decoded['size'] as int,
                      id: decoded['id'] as int,
                      mine: false,
                    )));
                _scrollToEnd();
                return;
              case 'file_request':
                _serveFileRequest(decoded['id'] as int);
                return;
              case 'file_data':
                _pendingFile = _FileHeader(
                  decoded['name'] as String,
                  decoded['size'] as int,
                  decoded['id'] as int,
                );
                return;
            }
          }
        } catch (_) {
          // Not a control frame after all — fall through and show it as text.
        }
      }
      setState(() => _messages.add(TextMessage(data, false)));
      _scrollToEnd();
      return;
    }
    final header = _pendingFile;
    _pendingFile = null;
    if (header == null) return;
    final message = _downloads.remove(header.id);
    if (message == null) return;
    final bytes = Uint8List.fromList(data as List<int>);
    setState(() {
      message.bytes = bytes;
      message.requested = false;
    });
    _saveFile(message);
  }

  // Runs on the offering side once the other end asks for the bytes.
  Future<void> _serveFileRequest(int id) async {
    final file = _offeredFiles[id];
    if (file == null || _socket == null) return;
    try {
      final bytes = await file.readAsBytes();
      _socket!.add(jsonEncode({'type': 'file_data', 'id': id, 'name': file.name, 'size': bytes.length}));
      _socket!.add(bytes);
    } catch (e) {
      _showError('Could not send ${file.name}: $e');
    }
  }

  Future<void> _downloadFile(FileMessage message) async {
    if (_socket == null || message.requested || message.bytes != null) return;
    setState(() => message.requested = true);
    _downloads[message.id] = message;
    try {
      _socket!.add(jsonEncode({'type': 'file_request', 'id': message.id}));
    } catch (e) {
      _downloads.remove(message.id);
      setState(() => message.requested = false);
      _showError('Download failed: $e');
    }
  }

  Future<void> _saveFile(FileMessage message) async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save received file',
        fileName: message.name,
        bytes: message.bytes!,
      );
      if (uri == null) return;
      setState(() => message.savedPath = uri.scheme == 'file' ? uri.toFilePath() : uri.toString());
    } catch (e) {
      _showError('Could not save ${message.name}: $e');
    }
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || _socket == null) return;
    try {
      _socket!.add(text);
    } catch (e) {
      _showError('Message not sent: $e');
      return;
    }
    setState(() => _messages.add(TextMessage(text, true)));
    _controller.clear();
    _scrollToEnd();
  }

  Future<void> _sendFile() async {
    if (_socket == null) return;
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final id = _nextFileId++;
    final size = await file.length();
    try {
      _socket!.add(jsonEncode({'type': 'file', 'id': id, 'name': file.name, 'size': size}));
    } catch (e) {
      _showError('${file.name} not sent: $e');
      return;
    }
    _offeredFiles[id] = file;
    setState(() => _messages.add(FileMessage(file.name, size, id: id, mine: true)));
    _scrollToEnd();
  }

  Future<void> _editHost() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1D),
        title: const Text('Phone IP address', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: _hostController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: '192.168.43.1'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _hostController.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) _connect();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _socket?.close();
    _controller.dispose();
    _hostController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        flexibleSpace: const Glass(borderRadius: BorderRadius.zero, child: SizedBox.expand()),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _connected ? const Color(0xFF3ED598) : _muted,
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _status,
                key: ValueKey(_status),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _connected ? 'Disconnect' : 'Connect',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _connected ? Icons.wifi_tethering_off : Icons.wifi_tethering,
                key: ValueKey(_connected),
              ),
            ),
            onPressed: _status == 'Connecting…' || _status == 'Reconnecting…'
                ? null
                : (_connected ? _disconnect : _connect),
          ),
          IconButton(
            tooltip: 'Phone IP address',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _editHost,
          ),
        ],
      ),
      body: GlassBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Text(
                          _connected ? 'No messages yet' : 'Tap the connect icon to connect',
                          style: TextStyle(color: _muted),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) => _FadeSlideIn(
                          child: _MessageBubble(_messages[i], onSave: _saveFile, onDownload: _downloadFile),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _socket == null ? 0.4 : 1,
                      child: IconButton(
                        icon: const Icon(Icons.attach_file, color: Colors.white70),
                        onPressed: _socket == null ? null : _sendFile,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(hintText: 'Message'),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _socket == null ? 0.4 : 1,
                      child: Container(
                        decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_upward_rounded, color: _bg),
                          onPressed: _socket == null ? null : _send,
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

/// Fades and slides its child up once when first built — used so a newly
/// appended message animates in without disturbing earlier bubbles, which
/// Flutter never rebuilds since ListView.builder only grows.
class _FadeSlideIn extends StatefulWidget {
  const _FadeSlideIn({required this.child});
  final Widget child;

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
        child: widget.child,
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(this.message, {required this.onSave, required this.onDownload});
  final ChatMessage message;
  final void Function(FileMessage) onSave;
  final void Function(FileMessage) onDownload;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Glass(
            opacity: message.mine ? 0.16 : 0.08,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  switch (message) {
                TextMessage(text: final text) => SelectableText(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.3),
                  ),
                FileMessage f => Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.insert_drive_file, color: Colors.white70, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(f.name, style: const TextStyle(color: Colors.white, fontSize: 15.5)),
                            const SizedBox(height: 2),
                            Text(
                              f.savedPath != null
                                  ? '${_formatSize(f.size)} · saved to ${f.savedPath}'
                                  : _formatSize(f.size),
                              style: const TextStyle(color: _muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (!f.mine && f.savedPath == null) ...[
                        const SizedBox(width: 4),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: f.requested
                              ? const Padding(
                                  key: ValueKey('spinner'),
                                  padding: EdgeInsets.all(6),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                                  ),
                                )
                              : IconButton(
                                  key: ValueKey(f.bytes == null ? 'download' : 'save'),
                                  tooltip: f.bytes == null ? 'Download' : 'Save',
                                  icon: Icon(
                                    f.bytes == null ? Icons.download : Icons.save_alt,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                  onPressed: () => f.bytes == null ? onDownload(f) : onSave(f),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                ),
                        ),
                      ],
                    ],
                  ),
                  },
                  const SizedBox(height: 4),
                  Text(_formatTime(message.time), style: const TextStyle(color: _muted, fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
