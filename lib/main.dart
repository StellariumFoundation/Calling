import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:audio_service/audio_service.dart';
import 'package:phone_state/phone_state.dart';

late MyCallAudioHandler _handler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  _handler = await AudioService.init(
    builder: () => MyCallAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.jv.calling.channel.audio',
      androidNotificationChannelName: 'Call Center Service',
      androidNotificationOngoing: false, 
      androidStopForegroundOnPause: false,
    ),
  );

  runApp(const CallCenterApp());
}

class MyCallAudioHandler extends BaseAudioHandler {
  PhoneStateStatus _currentPhoneStatus = PhoneStateStatus.NOTHING;

  MyCallAudioHandler() {
    PhoneState.stream.listen((event) {
      _currentPhoneStatus = event.status;
      // If a call starts, we should set our state to "paused" so we don't interfere
      // If a call ends, we set it back to "playing" to regain control of the button
      if (_currentPhoneStatus == PhoneStateStatus.NOTHING || _currentPhoneStatus == PhoneStateStatus.CALL_ENDED) {
        _takeControl();
      }
    });

    _takeControl();
  }

  // THIS IS THE KEY: We tell Android we are "playing" so we get the button events
  void _takeControl() {
    playbackState.add(PlaybackState(
      controls: [MediaControl.play, MediaControl.pause],
      systemActions: {MediaAction.play, MediaAction.pause, MediaAction.playPause},
      processingState: AudioProcessingState.ready,
      playing: true, // We lie to the OS and say we are playing to hijack the button
    ));
  }

  @override
  Future<void> play() => _checkAndDial();
  @override
  Future<void> pause() => _checkAndDial();
  
  // Some headsets send 'stop' or 'fastForward' depending on the brand
  @override
  Future<void> stop() => _checkAndDial();

  Future<void> _checkAndDial() async {
    if (_currentPhoneStatus != PhoneStateStatus.NOTHING && 
        _currentPhoneStatus != PhoneStateStatus.CALL_ENDED) {
      return; 
    }
    await _makeBackgroundCall();
  }

  Future<void> _makeBackgroundCall() async {
    if (!await Permission.phone.isGranted) return;

    final dbPath = await getDatabasesPath();
    final database = await openDatabase(p.join(dbPath, 'callcenter.db'));

    final List<Map<String, dynamic>> maps = await database.query(
      'numbers',
      where: 'wasCalled = ?',
      whereArgs: [0],
      limit: 1,
    );

    if (maps.isNotEmpty) {
      final id = maps.first['id'] as int;
      final number = maps.first['number'] as String;

      bool? res = await FlutterPhoneDirectCaller.callNumber(number);
      if (res == true) {
        await database.update('numbers', {'wasCalled': 1}, where: 'id = ?', whereArgs: [id]);
      }
    }
    await database.close();
    
    // After dialing, ensure we still have focus
    _takeControl();
  }
}

// --------------------------------------------------------------------------
// UI (Same as before, no changes needed to UI isolate)
// --------------------------------------------------------------------------
class CallCenterApp extends StatelessWidget {
  const CallCenterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Call Center Auto',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const CallCenterHome(),
    );
  }
}

class PhoneNumberModel {
  final int? id;
  final String number;
  final bool wasCalled;
  PhoneNumberModel({this.id, required this.number, this.wasCalled = false});
  factory PhoneNumberModel.fromMap(Map<String, dynamic> map) => PhoneNumberModel(
    id: map['id'], number: map['number'], wasCalled: map['wasCalled'] == 1,
  );
}

class CallCenterHome extends StatefulWidget {
  const CallCenterHome({super.key});
  @override
  State<CallCenterHome> createState() => _CallCenterHomeState();
}

class _CallCenterHomeState extends State<CallCenterHome> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  List<PhoneNumberModel> _numbers = [];
  Map<String, int> _stats = {'total': 0, 'called': 0, 'remaining': 0};
  PhoneStateStatus _uiPhoneStatus = PhoneStateStatus.NOTHING;
  StreamSubscription? _phoneSub;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _phoneSub = PhoneState.stream.listen((event) {
      if (mounted) setState(() => _uiPhoneStatus = event.status);
    });
    _refreshData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phoneSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshData();
  }

  Future<void> _refreshData() async {
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(p.join(dbPath, 'callcenter.db'), version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE numbers (id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT UNIQUE, wasCalled INTEGER)');
    });
    final List<Map<String, dynamic>> res = await db.query('numbers');
    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM numbers')) ?? 0;
    final called = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM numbers WHERE wasCalled = 1')) ?? 0;
    setState(() {
      _numbers = res.map((m) => PhoneNumberModel.fromMap(m)).toList();
      _stats = {'total': total, 'called': called, 'remaining': total - called};
    });
    await db.close();
  }

  Future<void> _parseAndAdd() async {
    if (_textController.text.isEmpty) return;
    setState(() => _isLoading = true);
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(p.join(dbPath, 'callcenter.db'));
    RegExp exp = RegExp(r'[\d\+\-\(\)\s]{8,}');
    Iterable<RegExpMatch> matches = exp.allMatches(_textController.text);
    for (final match in matches) {
      String candidate = match.group(0)!.trim();
      String cleanDigits = candidate.replaceAll(RegExp(r'\D'), '');
      if (cleanDigits.length == 10 && int.parse(cleanDigits.substring(2, 3)) >= 6) {
          candidate = '${cleanDigits.substring(0, 2)}9${cleanDigits.substring(2)}';
      }
      try {
        final parsed = PhoneNumber.parse(candidate, destinationCountry: IsoCode.BR);
        if (parsed.isValid()) {
          String international = '+${parsed.countryCode}${parsed.nsn}'; 
          await db.insert('numbers', {'number': international, 'wasCalled': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      } catch (_) {}
    }
    _textController.clear();
    await db.close();
    await _refreshData();
    setState(() => _isLoading = false);
  }

  void _manualCall() async {
    if (!await Permission.phone.isGranted) {
      await Permission.phone.request();
      return;
    }
    if (_uiPhoneStatus != PhoneStateStatus.NOTHING && _uiPhoneStatus != PhoneStateStatus.CALL_ENDED) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Already in a call!")));
       return;
    }
    await _handler.play();
    Future.delayed(const Duration(seconds: 1), () => _refreshData());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calling (Headset Enabled)'), centerTitle: true),
      body: Column(
        children: [
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStat("TOTAL", _stats['total']!),
                _buildStat("CALLED", _stats['called']!, color: Colors.green),
                _buildStat("PENDING", _stats['remaining']!, color: Colors.orange),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(15),
            child: TextField(
              controller: _textController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: "Paste numbers here",
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _parseAndAdd),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 180, height: 180,
                    child: ElevatedButton(
                      onPressed: _manualCall,
                      style: ElevatedButton.styleFrom(
                        shape: const CircleBorder(),
                        backgroundColor: _stats['remaining'] == 0 && _stats['total']! > 0 ? Colors.orange : Colors.green,
                        foregroundColor: Colors.white
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_stats['remaining'] == 0 && _stats['total']! > 0 ? Icons.refresh : Icons.call, size: 50),
                          Text(_stats['remaining'] == 0 && _stats['total']! > 0 ? "RESET" : "CALL NEXT", style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text("Status: ${_uiPhoneStatus.name}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _numbers.length,
              itemBuilder: (context, i) => ListTile(
                dense: true,
                leading: Icon(_numbers[i].wasCalled ? Icons.check_circle : Icons.circle_outlined, size: 16, color: _numbers[i].wasCalled ? Colors.green : Colors.grey),
                title: Text(_numbers[i].number),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStat(String label, int val, {Color? color}) {
    return Column(
      children: [
        Text("$val", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}