import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _ink = Color(0xFF0A1020);
const _panel = Color(0xFF121B30);
const _panel2 = Color(0xFF19243A);
const _mint = Color(0xFFB7F36B);
const _coral = Color(0xFFFF795C);
const _soft = Color(0xFF9AA8BF);
const _sensorChannel = MethodChannel('tiltdrive/sensors');
const _sensorEvents = EventChannel('tiltdrive/sensor_events');

void main() => runApp(const TiltDriveApp());

class TiltDriveApp extends StatelessWidget {
  const TiltDriveApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'TiltDrive Controller',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _mint,
        brightness: Brightness.dark,
      ),
      fontFamily: 'sans-serif',
    ),
    home: const ControllerPage(),
  );
}

class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  final _host = TextEditingController();
  final _room = TextEditingController();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<dynamic>? _sensorSub;
  Timer? _inputTimer;
  Timer? _reconnectTimer;
  String _status = 'Ready when you are';
  String _detail = 'Enter the laptop address and room code';
  String _role = 'controller';
  int? _latency;
  bool _wantConnection = false;
  bool _connecting = false;
  bool _sensorsReady = false;
  bool _jump = false;
  bool _manualSteerLeft = false;
  bool _manualSteerRight = false;
  double _roll = 0;
  double _pitch = 0;
  double _gyro = 0;
  double _centerRoll = 0;
  double _centerPitch = 0;
  double _lastAcceleration = 9.8;
  int _lastJumpAt = 0;
  int _controlSequence = 0;

  bool get _connected => _status == 'Connected' || _status == 'In the game';

  @override
  void initState() {
    super.initState();
    _inputTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _sendInput(),
    );
  }

  @override
  void dispose() {
    _wantConnection = false;
    _inputTimer?.cancel();
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _sensorSub?.cancel();
    _socket?.close();
    _host.dispose();
    _room.dispose();
    _sensorChannel.invokeMethod<void>('stop');
    super.dispose();
  }

  Future<void> _link() async {
    final host = _host.text.trim();
    final room = _room.text.trim();
    if (host.isEmpty || room.length != 5) {
      _notify('Enter the laptop IP address and its 5-digit room code.');
      return;
    }
    _wantConnection = true;
    await _startSensors();
    await _openSocket();
  }

  Future<void> _startSensors() async {
    try {
      final result = await _sensorChannel.invokeMapMethod<String, dynamic>(
        'start',
      );
      _sensorsReady = result?['rotation'] == true;
      _sensorSub ??= _sensorEvents.receiveBroadcastStream().listen(
        _onSensor,
        onError: (_) {
          if (mounted) setState(() => _sensorsReady = false);
        },
      );
      if (mounted) setState(() {});
    } on PlatformException catch (e) {
      _setStatus(
        'Sensors unavailable',
        e.message ?? 'Use the on-screen controls instead',
      );
    }
  }

  void _onSensor(dynamic raw) {
    if (raw is! Map) return;
    final data = Map<String, dynamic>.from(raw);
    final roll = (data['roll'] as num?)?.toDouble();
    final pitch = (data['pitch'] as num?)?.toDouble();
    final gyro = (data['gyro'] as num?)?.toDouble();
    final acceleration = (data['accel'] as num?)?.toDouble();
    if (roll == null || pitch == null) return;
    _roll = roll;
    _pitch = pitch;
    if (gyro != null) _gyro = gyro;
    if (acceleration != null) {
      final jolt = (acceleration - _lastAcceleration).abs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (jolt > 12 && now - _lastJumpAt > 900 && _connected) {
        _lastJumpAt = now;
        _triggerJump();
      }
      _lastAcceleration = _lastAcceleration * .72 + acceleration * .28;
    }
    if (mounted) setState(() {});
  }

  void _triggerJump() {
    HapticFeedback.lightImpact();
    setState(() => _jump = true);
    Future<void>.delayed(const Duration(milliseconds: 170), () {
      if (mounted) setState(() => _jump = false);
    });
  }

  Future<void> _openSocket() async {
    if (!_wantConnection || _connecting || _socket != null) return;
    _connecting = true;
    _setStatus('Connecting…', 'Finding the game on your laptop');
    try {
      final host = _host.text.trim();
      final socket = await WebSocket.connect('ws://$host:8765')
          .timeout(const Duration(seconds: 5));
      if (!_wantConnection) {
        await socket.close();
        return;
      }
      socket.pingInterval = const Duration(seconds: 15);
      _socket = socket;
      socket.add(
        jsonEncode({
          'type': 'join',
          'role': 'controller',
          'room': _room.text.trim(),
        }),
      );
      _socketSub = socket.listen(
        _onSocketMessage,
        onDone: _socketClosed,
        onError: (_) => _socketClosed(),
      );
      _setStatus('Connected', 'Tilt, tap, or shake. The game is listening.');
    } catch (_) {
      _setStatus('Reconnecting…', 'Check the laptop IP, room code, and Wi-Fi');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onSocketMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (message['type']) {
        case 'joined':
          _role = message['role']?.toString() ?? 'controller';
          _setStatus('Connected', 'Room ${message['room']} · sensors are live');
          break;
        case 'game_started':
          _setStatus('In the game', 'Easy does it. Tilt to steer.');
          break;
        case 'game_waiting':
          _setStatus('Connected', 'Waiting for the laptop game to start');
          break;
        case 'pong':
          final sent = message['sentAt'];
          if (sent is int && mounted)
            setState(
              () => _latency = DateTime.now().millisecondsSinceEpoch - sent,
            );
          break;
        case 'error':
          _wantConnection = false;
          _socket?.close();
          _socket = null;
          _setStatus(
            'Room not found',
            message['message']?.toString() ?? 'Check the code on the laptop',
          );
          break;
      }
    } catch (_) {
      // Ignore malformed messages; the room stays connected.
    }
  }

  void _sendInput() {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    final x = ((_roll - _centerRoll) / 28).clamp(-1.0, 1.0);
    final y = ((_pitch - _centerPitch) / 28).clamp(-1.0, 1.0);
    _controlSequence++;
    socket.add(
      jsonEncode({
        'type': 'input',
        'role': 'controller',
        'room': _room.text.trim(),
        'seq': _controlSequence,
        'tiltX': _manualSteerLeft ? -1.0 : (_manualSteerRight ? 1.0 : x),
        'tiltY': y,
        'jump': _jump,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    if (_controlSequence % 45 == 0) {
      socket.add(
        jsonEncode({
          'type': 'ping',
          'sentAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    }
  }

  void _socketClosed() {
    _socketSub = null;
    _socket = null;
    if (!_wantConnection || !mounted) return;
    _setStatus(
      'Reconnecting…',
      'Connection dropped. Trying again automatically.',
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (!_wantConnection) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), _openSocket);
  }

  Future<void> _disconnect() async {
    _wantConnection = false;
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    await _socket?.close();
    _socket = null;
    _socketSub = null;
    _setStatus('Ready when you are', 'Enter the laptop address and room code');
  }

  void _setStatus(String status, String detail) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _detail = detail;
    });
  }

  void _notify(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );

  void _calibrate() {
    _centerRoll = _roll;
    _centerPitch = _pitch;
    HapticFeedback.selectionClick();
    _notify('Neutral set. Hold the phone how you want to steer.');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned(top: -160, right: -130, child: _Glow()),
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 34),
                  sliver: SliverList.list(
                    children: [
                      _topbar(),
                      const SizedBox(height: 32),
                      Text(
                        _connected
                            ? 'You’re on\nthe starting grid.'
                            : 'Your phone is\nthe steering wheel.',
                        style: const TextStyle(
                          fontSize: 37,
                          fontWeight: FontWeight.w800,
                          height: 1.04,
                          letterSpacing: -1.8,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Lean to carve. Shake to jump. Make the laptop earn its keep.',
                        style: TextStyle(
                          color: _soft.withValues(alpha: .88),
                          fontSize: 14,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _statusCard(),
                      const SizedBox(height: 14),
                      if (!_connected) _pairCard() else _controllerCard(size),
                      const SizedBox(height: 15),
                      _howItWorks(),
                      const SizedBox(height: 12),
                      _bottomNote(),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _topbar() => Row(
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: _mint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.sports_esports_rounded, color: _ink, size: 21),
      ),
      const SizedBox(width: 11),
      const Text(
        'TILT',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 2.3,
        ),
      ),
      Text(
        'DRIVE',
        style: TextStyle(
          color: _mint,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 2.3,
        ),
      ),
      const Spacer(),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF172237),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: _connected ? _mint : _coral,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              _connected ? 'LINKED' : 'OFFLINE',
              style: const TextStyle(
                fontSize: 9,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _statusCard() => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF26334A)),
    ),
    child: Row(
      children: [
        Container(
          width: 43,
          height: 43,
          decoration: BoxDecoration(
            color: _connected
                ? const Color(0xFF273B30)
                : const Color(0xFF382A31),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            _connected ? Icons.bolt_rounded : Icons.link_rounded,
            color: _connected ? _mint : _coral,
            size: 21,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _status,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, height: 1.4, color: _soft),
              ),
            ],
          ),
        ),
        if (_latency != null)
          Column(
            children: [
              Text(
                '${_latency}ms',
                style: TextStyle(
                  color: (_latency ?? 999) < 100 ? _mint : _coral,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                'PING',
                style: TextStyle(color: _soft, fontSize: 8, letterSpacing: 1),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _pairCard() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('01 / PAIR UP'),
        const SizedBox(height: 7),
        const Text(
          'Meet your laptop.',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        const SizedBox(height: 6),
        const Text(
          'Put both devices on the same Wi-Fi, then enter the details shown in the laptop game.',
          style: TextStyle(color: _soft, fontSize: 11, height: 1.5),
        ),
        const SizedBox(height: 16),
        _input(
          _host,
          'Laptop IP address',
          'e.g. 192.168.1.12',
          keyboard: TextInputType.url,
        ),
        const SizedBox(height: 10),
        _input(
          _room,
          '5-digit room code',
          'e.g. 48219',
          keyboard: TextInputType.number,
          maxLength: 5,
        ),
        const SizedBox(height: 13),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _link,
            icon: const Icon(Icons.rocket_launch_rounded, size: 17),
            label: const Text('LINK PHONE TO GAME'),
            style: FilledButton.styleFrom(
              backgroundColor: _mint,
              foregroundColor: _ink,
              padding: const EdgeInsets.symmetric(vertical: 15),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
        const SizedBox(height: 9),
        Center(
          child: Text(
            'Your phone never needs a game controller.',
            style: TextStyle(color: _soft.withValues(alpha: .65), fontSize: 9),
          ),
        ),
      ],
    ),
  );

  Widget _input(
    TextEditingController controller,
    String label,
    String hint, {
    TextInputType keyboard = TextInputType.text,
    int? maxLength,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    maxLength: maxLength,
    textCapitalization: TextCapitalization.none,
    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      counterText: '',
      labelStyle: const TextStyle(color: _soft, fontSize: 11),
      hintStyle: TextStyle(color: _soft.withValues(alpha: .45), fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF0C1527),
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: Color(0xFF2A3850)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: _mint, width: 1.3),
      ),
    ),
  );

  Widget _controllerCard(Size size) => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _label('02 / CONTROLLER LIVE'),
            const Spacer(),
            Icon(
              Icons.sensors_rounded,
              size: 15,
              color: _sensorsReady ? _mint : _coral,
            ),
            const SizedBox(width: 5),
            Text(
              _sensorsReady ? 'MOTION ON' : 'TOUCH MODE',
              style: TextStyle(
                color: _sensorsReady ? _mint : _coral,
                fontSize: 9,
                letterSpacing: .7,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        const Text(
          'Hold it like a wheel.',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 4),
        const Text(
          'Lean left / right to steer · shake to hop over trouble',
          style: TextStyle(color: _soft, fontSize: 10),
        ),
        const SizedBox(height: 14),
        Container(
          height: math.min(size.height * .27, 205),
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF0A1425),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: const Color(0xFF26354B)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Positioned(
                left: 24,
                right: 24,
                child: Divider(color: Color(0xFF26344A), height: 1),
              ),
              const Positioned(
                top: 17,
                bottom: 17,
                child: VerticalDivider(color: Color(0xFF26344A), width: 1),
              ),
              Positioned.fill(child: CustomPaint(painter: _OrbitPainter())),
              Transform.translate(
                offset: Offset(
                  ((_roll - _centerRoll) / 35).clamp(-1, 1) * 68,
                  ((_pitch - _centerPitch) / 35).clamp(-1, 1) * 48,
                ),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _mint,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _mint.withValues(alpha: .35),
                        blurRadius: 18,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: _ink,
                    size: 18,
                  ),
                ),
              ),
              const Positioned(
                bottom: 9,
                child: Text(
                  'TILT LEFT / RIGHT  ·  SHAKE TO HOP',
                  style: TextStyle(
                    color: Color(0xFF66758C),
                    fontSize: 8,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _readout(
                'ROLL',
                '${(_roll - _centerRoll).toStringAsFixed(0)}°',
              ),
            ),
            Expanded(
              child: _readout(
                'PITCH',
                '${(_pitch - _centerPitch).toStringAsFixed(0)}°',
              ),
            ),
            Expanded(child: _readout('GYRO', _gyro.toStringAsFixed(1))),
            Expanded(
              child: _readout(
                'LATENCY',
                _latency == null ? '—' : '${_latency}ms',
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _calibrate,
                icon: const Icon(Icons.center_focus_strong_rounded, size: 15),
                label: const Text('SET NEUTRAL'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _mint,
                  side: const BorderSide(color: Color(0xFF394B3D)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  textStyle: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .7,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _triggerJump,
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                label: const Text('JUMP'),
                style: FilledButton.styleFrom(
                  backgroundColor: _coral,
                  foregroundColor: _ink,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  textStyle: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SteerButton(
                label: '◀ DRIFT',
                onDown: () => setState(() => _manualSteerLeft = true),
                onUp: () => setState(() => _manualSteerLeft = false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SteerButton(
                label: 'DRIFT ▶',
                onDown: () => setState(() => _manualSteerRight = true),
                onUp: () => setState(() => _manualSteerRight = false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _disconnect,
            icon: const Icon(Icons.link_off_rounded, size: 14),
            label: const Text('Disconnect', style: TextStyle(fontSize: 10)),
            style: TextButton.styleFrom(foregroundColor: _soft),
          ),
        ),
      ],
    ),
  );

  Widget _readout(String label, String value) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(color: _soft, fontSize: 8, letterSpacing: 1),
      ),
    ],
  );

  Widget _howItWorks() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('NO MAGIC. JUST MOTION.'),
        const SizedBox(height: 12),
        _step('01', 'Pair', 'Both screens meet in the same 5-digit room.'),
        _step('02', 'Move', 'Phone sensors read tilt and a shake.'),
        _step(
          '03',
          'Play',
          'Tiny control packets fly to the laptop in real time.',
        ),
      ],
    ),
  );

  Widget _step(String number, String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          number,
          style: const TextStyle(
            color: _mint,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 10, color: _soft, height: 1.4),
              children: [
                TextSpan(
                  text: '$title  ',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(text: body),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _bottomNote() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        Icons.vibration_rounded,
        color: _soft.withValues(alpha: .5),
        size: 12,
      ),
      const SizedBox(width: 5),
      Text(
        'Built for humans. Played with a phone.',
        style: TextStyle(color: _soft.withValues(alpha: .55), fontSize: 9),
      ),
    ],
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: _mint,
      fontSize: 9,
      letterSpacing: 1.35,
      fontWeight: FontWeight.w900,
    ),
  );

  Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF26334A)),
    ),
    child: child,
  );
}

class _SteerButton extends StatelessWidget {
  const _SteerButton({
    required this.label,
    required this.onDown,
    required this.onUp,
  });
  final String label;
  final VoidCallback onDown;
  final VoidCallback onUp;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => onDown(),
    onPointerUp: (_) => onUp(),
    onPointerCancel: (_) => onUp(),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        color: _panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF34415A)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          letterSpacing: 1,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );
}

class _OrbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = const Color(0xFF27344A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, 38, paint);
    paint.color = const Color(0xFF1D2A3F);
    canvas.drawCircle(center, 73, paint);
    final dash = Paint()
      ..color = _mint.withValues(alpha: .12)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(12, center.dy),
      Offset(size.width - 12, center.dy),
      dash,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Glow extends StatelessWidget {
  const _Glow();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: 280,
      height: 280,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [_mint.withValues(alpha: .08), Colors.transparent],
        ),
      ),
    ),
  );
}
