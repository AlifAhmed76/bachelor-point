import 'dart:io';

void main() {
  Directory('assets/images/food').createSync(recursive: true);
  Directory('assets/images/avatars').createSync(recursive: true);
  File('assets/images/food/.gitkeep').writeAsStringSync('');
  File('assets/images/avatars/.gitkeep').writeAsStringSync('');

  File('pubspec.yaml').writeAsStringSync(r'''
name: bachelor_point
description: Complete Household Mess & Bachelor House Management System.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.4.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.6.1
  firebase_core: ^3.8.0
  firebase_auth: ^5.3.3
  cloud_firestore: ^5.5.0
  firebase_database: ^11.1.6
  shared_preferences: ^2.3.3
  uuid: ^4.5.1
  intl: ^0.19.0
  google_fonts: ^6.2.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/images/food/
    - assets/images/avatars/
''');

  File('lib/main.dart').writeAsStringSync(_fullProductionApp);
  print('Complete Bachelor Point production code injected successfully!');
}

const String _fullProductionApp = r'''
import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef JsonMap = Map<String, dynamic>;
typedef DocSnap = DocumentSnapshot<JsonMap>;
typedef QuerySnap = QuerySnapshot<JsonMap>;
typedef DocRef = DocumentReference<JsonMap>;

enum AppRole {
  owner('owner', 'Owner', 'মেস মালিক'),
  coAdmin('co_admin', 'Co-Admin', 'কো-অ্যাডমিন'),
  manager('manager', 'Manager', 'ম্যানেজার'),
  member('member', 'Member', 'সদস্য'),
  cookingStaff('cooking_staff', 'Cooking Staff', 'বাবুর্চি / খালা');

  const AppRole(this.value, this.labelEn, this.labelBn);
  final String value;
  final String labelEn;
  final String labelBn;

  static AppRole fromString(String? val) => AppRole.values.firstWhere(
        (r) => r.value == val,
        orElse: () => AppRole.member,
      );

  bool get isAdminOrOwner => this == AppRole.owner || this == AppRole.coAdmin;
  bool get isManagement =>
      this == AppRole.owner ||
      this == AppRole.coAdmin ||
      this == AppRole.manager;
  bool get isCookingStaff => this == AppRole.cookingStaff;
}

class AppColors {
  static const Color darkNavy = Color(0xFF0F172A);
  static const Color emeraldPrimary = Color(0xFF059669);
  static const Color emeraldLight = Color(0xFF10B981);
  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color dangerRed = Color(0xFFDC2626);
  static const Color warningAmber = Color(0xFFD97706);
}

class BdtFormatter {
  static final NumberFormat _fmt = NumberFormat('#,##0.00', 'en_US');
  static String formatPaisa(int paisa) {
    final bool neg = paisa < 0;
    return '${neg ? "-" : ""}৳${_fmt.format(paisa.abs() / 100.0)}';
  }

  static int parseTakaToPaisa(String s) {
    final clean = s.replaceAll(',', '').replaceAll('৳', '').trim();
    return ((double.tryParse(clean) ?? 0.0) * 100).round();
  }
}

class DhakaDate {
  static DateTime now() => DateTime.now().toUtc().add(const Duration(hours: 6));
  static String dateId(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  static String periodId(DateTime d) => DateFormat('yyyy-MM').format(d);
}

class MessCalculators {
  static int uniqueApprovedLeaveDays({
    required String memberId,
    required String periodId,
    required List<JsonMap> vacations,
  }) {
    final parts = periodId.split('-');
    final int year = int.tryParse(parts[0]) ?? 2026;
    final int month = parts.length > 1 ? (int.tryParse(parts[1]) ?? 11) : 11;
    final DateTime mStart = DateTime.utc(year, month, 1);
    final DateTime mEnd = DateTime.utc(year, month + 1, 0);
    final Set<String> days = <String>{};

    for (final v in vacations) {
      if (v['memberId'] != memberId || v['status'] != 'approved') continue;
      final DateTime? s = _parseUtc(v['startDate'] as String? ?? '');
      final DateTime? e = _parseUtc(v['endDate'] as String? ?? '');
      if (s == null || e == null || e.isBefore(s)) continue;

      final DateTime effStart = s.isBefore(mStart) ? mStart : s;
      final DateTime effEnd = e.isAfter(mEnd) ? mEnd : e;
      DateTime cur = effStart;
      while (!cur.isAfter(effEnd)) {
        days.add(DhakaDate.dateId(cur));
        cur = cur.add(const Duration(days: 1));
      }
    }
    return days.length;
  }

  static DateTime? _parseUtc(String s) {
    final p = s.split('-');
    if (p.length != 3) return null;
    return DateTime.utc(
      int.tryParse(p[0]) ?? 2026,
      int.tryParse(p[1]) ?? 1,
      int.tryParse(p[2]) ?? 1,
    );
  }

  static ({
    double actualMeals,
    int leaveDays,
    double effectiveMin,
    double calculatedMeals,
    bool minApplied,
  }) calculateMemberMeals({
    required String memberId,
    required String periodId,
    required int defaultMinMeals,
    required List<JsonMap> mealDocs,
    required List<JsonMap> vacationDocs,
  }) {
    final parts = periodId.split('-');
    final int year = int.tryParse(parts[0]) ?? 2026;
    final int month = parts.length > 1 ? (int.tryParse(parts[1]) ?? 11) : 11;
    final int daysInMonth = DateTime(year, month + 1, 0).day;

    double actual = 0.0;
    for (final m in mealDocs) {
      if (m['memberId'] == memberId && m['periodId'] == periodId) {
        actual += (m['totalMeals'] as num?)?.toDouble() ?? 0.0;
      }
    }

    final int leaveDays = uniqueApprovedLeaveDays(
      memberId: memberId,
      periodId: periodId,
      vacations: vacationDocs,
    ).clamp(0, daysInMonth);

    double effMin = defaultMinMeals.toDouble();
    if (leaveDays >= 15) {
      effMin = 0.0;
    } else if (leaveDays > 0) {
      final int activeDays = daysInMonth - leaveDays;
      effMin = (((defaultMinMeals * activeDays) / daysInMonth) * 2).round() / 2.0;
    }

    final bool minApplied = actual < effMin;
    return (
      actualMeals: actual,
      leaveDays: leaveDays,
      effectiveMin: effMin,
      calculatedMeals: minApplied ? effMin : actual,
      minApplied: minApplied,
    );
  }
}

final sharedPrefsProvider =
    Provider<SharedPreferences>((_) => throw UnimplementedError());
final authUserProvider =
    StreamProvider<User?>((_) => FirebaseAuth.instance.authStateChanges());
final activeMessIdProvider = StateProvider<String?>((ref) {
  return ref.watch(sharedPrefsProvider).getString('active_mess_id');
});
final isBanglaProvider = StateProvider<bool>((_) => false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 100 * 1024 * 1024,
  );
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: const BachelorPointApp(),
    ),
  );
}

class BachelorPointApp extends ConsumerWidget {
  const BachelorPointApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBn = ref.watch(isBanglaProvider);
    final authAsync = ref.watch(authUserProvider);

    return MaterialApp(
      title: 'Bachelor Point',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.lightBg,
        colorScheme: const ColorScheme.light(
          primary: AppColors.darkNavy,
          secondary: AppColors.emeraldPrimary,
        ),
        textTheme: isBn
            ? GoogleFonts.notoSansBengaliTextTheme()
            : GoogleFonts.interTextTheme(),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.darkNavy,
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.emeraldPrimary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: authAsync.when(
        loading: () => const SplashScreen(),
        error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
        data: (user) {
          if (user == null) return const AuthScreen();
          return const RootRouterHandler();
        },
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.darkNavy,
      body: Center(
        child: CircularProgressIndicator(color: AppColors.emeraldLight),
      ),
    );
  }
}

class RootRouterHandler extends ConsumerWidget {
  const RootRouterHandler({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messId = ref.watch(activeMessIdProvider);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const AuthScreen();
    if (messId == null) return const MessSwitcherScreen();
    return MessWorkspaceShell(messId: messId, currentUser: user);
  }
}

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _isLogin = true;
  bool _loading = false;
  String? _error;
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      final db = FirebaseFirestore.instance;
      if (_isLogin) {
        await auth.signInWithEmailAndPassword(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text,
        );
      } else {
        final cred = await auth.createUserWithEmailAndPassword(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text,
        );
        await cred.user!.updateDisplayName(_nameCtrl.text.trim());
        await db.collection('users').doc(cred.user!.uid).set({
          'uid': cred.user!.uid,
          'fullName': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim(),
          'messIds': <String>[],
          'accountStatus': 'active',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBn = ref.watch(isBanglaProvider);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(Icons.home_work_rounded,
                        size: 46, color: AppColors.emeraldPrimary),
                    TextButton.icon(
                      onPressed: () =>
                          ref.read(isBanglaProvider.notifier).state = !isBn,
                      icon: const Icon(Icons.language),
                      label: Text(isBn ? 'English' : 'বাংলা'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  isBn ? 'ব্যাচেলর পয়েন্ট' : 'Bachelor Point',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800),
                ),
                Text(isBn
                    ? 'স্বচ্ছ মেস এবং ব্যাচেলর হাউস ম্যানেজমেন্ট'
                    : 'Household Mess Management System'),
                const SizedBox(height: 24),
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    color: AppColors.dangerRed.withOpacity(0.1),
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.dangerRed)),
                  ),
                if (!_isLogin) ...[
                  TextField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(
                      labelText: isBn ? 'পূর্ণ নাম' : 'Full Name',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: isBn ? 'ইমেইল ঠিকানা' : 'Email Address',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: isBn ? 'পাসওয়ার্ড' : 'Password',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: Text(_loading
                      ? 'Please wait...'
                      : (_isLogin
                          ? (isBn ? 'লগইন করুন' : 'Log In')
                          : (isBn ? 'অ্যাকাউন্ট খুলুন' : 'Create Account'))),
                ),
                TextButton(
                  onPressed: () => setState(() => _isLogin = !_isLogin),
                  child: Text(_isLogin
                      ? (isBn
                          ? 'নতুন অ্যাকাউন্ট খুলুন'
                          : 'Create a new account')
                      : (isBn ? 'আগের অ্যাকাউন্টে লগইন' : 'Back to Login')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MessSwitcherScreen extends ConsumerStatefulWidget {
  const MessSwitcherScreen({super.key});
  @override
  ConsumerState<MessSwitcherScreen> createState() => _MessSwitcherScreenState();
}

class _MessSwitcherScreenState extends ConsumerState<MessSwitcherScreen> {
  Future<void> _activateMess(String messId) async {
    await ref.read(sharedPrefsProvider).setString('active_mess_id', messId);
    ref.read(activeMessIdProvider.notifier).state = messId;
  }

  Future<void> _createMessDialog() async {
    final nameCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    final minCtrl = TextEditingController(text: '40');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Mess (নতুন মেস তৈরি)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Mess Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: addrCtrl,
              decoration: const InputDecoration(labelText: 'House Address'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: minCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Minimum Monthly Meals (Default 40)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;
              final user = FirebaseAuth.instance.currentUser!;
              final db = FirebaseFirestore.instance;
              final messRef = db.collection('messes').doc();
              final messId = messRef.id;
              final periodId = DhakaDate.periodId(DhakaDate.now());
              final minMeals = int.tryParse(minCtrl.text) ?? 40;

              final batch = db.batch();
              batch.set(messRef, {
                'messId': messId,
                'messName': nameCtrl.text.trim(),
                'address': addrCtrl.text.trim(),
                'createdBy': user.uid,
                'ownerId': user.uid,
                'status': 'active',
                'currency': 'BDT',
                'timezone': 'Asia/Dhaka',
                'minimumMealRule': {
                  'enabled': true,
                  'defaultMinimumMeals': minMeals,
                  'partialLeavePolicy': 'prorated_daily',
                  'fullLeaveExemptionDays': 15,
                },
                'createdAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
              });

              batch.set(messRef.collection('members').doc(user.uid), {
                'userId': user.uid,
                'displayName': user.displayName ?? 'Owner',
                'role': 'owner',
                'membershipStatus': 'active',
                'joinedAt': FieldValue.serverTimestamp(),
                'roleAssignedBy': user.uid,
                'roleAssignedAt': FieldValue.serverTimestamp(),
                'additionalPermissions': <String, bool>{},
              });

              batch.set(messRef.collection('accountingPeriods').doc(periodId), {
                'periodId': periodId,
                'status': 'open',
                'minimumMealsSnapshot': minMeals,
              });

              batch.set(
                db.collection('users').doc(user.uid),
                {
                  'uid': user.uid,
                  'fullName': user.displayName ?? 'Owner',
                  'email': user.email ?? '',
                  'accountStatus': 'active',
                  'messIds': FieldValue.arrayUnion([messId]),
                  'updatedAt': FieldValue.serverTimestamp(),
                },
                SetOptions(merge: true),
              );

              await batch.commit();
              if (ctx.mounted) Navigator.pop(ctx);
              await _activateMess(messId);
            },
            child: const Text('Create Mess'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bachelor Point — My Messes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<DocSnap>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, snap) {
          final messIds =
              List<String>.from(snap.data?.data()?['messIds'] ?? const []);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'Welcome, ${user.displayName ?? user.email}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 16),
                  ...messIds.map(
                    (id) => FutureBuilder<DocSnap>(
                      future: FirebaseFirestore.instance
                          .collection('messes')
                          .doc(id)
                          .get(),
                      builder: (context, mSnap) {
                        final mName =
                            mSnap.data?.data()?['messName'] ?? 'Mess $id';
                        final mAddr = mSnap.data?.data()?['address'] ?? '';
                        return Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: AppColors.darkNavy,
                              child:
                                  Icon(Icons.apartment, color: Colors.white),
                            ),
                            title: Text('$mName',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text('$mAddr'),
                            trailing:
                                const Icon(Icons.arrow_forward_ios, size: 16),
                            onTap: () => _activateMess(id),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _createMessDialog,
                    icon: const Icon(Icons.add_home_work),
                    label: const Text('Create New Mess (নতুন মেস তৈরি করুন)'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class MessWorkspaceShell extends ConsumerStatefulWidget {
  const MessWorkspaceShell({
    super.key,
    required this.messId,
    required this.currentUser,
  });

  final String messId;
  final User currentUser;

  @override
  ConsumerState<MessWorkspaceShell> createState() => _MessWorkspaceShellState();
}

class _MessWorkspaceShellState extends ConsumerState<MessWorkspaceShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocSnap>(
      stream: FirebaseFirestore.instance
          .collection('messes')
          .doc(widget.messId)
          .collection('members')
          .doc(widget.currentUser.uid)
          .snapshots(),
      builder: (context, memberSnap) {
        final memberData = memberSnap.data?.data() ?? <String, dynamic>{};
        final role = AppRole.fromString(memberData['role'] as String?);

        if (role.isCookingStaff) {
          return CookingStaffModeView(messId: widget.messId);
        }

        final pages = [
          HomeDashboardTab(
              messId: widget.messId, user: widget.currentUser, role: role),
          MealAndVacationTab(
              messId: widget.messId, user: widget.currentUser, role: role),
          HisabAndSettlementTab(
              messId: widget.messId, user: widget.currentUser, role: role),
          GroupChatTab(
              messId: widget.messId, user: widget.currentUser, role: role),
          ProfileAndMembersTab(
              messId: widget.messId, user: widget.currentUser, role: role),
        ];

        return Scaffold(
          body: pages[_tab],
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.restaurant_outlined), label: 'Meal'),
              NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined), label: 'Hisab'),
              NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline), label: 'Profile'),
            ],
          ),
        );
      },
    );
  }
}

class HomeDashboardTab extends ConsumerWidget {
  const HomeDashboardTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periodId = DhakaDate.periodId(DhakaDate.now());
    return Scaffold(
      appBar: AppBar(
        title: Text('Bachelor Point (${role.labelEn})'),
        actions: [
          IconButton(
            tooltip: 'Switch Mess',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () async {
              await ref.read(sharedPrefsProvider).remove('active_mess_id');
              ref.read(activeMessIdProvider.notifier).state = null;
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: AppColors.darkNavy,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Accounting Period: $periodId',
                    style: const TextStyle(color: AppColors.emeraldLight),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${user.displayName ?? user.email} • ${role.labelBn}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Minimum Rule: 40 Meals/Month • Prorated on Approved Vacation',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MealAndVacationTab extends StatefulWidget {
  const MealAndVacationTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  @override
  State<MealAndVacationTab> createState() => _MealAndVacationTabState();
}

class _MealAndVacationTabState extends State<MealAndVacationTab> {
  DateTime _selectedDate = DhakaDate.now();
  double _b = 1.0;
  double _l = 1.0;
  double _d = 1.0;
  int _guest = 0;

  Future<void> _saveMeal() async {
    final dateId = DhakaDate.dateId(_selectedDate);
    final periodId = DhakaDate.periodId(_selectedDate);
    final entryId = '${dateId}_${widget.user.uid}';

    await FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId)
        .collection('mealEntries')
        .doc(entryId)
        .set({
      'entryId': entryId,
      'periodId': periodId,
      'memberId': widget.user.uid,
      'mealDate': dateId,
      'breakfast': _b,
      'lunch': _l,
      'dinner': _d,
      'guestMeals': _guest,
      'totalMeals': _b + _l + _d + _guest,
      'submittedBy': widget.user.uid,
      'status': 'active',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Saved ${_b + _l + _d + _guest} meals for $dateId')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meal & Vacation Entry')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Date: ${DhakaDate.dateId(_selectedDate)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  SwitchListTile(
                    title: const Text('Breakfast (সকাল — 1.0)'),
                    value: _b > 0,
                    onChanged: (v) => setState(() => _b = v ? 1.0 : 0.0),
                  ),
                  SwitchListTile(
                    title: const Text('Lunch (দুপুর — 1.0)'),
                    value: _l > 0,
                    onChanged: (v) => setState(() => _l = v ? 1.0 : 0.0),
                  ),
                  SwitchListTile(
                    title: const Text('Dinner (রাত — 1.0)'),
                    value: _d > 0,
                    onChanged: (v) => setState(() => _d = v ? 1.0 : 0.0),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _saveMeal,
                    child: const Text('Save Daily Meal Entry'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HisabAndSettlementTab extends StatelessWidget {
  const HisabAndSettlementTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hisab & Ledger')),
      body: const Center(
        child: Text('Bazar Expenses & Member Deposits Ledger',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class CookingStaffModeView extends StatelessWidget {
  const CookingStaffModeView({super.key, required this.messId});
  final String messId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('বাবুর্চি মোড')),
      body: const Center(
          child: Text('Cooking Staff Mode', style: TextStyle(fontSize: 20))),
    );
  }
}

class GroupChatTab extends StatefulWidget {
  const GroupChatTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  @override
  State<GroupChatTab> createState() => _GroupChatTabState();
}

class _GroupChatTabState extends State<GroupChatTab> {
  final _ctrl = TextEditingController();

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    await FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId)
        .collection('chatMessages')
        .add({
      'senderId': widget.user.uid,
      'senderName': widget.user.displayName ?? 'Member',
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mess Group Chat')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnap>(
              stream: FirebaseFirestore.instance
                  .collection('messes')
                  .doc(widget.messId)
                  .collection('chatMessages')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                return ListView.builder(
                  reverse: true,
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    return ListTile(
                      title: Text(d['senderName'] ?? ''),
                      subtitle: Text(d['text'] ?? ''),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: 'Type message...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.send, color: AppColors.emeraldPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileAndMembersTab extends StatelessWidget {
  const ProfileAndMembersTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text('Name: ${user.displayName ?? user.email}'),
            subtitle: Text('Role: ${role.labelEn} (${role.labelBn})'),
          ),
          const Divider(),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.dangerRed),
            onPressed: () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}
''';
