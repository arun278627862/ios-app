import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:io';

void main() {
  runApp(const OTSMobileApp());
}

class OTSMobileApp extends StatelessWidget {
  const OTSMobileApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OTS Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F172A)), // Slate 900
        useMaterial3: true,
      ),
      home: const SetupScreen(),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({Key? key}) : super(key: key);

  @override
  _SetupScreenState createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _serverController = TextEditingController(text: '192.168.1.100:3006');
  final _empIdController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isLoading = false;
  bool _isScanning = false;
  bool _isValidated = false;
  
  List<dynamic> _orgStructure = [];
  String? _selectedDept;
  String? _selectedLine;
  List<String> _availableLines = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _autoDiscover();
  }

  Future<void> _autoDiscover() async {
    // We will do a quick background UDP check just in case, but rely on the scan button for fallback.
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.send("DISCOVER_SERVER_REQUEST".codeUnits, InternetAddress("255.255.255.255"), 8888);
      
      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg != null) {
            final reply = String.fromCharCodes(dg.data);
            if (reply.startsWith("DISCOVER_SERVER_RESPONSE")) {
               if (mounted) {
                 setState(() {
                   _serverController.text = "${dg.address.address}:3006";
                 });
                 _validateServer();
               }
               socket.close();
            }
          }
        }
      });
      Future.delayed(const Duration(seconds: 3), () => socket.close());
    } catch (e) {}
  }

  Future<void> _scanNetworkForServer() async {
    setState(() => _isScanning = true);
    try {
      List<String> myIps = [];
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            myIps.add(addr.address);
          }
        }
      }
      
      if (myIps.isEmpty) {
        _showError("Could not find local Wi-Fi IP.");
        setState(() => _isScanning = false);
        return;
      }

      String myIp = myIps.first; 
      // Extract the first two blocks (e.g., "172.27" from "172.27.30.45")
      List<String> parts = myIp.split('.');
      String baseSubnet = "${parts[0]}.${parts[1]}";
      
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Wide Scanning: $baseSubnet.X.X... This may take up to 2 minutes."), backgroundColor: Colors.orange));
      
      bool found = false;
      
      // We will scan in chunks to avoid crashing the phone's network stack
      for (int subnet3 = 0; subnet3 <= 255; subnet3++) {
        if (found) break;
        
        List<Future<void>> checks = [];
        for (int i = 1; i <= 254; i++) {
          if (found) break;
          String targetIp = "$baseSubnet.$subnet3.$i";
          
          checks.add(
            http.get(Uri.parse('http://$targetIp:3006/api/org-structure'))
                .timeout(const Duration(milliseconds: 1000)) // Very aggressive timeout
                .then((res) {
              if (res.statusCode == 200 && !found) {
                found = true;
                if (mounted) {
                  setState(() {
                    _serverController.text = "$targetIp:3006";
                  });
                  _validateServer();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Server FOUND at $targetIp!"), backgroundColor: Colors.green));
                }
              }
            }).catchError((e) { /* ignore */ })
          );
        }
        
        // Wait for this chunk of 254 IPs to finish before moving to the next block
        await Future.wait(checks);
      }
      
      if (!found && mounted) {
        _showError("Server not found on the wide network.");
      }
    } catch (e) {
      if (mounted) _showError("Scan failed: $e");
    }
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverController.text = prefs.getString('server_ip') ?? '192.168.1.100:3006';
      _empIdController.text = prefs.getString('emp_id') ?? '';
      _passwordController.text = prefs.getString('password') ?? '';
      _selectedDept = prefs.getString('dept');
      _selectedLine = prefs.getString('line');
    });
  }

  Future<void> _validateServer() async {
    setState(() => _isLoading = true);
    final server = _serverController.text.trim();
    try {
      final response = await http.get(Uri.parse('http://$server/api/org-structure'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _orgStructure = data;
          _isValidated = true;
          // Refresh lines if dept was already selected
          if (_selectedDept != null) {
             final deptObj = _orgStructure.firstWhere((d) => d['department'] == _selectedDept, orElse: () => null);
             if (deptObj != null) {
                _availableLines = List<String>.from(deptObj['lines']);
             } else {
                _selectedDept = null;
                _selectedLine = null;
             }
          }
        });
        _showSuccess('Server validated. Departments loaded.');
      } else {
        _showError('Failed to load structure. Status: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Connection failed: Check Server IP/Port.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _login() async {
    if (_selectedDept == null || _selectedLine == null || _empIdController.text.isEmpty || _passwordController.text.isEmpty) {
       _showError('Please select Department, Line, and enter Employee ID/Password.');
       return;
    }
    
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _serverController.text.trim());
    await prefs.setString('emp_id', _empIdController.text.trim());
    await prefs.setString('password', _passwordController.text);
    await prefs.setString('dept', _selectedDept!);
    await prefs.setString('line', _selectedLine!);

    try {
      final response = await http.post(
        Uri.parse('http://${_serverController.text}/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identifier': _empIdController.text,
          'password': _passwordController.text,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScreen()));
      } else {
        _showError('Login failed: Invalid credentials');
      }
    } catch (e) {
      _showError('Login Error. Check connection.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }
  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  InputDecoration _inputDeco(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFF64748B)),
      prefixIcon: Icon(icon, color: const Color(0xFF64748B)),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9), // Slate 100 for premium feel
      appBar: AppBar(
        title: const Text('OTS Login & Setup', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
        elevation: 0,
        backgroundColor: Colors.transparent,
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _serverController,
                            decoration: _inputDeco('Server IP & Port', Icons.computer),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          height: 56,
                          width: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)]),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(color: const Color(0xFF2563EB).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
                            ],
                          ),
                          child: IconButton(
                            onPressed: _isScanning ? null : _scanNetworkForServer,
                            icon: _isScanning 
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)) 
                              : const Icon(Icons.search, color: Colors.white, size: 28),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _validateServer,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF8FAFC),
                          foregroundColor: const Color(0xFF0F172A),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE2E8F0))),
                        ),
                        child: _isLoading && !_isValidated 
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                          : const Text('Validate Server', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              
              if (_isValidated)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _empIdController,
                        decoration: _inputDeco('Employee ID', Icons.badge),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        decoration: _inputDeco('Password', Icons.lock),
                        obscureText: true,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        decoration: _inputDeco('Department', Icons.business),
                        value: _selectedDept,
                        dropdownColor: Colors.white,
                        items: _orgStructure.map((d) {
                          return DropdownMenuItem<String>(
                            value: d['department'],
                            child: Text(d['department'], style: const TextStyle(fontWeight: FontWeight.w500)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedDept = val;
                            final deptObj = _orgStructure.firstWhere((d) => d['department'] == val);
                            _availableLines = List<String>.from(deptObj['lines']);
                            _selectedLine = null;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        decoration: _inputDeco('Production Line', Icons.precision_manufacturing),
                        value: _selectedLine,
                        dropdownColor: Colors.white,
                        items: _availableLines.map((l) {
                          return DropdownMenuItem<String>(
                            value: l,
                            child: Text(l, style: const TextStyle(fontWeight: FontWeight.w500)),
                          );
                        }).toList(),
                        onChanged: (val) => setState(() => _selectedLine = val),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 56,
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F172A),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 4,
                            shadowColor: const Color(0xFF0F172A).withOpacity(0.4),
                          ),
                          child: _isLoading 
                            ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)) 
                            : const Text('Connect & Login', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                        ),
                      )
                    ],
                  ),
                ),
                
              const SizedBox(height: 20),
              if (_isValidated)
                TextButton.icon(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.clear();
                    setState(() {
                      _empIdController.clear();
                      _passwordController.clear();
                      _selectedDept = null;
                      _selectedLine = null;
                      _isValidated = false;
                    });
                    _showSuccess('App Data Cleared.');
                  },
                  icon: const Icon(Icons.cleaning_services, color: Color(0xFFEF4444)),
                  label: const Text('Clear Saved Data', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({Key? key}) : super(key: key);

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  
  final List<Widget> _pages = [
    const DashboardPage(),
    const ScanPage(),
    const WebAppPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        selectedItemColor: const Color(0xFF0F172A),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.qr_code_scanner), label: 'Scan'),
          BottomNavigationBarItem(icon: Icon(Icons.web), label: 'Web View'),
        ],
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({Key? key}) : super(key: key);
  @override
  _DashboardPageState createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String _server = '';
  String _emp = '';
  String _line = '';
  Map<String, dynamic> _summary = {};
  Map<String, dynamic> _totals = {'A': 0, 'G': 0, 'B': 0, 'C': 0};
  int _totalPresent = 0;
  bool _loading = true;

  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    _server = prefs.getString('server_ip') ?? '';
    _emp = prefs.getString('emp_id') ?? '';
    _line = prefs.getString('line') ?? '';
    setState(() {});
    
    _fetchHeadcounts();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0F172A),
              onPrimary: Colors.white,
              onSurface: Color(0xFF0F172A),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
      _fetchHeadcounts();
    }
  }

  Future<void> _fetchHeadcounts() async {
    setState(() => _loading = true);
    try {
      final dateStr = "${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}";
      final response = await http.get(Uri.parse('http://$_server/api/line-summary-by-shift?date=$dateStr'));
      if (response.statusCode == 200) {
         final data = jsonDecode(response.body);
         setState(() {
            _totalPresent = data['totalPresent'] is int ? data['totalPresent'] : (int.tryParse('${data['totalPresent']}') ?? 0);
            if (data['summary'] != null && data['summary'] is Map) {
              _summary = Map<String, dynamic>.from(data['summary']);
            } else if (data['data'] != null && data['data'] is Map) {
              _summary = Map<String, dynamic>.from(data['data']);
            } else {
              _summary = {};
            }
            if (data['totals'] != null && data['totals'] is Map) {
              _totals = Map<String, dynamic>.from(data['totals']);
            } else {
              int a = 0, g = 0, b = 0, c = 0;
              _summary.forEach((_, val) {
                if (val is Map) {
                  a += (val['A'] is int ? val['A'] as int : int.tryParse('${val['A']}') ?? 0);
                  g += (val['G'] is int ? val['G'] as int : int.tryParse('${val['G']}') ?? 0);
                  b += (val['B'] is int ? val['B'] as int : int.tryParse('${val['B']}') ?? 0);
                  c += (val['C'] is int ? val['C'] as int : int.tryParse('${val['C']}') ?? 0);
                }
              });
              _totals = {'A': a, 'G': g, 'B': b, 'C': c};
            }
         });
      }
    } catch(e) {}
    setState(() => _loading = false);
  }

  Widget _buildShiftBox(String shift, dynamic count) {
    int val = 0;
    if (count is int) {
      val = count;
    } else if (count != null) {
      val = int.tryParse('$count') ?? 0;
    }

    Color bgColor;
    Color textColor;
    Color borderColor;

    switch (shift.toUpperCase()) {
      case 'A':
        bgColor = const Color(0xFFE0F2FE); // sky-100
        textColor = const Color(0xFF0C4A6E); // sky-800
        borderColor = const Color(0xFFBAE6FD); // sky-200
        break;
      case 'G':
        bgColor = const Color(0xFFDBEAFE); // blue-100
        textColor = const Color(0xFF1E40AF); // blue-800
        borderColor = const Color(0xFF93C5FD); // blue-300
        break;
      case 'B':
        bgColor = const Color(0xFFDCFCE7); // green-100
        textColor = const Color(0xFF166534); // green-800
        borderColor = const Color(0xFFBBF7D0); // green-200
        break;
      case 'C':
        bgColor = const Color(0xFFFFEDD5); // orange-100
        textColor = const Color(0xFF9A3412); // orange-800
        borderColor = const Color(0xFFFED7AA); // orange-200
        break;
      default:
        bgColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF334155);
        borderColor = const Color(0xFFCBD5E1);
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 44),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Center(
        child: Text(
          '$val',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryTable() {
    final sortedLineNames = _summary.keys.toList()..sort();
    final dateDisplay = "${_selectedDate.day.toString().padLeft(2, '0')}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.year}";

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      'Total Present: ',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                    ),
                    Text(
                      '$_totalPresent',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2563EB)),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.calendar_today_outlined, size: 12, color: Color(0xFF64748B)),
                      const SizedBox(width: 4),
                      Text(dateDisplay, style: const TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 350),
              child: DataTable(
                headingRowColor: MaterialStateProperty.all(const Color(0xFFF8FAFC)),
                headingTextStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Color(0xFF2563EB),
                  letterSpacing: 0.5,
                ),
                dataRowMinHeight: 44,
                dataRowMaxHeight: 52,
                columnSpacing: 14,
                horizontalMargin: 12,
                dividerThickness: 1,
                border: const TableBorder(
                  top: BorderSide(color: Color(0xFFBFDBFE), width: 1.5),
                  bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
                  horizontalInside: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                ),
                columns: const [
                  DataColumn(label: Text('LINE')),
                  DataColumn(label: Center(child: Text('SHIFT A'))),
                  DataColumn(label: Center(child: Text('SHIFT G'))),
                  DataColumn(label: Center(child: Text('SHIFT B'))),
                  DataColumn(label: Center(child: Text('SHIFT C'))),
                ],
                rows: [
                  DataRow(
                    color: MaterialStateProperty.resolveWith<Color?>((states) => const Color(0xFFF1F5F9)),
                    cells: [
                      const DataCell(
                        Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0F172A))),
                      ),
                      DataCell(Center(child: _buildShiftBox('A', _totals['A']))),
                      DataCell(Center(child: _buildShiftBox('G', _totals['G']))),
                      DataCell(Center(child: _buildShiftBox('B', _totals['B']))),
                      DataCell(Center(child: _buildShiftBox('C', _totals['C']))),
                    ],
                  ),
                  ...sortedLineNames.map((lineName) {
                    final lineCounts = _summary[lineName] as Map<String, dynamic>? ?? {};
                    final isMyLine = lineName.toString().trim().toLowerCase() == _line.trim().toLowerCase();

                    return DataRow(
                      color: MaterialStateProperty.resolveWith<Color?>(
                        (states) => isMyLine ? const Color(0xFFEFF6FF) : Colors.white,
                      ),
                      cells: [
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                lineName,
                                style: TextStyle(
                                  fontWeight: isMyLine ? FontWeight.w800 : FontWeight.w600,
                                  fontSize: 12,
                                  color: isMyLine ? const Color(0xFF1D4ED8) : const Color(0xFF1E293B),
                                ),
                              ),
                              if (isMyLine) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.check_circle, size: 14, color: Color(0xFF2563EB)),
                              ],
                            ],
                          ),
                        ),
                        DataCell(Center(child: _buildShiftBox('A', lineCounts['A']))),
                        DataCell(Center(child: _buildShiftBox('G', lineCounts['G']))),
                        DataCell(Center(child: _buildShiftBox('B', lineCounts['B']))),
                        DataCell(Center(child: _buildShiftBox('C', lineCounts['C']))),
                      ],
                    );
                  }).toList(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('OTS Dashboard', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month, color: Color(0xFF2563EB)),
            onPressed: () => _selectDate(context),
            tooltip: 'Change Date',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF0F172A)),
            onPressed: _fetchHeadcounts,
            tooltip: 'Refresh Summary',
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Color(0xFFE11D48)),
            onPressed: () async {
              // Removed prefs.clear() to keep data on logout
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (context) => const SetupScreen()),
                );
              }
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _loading 
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _fetchHeadcounts,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              children: [
                Card(
                  color: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Active Session', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold, fontSize: 11)),
                        const SizedBox(height: 3),
                        Text('Recorder: $_emp', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                        Text('Primary Line: $_line', style: const TextStyle(fontSize: 13, color: Color(0xFF475569))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Line Summary', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
                const SizedBox(height: 10),
                if (_summary.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: const Center(
                      child: Text(
                        "No data found for today.",
                        style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                      ),
                    ),
                  )
                else
                  _buildSummaryTable(),
                const SizedBox(height: 24),
              ],
            ),
          ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({Key? key}) : super(key: key);
  @override
  _ScanPageState createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _isProcessing = false;
  Map<String, dynamic>? _lastScanResult;
  int _currentLineCount = 0;
  Map<String, int> _shiftCounts = {'A': 0, 'G': 0, 'B': 0, 'C': 0};
  String _line = '';
  String _server = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    _server = prefs.getString('server_ip') ?? '';
    _line = prefs.getString('line') ?? '';
    if (mounted) setState(() {});
    _fetchLineCount();
  }

  Future<void> _fetchLineCount() async {
    if (_server.isEmpty || _line.isEmpty) return;
    try {
      final now = DateTime.now();
      final dateStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final response = await http.get(Uri.parse('http://$_server/api/line-summary-by-shift?date=$dateStr'));
      if (response.statusCode == 200) {
         final data = jsonDecode(response.body);
         Map<String, dynamic> summary = {};
         if (data['summary'] != null && data['summary'] is Map) {
           summary = Map<String, dynamic>.from(data['summary']);
         } else if (data['data'] != null && data['data'] is Map) {
           summary = Map<String, dynamic>.from(data['data']);
         }
         
         int count = 0;
         Map<String, int> shifts = {'A': 0, 'G': 0, 'B': 0, 'C': 0};
         
         String targetLineLower = _line.trim().toLowerCase();
         String actualKey = _line;
         for (String key in summary.keys) {
           if (key.trim().toLowerCase() == targetLineLower) {
             actualKey = key;
             break;
           }
         }
         
         final lineCounts = summary[actualKey] as Map<String, dynamic>? ?? {};
         lineCounts.forEach((shift, val) {
            int v = (val is int ? val : int.tryParse('$val') ?? 0);
            count += v;
            shifts[shift] = v;
         });
         
         if (mounted) setState(() { 
           _currentLineCount = count; 
           _shiftCounts = shifts;
         });
      }
    } catch(e) {}
  }

  void _onDetect(BarcodeCapture capture, BuildContext context) async {
    if (_isProcessing) return;
    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final code = barcodes.first.rawValue;
      if (code != null) {
        setState(() => _isProcessing = true);
        
        final prefs = await SharedPreferences.getInstance();
        final server = prefs.getString('server_ip');
        final line = prefs.getString('line');
        final recorder = prefs.getString('emp_id');
        
        try {
          final response = await http.post(
             Uri.parse('http://$server/api/attendance'),
             headers: {'Content-Type': 'application/json'},
             body: jsonEncode({'empNo': code, 'line': line, 'recorder': recorder}),
          );
          
          final data = jsonDecode(response.body);
          setState(() {
             _lastScanResult = data;
          });
          if (data['success'] == true) {
             _fetchLineCount();
          }
          
        } catch(e) {
          setState(() {
             _lastScanResult = {'success': false, 'message': 'Network error'};
          });
        }
        
        // Wait before allowing next scan
        await Future.delayed(const Duration(seconds: 2));
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: () async {
              // Removed prefs.clear() to keep data on logout
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (context) => const SetupScreen()),
                );
              }
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) => _onDetect(capture, context),
          ),
          
          // Line Count Header Overlay
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("CURRENT LINE", style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                      Text(_line.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text("SHIFTS", style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                      Text('A:${_shiftCounts['A']}  G:${_shiftCounts['G']}  B:${_shiftCounts['B']}  C:${_shiftCounts['C']}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text("TOTAL", style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                      Text('$_currentLineCount', style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.w900)),
                    ],
                  )
                ],
              ),
            ),
          ),

          // Scanner Overlay bounding box
          Center(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                border: Border.all(color: _isProcessing ? Colors.orange : Colors.blueAccent, width: 4),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          
          // Result overlay
          if (_lastScanResult != null)
            Align(
              alignment: Alignment.center,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                child: _buildResultCard(),
              ),
            ),
          if (_isProcessing && _lastScanResult == null)
            const Center(child: CircularProgressIndicator(color: Colors.white))
        ],
      ),
    );
  }
  
  Widget _buildResultCard() {
    bool isSuccess = _lastScanResult!['success'] == true;
    bool isDuplicate = _lastScanResult!['isDuplicate'] == true;
    bool isOut = _lastScanResult!['isOutEntry'] == true;
    bool isTransfer = _lastScanResult!['isTransfer'] == true;
    bool isLineMismatch = _lastScanResult!['isLineMismatch'] == true;
    
    Color cardColor = Colors.green;
    String statusLabel = "IN RECORDED";
    
    if (!isSuccess) {
      if (isDuplicate) {
         cardColor = const Color(0xFFEA580C); // Dark orange
         statusLabel = "ALREADY RECORDED!";
      } else {
         cardColor = Colors.red;
         statusLabel = "ERROR";
      }
    } else {
      if (isLineMismatch) {
         cardColor = Colors.amber.shade700;
         statusLabel = "LINE MISMATCH";
      } else if (isOut) {
         cardColor = Colors.purple;
         statusLabel = "OUT RECORDED";
      } else if (isTransfer) {
         cardColor = Colors.blue;
         statusLabel = "TRANSFER";
      }
    }
    
    String empName = "Unknown";
    if (_lastScanResult!['employee'] != null) {
       empName = _lastScanResult!['employee']['name'] ?? "Unknown";
    }

    return Card(
      elevation: 12,
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(isDuplicate ? 24.0 : 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isSuccess && !isDuplicate) const Icon(Icons.check_circle, color: Colors.white, size: 28)
                else if (isDuplicate) const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 36)
                else const Icon(Icons.error, color: Colors.white, size: 28),
                const SizedBox(width: 8),
                Text(statusLabel, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: isDuplicate ? 20 : 16)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              empName, 
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white, 
                fontSize: isDuplicate ? 32 : 24, 
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2
              )
            ),
            const SizedBox(height: 8),
            Text(
              _lastScanResult!['message'] ?? '', 
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: isDuplicate ? 16 : 14, fontWeight: FontWeight.w500)
            ),
          ],
        ),
      ),
    );
  }
}

class WebAppPage extends StatefulWidget {
  const WebAppPage({Key? key}) : super(key: key);
  @override
  _WebAppPageState createState() => _WebAppPageState();
}

class _WebAppPageState extends State<WebAppPage> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _initWeb();
  }
  
  Future<void> _initWeb() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server_ip') ?? '127.0.0.1:3006';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
      ..loadRequest(Uri.parse('http://$server'));
    setState((){});
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      appBar: AppBar(title: const Text('OTS Web View'), backgroundColor: Colors.white),
      body: WebViewWidget(controller: _controller!),
    );
  }
}
