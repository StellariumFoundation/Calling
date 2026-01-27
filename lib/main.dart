import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// FIX: Import path as an alias 'p' to avoid conflict with BuildContext
import 'package:path/path.dart' as p; 
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CallCenterApp());
}

class CallCenterApp extends StatelessWidget {
  const CallCenterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Call Center Auto',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const CallCenterHome(),
    );
  }
}

// Model for our Phone Number
class PhoneNumberModel {
  final int? id;
  final String number;
  final bool wasCalled;

  PhoneNumberModel({this.id, required this.number, this.wasCalled = false});

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'number': number,
      'wasCalled': wasCalled ? 1 : 0,
    };
  }

  factory PhoneNumberModel.fromMap(Map<String, dynamic> map) {
    return PhoneNumberModel(
      id: map['id'],
      number: map['number'],
      wasCalled: map['wasCalled'] == 1,
    );
  }
}

// Database Helper
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('callcenter.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    // FIX: Use p.join because we aliased the import
    final path = p.join(dbPath, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE numbers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT UNIQUE,
      wasCalled INTEGER NOT NULL
    )
    ''');
  }

  Future<void> insertNumber(String number) async {
    final db = await instance.database;
    // Insert or Ignore to avoid duplicates crashing the app
    await db.rawInsert(
      'INSERT OR IGNORE INTO numbers(number, wasCalled) VALUES(?, ?)',
      [number, 0],
    );
  }

  Future<List<PhoneNumberModel>> getAllNumbers() async {
    final db = await instance.database;
    final result = await db.query('numbers');
    return result.map((json) => PhoneNumberModel.fromMap(json)).toList();
  }

  Future<PhoneNumberModel?> getNextNumberToCall() async {
    final db = await instance.database;
    final result = await db.query(
      'numbers',
      where: 'wasCalled = ?',
      whereArgs: [0],
      limit: 1,
    );
    if (result.isNotEmpty) {
      return PhoneNumberModel.fromMap(result.first);
    }
    return null;
  }

  Future<void> markAsCalled(int id) async {
    final db = await instance.database;
    await db.update(
      'numbers',
      {'wasCalled': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> resetRotation() async {
    final db = await instance.database;
    await db.update('numbers', {'wasCalled': 0});
  }

  Future<Map<String, int>> getStats() async {
    final db = await instance.database;
    final total = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM numbers'));
    final called = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM numbers WHERE wasCalled = 1'));
    return {
      'total': total ?? 0,
      'called': called ?? 0,
      'remaining': (total ?? 0) - (called ?? 0),
    };
  }
}

class CallCenterHome extends StatefulWidget {
  const CallCenterHome({super.key});

  @override
  State<CallCenterHome> createState() => _CallCenterHomeState();
}

class _CallCenterHomeState extends State<CallCenterHome> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  // State
  List<PhoneNumberModel> _numbers = [];
  Map<String, int> _stats = {'total': 0, 'called': 0, 'remaining': 0};
  String? _lastCalledNumber;
  int? _currentProcessingId; // ID of the number currently being called
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    super.dispose();
  }

  // Detect when user returns to app to update status
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _currentProcessingId != null) {
      // User returned from the dialer
      _finalizeCall();
    }
  }

  Future<void> _refreshData() async {
    final nums = await _db.getAllNumbers();
    final stats = await _db.getStats();
    setState(() {
      _numbers = nums;
      _stats = stats;
    });
  }

  Future<void> _finalizeCall() async {
    if (_currentProcessingId != null) {
      await _db.markAsCalled(_currentProcessingId!);
      setState(() {
        _currentProcessingId = null;
      });
      await _refreshData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Call ended. Database updated.')),
        );
      }
    }
  }

  // 1. Parse Logic
  Future<void> _parseAndAdd() async {
    if (_textController.text.isEmpty) return;

    setState(() => _isLoading = true);

    String rawText = _textController.text;
    
    // Regex to find sequences of digits (at least 8) allowing for formatting chars
    RegExp exp = RegExp(r'[\d\+\-\(\)\s]{8,}');
    Iterable<RegExpMatch> matches = exp.allMatches(rawText);

    int addedCount = 0;

    for (final match in matches) {
      String candidate = match.group(0)!.trim();
      
      // --- NINTH DIGIT FIX LOGIC START ---
      // Remove everything that is not a digit to analyze length
      String cleanDigits = candidate.replaceAll(RegExp(r'\D'), '');
      
      // Case 1: User typed DDD + Number (e.g., 6188377338) - Total 10 digits
      // In Brazil, Landlines start with 2-5, Mobiles start with 6-9 (historically).
      if (cleanDigits.length == 10) {
        int firstDigit = int.parse(cleanDigits.substring(2, 3));
        if (firstDigit >= 6) {
          // It's a mobile missing the 9. Inject it.
          // Turns 6188377338 -> 61988377338
          candidate = '${cleanDigits.substring(0, 2)}9${cleanDigits.substring(2)}';
        }
      } 
      // Case 2: User typed 55 + DDD + Number (e.g., 556188377338) - Total 12 digits
      else if (cleanDigits.length == 12 && cleanDigits.startsWith('55')) {
         int firstDigit = int.parse(cleanDigits.substring(4, 5));
         if (firstDigit >= 6) {
           // Insert 9 after DDD
           candidate = '${cleanDigits.substring(0, 4)}9${cleanDigits.substring(4)}';
         }
      }
      // --- NINTH DIGIT FIX LOGIC END ---

      try {
        final parsed = PhoneNumber.parse(candidate, destinationCountry: IsoCode.BR);
        
        if (parsed.isValid()) {
          // This will now output +5561988377338 due to the fix above
          String international = '+${parsed.countryCode}${parsed.nsn}'; 
          
          await _db.insertNumber(international);
          addedCount++;
        } else {
          debugPrint("Invalid number: $candidate");
        }
      } catch (e) {
        debugPrint("Parse error: $e");
      }
    }

    _textController.clear();
    await _refreshData();
    setState(() => _isLoading = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $addedCount valid numbers to database.')),
      );
    }
  }

  // 2. Call Logic
  Future<void> _makeCall({String? specificNumber}) async {
    PhoneNumberModel? target;

    if (specificNumber != null) {
      // Re-calling specific number
      target = PhoneNumberModel(number: specificNumber); 
      // We don't track ID here because "Call Again" doesn't change database status 
      // (it was likely already marked called).
    } else {
      // Get next from DB
      target = await _db.getNextNumberToCall();

      if (target == null) {
        // Rotation Logic
        if (_stats['total']! > 0 && _stats['remaining'] == 0) {
           bool confirm = await showDialog(
             context: context, 
             builder: (c) => AlertDialog(
               title: const Text("Rotation"),
               content: const Text("All numbers called. Restart rotation?"),
               actions: [
                 TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("No")),
                 TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Yes")),
               ],
             )) ?? false;
           
           if (confirm) {
             await _db.resetRotation();
             await _refreshData();
             _makeCall(); // Recursive call to start new batch
             return;
           } else {
             return;
           }
        } else {
           if(mounted) {
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Database empty.")));
           }
           return;
        }
      }
      
      // Setup state to mark as called when returning
      setState(() {
        _currentProcessingId = target!.id;
      });
    }

    setState(() {
      _lastCalledNumber = target!.number;
    });

    final Uri launchUri = Uri(
      scheme: 'tel',
      path: target.number,
    );

    try {
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
        // Note: Actual DB update happens in didChangeAppLifecycleState
      } else {
         throw 'Could not launch $launchUri';
      }
    } catch (e) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error launching call: $e")));
      }
      // Reset state if launch fails
      setState(() {
        _currentProcessingId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto Call Center'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Status Bar
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem("Total", "${_stats['total']}"),
                _buildStatItem("Called", "${_stats['called']}", color: Colors.green),
                _buildStatItem("Remaining", "${_stats['remaining']}", color: Colors.orange),
              ],
            ),
          ),
          
          // Input Area
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _textController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Paste text with numbers here (e.g., "Bob: 11 99999-9999")',
                    labelText: 'Import Numbers',
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _parseAndAdd,
                  icon: const Icon(Icons.download),
                  label: const Text('Extract & Save Numbers'),
                ),
              ],
            ),
          ),

          const Divider(),

          // Central Action Area
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        shape: const CircleBorder(),
                        backgroundColor: _stats['remaining'] == 0 && _stats['total']! > 0 
                            ? Colors.orange 
                            : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _makeCall(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _stats['remaining'] == 0 && _stats['total']! > 0 
                              ? Icons.refresh 
                              : Icons.call, 
                            size: 50
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _stats['remaining'] == 0 && _stats['total']! > 0 
                              ? "Rotate / Reset"
                              : "CALL NEXT",
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _lastCalledNumber == null 
                        ? null 
                        : () => _makeCall(specificNumber: _lastCalledNumber),
                    icon: const Icon(Icons.replay),
                    label: Text(_lastCalledNumber == null 
                        ? "No recent call" 
                        : "Call Again ($_lastCalledNumber)"),
                  )
                ],
              ),
            ),
          ),

          // Database Preview (Mini list)
          const Padding(
            padding: EdgeInsets.only(left: 16.0, top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("Database Preview:", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            flex: 1,
            child: ListView.builder(
              itemCount: _numbers.length,
              itemBuilder: (context, index) {
                final item = _numbers[index];
                return ListTile(
                  leading: Icon(
                    item.wasCalled ? Icons.check_circle : Icons.circle_outlined,
                    color: item.wasCalled ? Colors.green : Colors.grey,
                  ),
                  title: Text(item.number),
                  trailing: IconButton(
                    icon: const Icon(Icons.call, size: 20),
                    onPressed: () => _makeCall(specificNumber: item.number),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}