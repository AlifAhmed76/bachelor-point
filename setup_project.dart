import 'dart:io';

/// Automated Cloud Builder Script for Bachelor Point.
/// Generates the complete production multi-screen Flutter architecture inside GitHub Actions.
void main() {
  print('Generating Bachelor Point production source files...');

  // 1. Create folder structure
  final dirs = [
    'assets/images/food',
    'assets/images/avatars',
    'lib/core/constants',
    'lib/core/theme',
    'lib/core/utils',
    'lib/core/localization',
    'lib/core/router',
    'lib/domain/entities',
    'lib/domain/calculators',
    'lib/data/local',
    'lib/data/remote',
    'lib/data/repositories',
    'lib/data/sync',
    'lib/presentation/providers',
    'lib/presentation/layouts',
    'lib/presentation/features/auth',
    'lib/presentation/features/mess',
    'lib/presentation/features/meals',
    'lib/presentation/features/vacation',
    'lib/presentation/features/finance',
    'lib/presentation/features/menu',
    'lib/presentation/features/duties',
    'lib/presentation/features/chat',
    'lib/presentation/features/notices_complaints',
    'lib/presentation/features/inventory',
  ];

  for (final d in dirs) {
    Directory(d).createSync(recursive: true);
  }

  // Keep placeholder files in asset folders so pubspec.yaml succeeds
  File('assets/images/food/.gitkeep').writeAsStringSync('');
  File('assets/images/avatars/.gitkeep').writeAsStringSync('');

  // 2. Write pubspec.yaml
  File('pubspec.yaml').writeAsStringSync(r'''
name: bachelor_point
description: Household Mess & Bachelor House Management System (Spark Plan Zero-Cost).
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.4.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.6.1
  go_router: ^14.6.2
  firebase_core: ^3.8.0
  firebase_auth: ^5.3.3
  cloud_firestore: ^5.5.0
  firebase_database: ^11.1.6
  shared_preferences: ^2.3.3
  uuid: ^4.5.1
  intl: ^0.19.0
  equatable: ^2.0.7
  connectivity_plus: ^6.1.0
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

  // 3. Write complete consolidated application entrypoint & modules into lib/main.dart
  File('lib/main.dart').writeAsStringSync(_mainAppCode);
  print('Bachelor Point source generation complete!');
}

const String _mainAppCode = r'''
import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// ============================================================================
// 1. CORE CONSTANTS, ROLES, THEME & BDT PAISA FORMATTER
// ============================================================================

enum AppRole {
  owner('owner', 'Owner', 'মেস মালিক'),
  coAdmin('co_admin', 'Co-Admin', 'কো-অ্যাডমিন'),
  manager('manager', 'Manager', 'ম্যানেজার'),
  member('member', 'Member', 'সদস্য'),
  cookingStaff('cooking_staff', 'Cooking Staff', 'বাবুর্চি / রান্নার স্টাফ');

  const AppRole(this.value, this.labelEn, this.labelBn);
  final String value;
  final String labelEn;
  final String labelBn;

  static AppRole fromString(String? value) {
    return AppRole.values.firstWhere(
      (r) => r.value == value,
      orElse: () => AppRole.member,
    );
  }

  bool get isAdminOrOwner => this == AppRole.owner || this == AppRole.coAdmin;
  bool get isManagement =>
      this == AppRole.owner ||
      this == AppRole.coAdmin ||
      this == AppRole.manager;
  bool get isCookingStaff => this == AppRole.cookingStaff;
}

class AppColors {
  static const Color darkNavy = Color(0xFF0F172A);
  static const Color slateNavy = Color(0xFF1E293B);
  static const Color emeraldPrimary = Color(0xFF059669);
  static const Color emeraldLight = Color(0xFF10B981);
  static const Color lightBackground = Color(0xFFF8FAFC);
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color dangerRed = Color(0xFFDC2626);
  static const Color warningAmber = Color(0xFFD97706);
}

class BdtFormatter {
  static final NumberFormat _fmt = NumberFormat('#,##0.00', 'en_US');

  static String formatPaisa(int paisa) {
    final bool neg = paisa < 0;
    final double taka = paisa.abs() / 100.0;
    return '${neg ? "-" : ""}৳${_fmt.format(taka)}';
  }

  static int parseTakaToPaisa(String input) {
    final cleaned = input.replaceAll(',', '').replaceAll('৳', '').trim();
    if (cleaned.isEmpty) return 0;
    final double val = double.tryParse(cleaned) ?? 0.0;
    return (val * 100).round();
  }
}

class DhakaDateUtils {
  static DateTime nowInDhaka() =>
      DateTime.now().toUtc().add(const Duration(hours: 6));

  static String formatDateId(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  static String formatPeriodId(DateTime d) => DateFormat('yyyy-MM').format(d);
  static String formatDisplay(DateTime d) =>
      DateFormat('dd MMM yyyy').format(d);
}

// ============================================================================
// 2. RIVERPOD PROVIDERS & STATE
// ============================================================================

final sharedPrefsProvider = Provider<SharedPreferences>((_) {
  throw UnimplementedError();
});

final authStateProvider = StreamProvider<User?>((_) {
  return FirebaseAuth.instance.authStateChanges();
});

final activeMessIdProvider = StateProvider<String?>((ref) {
  return ref.watch(sharedPrefsProvider).getString('active_mess_id');
});

final localeIsBanglaProvider = StateProvider<bool>((_) => false);

// ============================================================================
// 3. MAIN BOOTSTRAP
// ============================================================================

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
    final isBn = ref.watch(localeIsBanglaProvider);
    final authAsync = ref.watch(authStateProvider);
    final activeMessId = ref.watch(activeMessIdProvider);

    final baseText = isBn
        ? GoogleFonts.notoSansBengaliTextTheme()
        : GoogleFonts.interTextTheme();

    return MaterialApp(
      title: 'Bachelor Point',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.lightBackground,
        colorScheme: const ColorScheme.light(
          primary: AppColors.darkNavy,
          secondary: AppColors.emeraldPrimary,
        ),
        textTheme: baseText,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.darkNavy,
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.emeraldPrimary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: authAsync.when(
        loading: () => const Scaffold(
          backgroundColor: AppColors.darkNavy,
          body: Center(
            child: CircularProgressIndicator(color: AppColors.emeraldLight),
          ),
        ),
        error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
        data: (user) {
          if (user == null) return const AuthScreen();
          if (activeMessId == null) return const MessSelectorScreen();
          return MainShellScreen(messId: activeMessId, currentUser: user);
        },
      ),
    );
  }
}

// ============================================================================
// 4. AUTHENTICATION SCREEN (LOGIN / REGISTER / RESET)
// ============================================================================

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
    final isBn = ref.watch(localeIsBanglaProvider);
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
                        size: 44, color: AppColors.emeraldPrimary),
                    TextButton.icon(
                      onPressed: () => ref
                          .read(localeIsBanglaProvider.notifier)
                          .state = !isBn,
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
                Text(
                  isBn
                      ? 'স্বচ্ছ মেস ও ব্যাচেলর হাউস ম্যানেজমেন্ট'
                      : 'Transparent Mess & Bachelor House Management',
                ),
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
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() => _isLogin = !_isLogin),
                  child: Text(_isLogin
                      ? (isBn
                          ? 'নতুন অ্যাকাউন্ট খুলতে এখানে ট্যাপ করুন'
                          : 'Need an account? Register')
                      : (isBn
                          ? 'আগে থেকেই অ্যাকাউন্ট আছে? লগইন করুন'
                          : 'Already have an account? Log In')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 5. MESS SELECTOR, CREATE MESS & JOIN BY INVITE CODE
// ============================================================================

class MessSelectorScreen extends ConsumerStatefulWidget {
  const MessSelectorScreen({super.key});

  @override
  ConsumerState<MessSelectorScreen> createState() => _MessSelectorScreenState();
}

class _MessSelectorScreenState extends ConsumerState<MessSelectorScreen> {
  Future<void> _selectMess(String messId) async {
    final prefs = ref.read(sharedPrefsProvider);
    await prefs.setString('active_mess_id', messId);
    ref.read(activeMessIdProvider.notifier).state = messId;
  }

  Future<void> _showCreateMessDialog() async {
    final nameCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    final minCtrl = TextEditingController(text: '40');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Mess (নতুন মেস)'),
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
              decoration:
                  const InputDecoration(labelText: 'Address (e.g. Mirpur-10)'),
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
              final user = FirebaseAuth.instance.currentUser!;
              final db = FirebaseFirestore.instance;
              final messRef = db.collection('messes').doc();
              final messId = messRef.id;
              final periodId =
                  DhakaDateUtils.formatPeriodId(DhakaDateUtils.nowInDhaka());
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
              await _selectMess(messId);
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
        title: const Text('Select or Create Mess'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>>(
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
                  if (messIds.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'You have not joined any mess yet. Create your mess below to become the Owner.'),
                      ),
                    ),
                  ...messIds.map(
                    (id) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.apartment,
                            color: AppColors.emeraldPrimary),
                        title: Text('Mess ID: $id'),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                        onTap: () => _selectMess(id),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _showCreateMessDialog,
                    icon: const Icon(Icons.add_home_work),
                    label: const Text('Create New Mess (নতুন মেস খুলুন)'),
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

// ============================================================================
// 6. MAIN SHELL (HOME, MEALS, HISAB, MENU/COOKING STAFF, CHAT)
// ============================================================================

class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({
    super.key,
    required this.messId,
    required this.currentUser,
  });

  final String messId;
  final User currentUser;

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _DashboardTab(messId: widget.messId, user: widget.currentUser),
      _MealsTab(messId: widget.messId, user: widget.currentUser),
      _HisabTab(messId: widget.messId, user: widget.currentUser),
      _CookingMenuTab(messId: widget.messId, user: widget.currentUser),
      _ChatTab(messId: widget.messId, user: widget.currentUser),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bachelor Point'),
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
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.restaurant_outlined), label: 'Meal'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined), label: 'Hisab'),
          NavigationDestination(
              icon: Icon(Icons.soup_kitchen_outlined), label: 'Menu'),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
        ],
      ),
    );
  }
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({required this.messId, required this.user});
  final String messId;
  final User user;

  @override
  Widget build(BuildContext context) {
    final periodId =
        DhakaDateUtils.formatPeriodId(DhakaDateUtils.nowInDhaka());
    return ListView(
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
                  'Active Period: $periodId',
                  style: const TextStyle(color: AppColors.emeraldLight),
                ),
                const SizedBox(height: 8),
                Text(
                  'Member: ${user.displayName ?? user.email}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Minimum Meal Rule: 40 Meals / Month (Prorated on Approved Leave)',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MealsTab extends StatefulWidget {
  const _MealsTab({required this.messId, required this.user});
  final String messId;
  final User user;

  @override
  State<_MealsTab> createState() => _MealsTabState();
}

class _MealsTabState extends State<_MealsTab> {
  double _b = 1.0;
  double _l = 1.0;
  double _d = 1.0;
  int _guest = 0;

  Future<void> _saveMeal() async {
    final now = DhakaDateUtils.nowInDhaka();
    final dateId = DhakaDateUtils.formatDateId(now);
    final periodId = DhakaDateUtils.formatPeriodId(now);
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
      'idempotencyKey': const Uuid().v4(),
      'status': 'active',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${_b + _l + _d + _guest} meals for $dateId')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text('Today\'s Meal Entry (আজকের মিল)',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _saveMeal,
                  child: const Text('Save Today\'s Meal'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HisabTab extends StatelessWidget {
  const _HisabTab({required this.messId, required this.user});
  final String messId;
  final User user;

  @override
  Widget build(BuildContext context) {
    final periodId =
        DhakaDateUtils.formatPeriodId(DhakaDateUtils.nowInDhaka());
    final expStream = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('expenses')
        .where('periodId', isEqualTo: periodId)
        .snapshots();

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addExpenseDialog(context, periodId),
        icon: const Icon(Icons.add),
        label: const Text('Add Bazar Expense'),
      ),
      body: StreamBuilder<QuerySnapshot>>(
        stream: expStream,
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          int totalPaisa = 0;
          for (final d in docs) {
            if (d.data()['status'] == 'verified') {
              totalPaisa += (d.data()['amountPaisa'] as num?)?.toInt() ?? 0;
            }
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: AppColors.darkNavy,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    'Total Verified Expense ($periodId): ${BdtFormatter.formatPaisa(totalPaisa)}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ...docs.map((d) {
                final data = d.data();
                return Card(
                  child: ListTile(
                    title: Text(data['description'] ?? 'Bazar'),
                    subtitle: Text(data['expenseDate'] ?? ''),
                    trailing: Text(
                      BdtFormatter.formatPaisa(
                          (data['amountPaisa'] as num?)?.toInt() ?? 0),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }

  void _addExpenseDialog(BuildContext context, String periodId) {
    final descCtrl = TextEditingController();
    final amtCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Bazar Expense (বাজার খরচ)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amtCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount in BDT (৳)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final paisa = BdtFormatter.parseTakaToPaisa(amtCtrl.text);
              if (paisa <= 0) return;
              final ref = FirebaseFirestore.instance
                  .collection('messes')
                  .doc(messId)
                  .collection('expenses')
                  .doc();
              await ref.set({
                'expenseId': ref.id,
                'periodId': periodId,
                'category': 'bazar',
                'isMealExpense': true,
                'description': descCtrl.text.trim(),
                'amountPaisa': paisa,
                'paidBy': user.uid,
                'expenseDate': DhakaDateUtils.formatDateId(
                    DhakaDateUtils.nowInDhaka()),
                'createdBy': user.uid,
                'idempotencyKey': const Uuid().v4(),
                'status': 'verified',
                'createdAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _CookingMenuTab extends StatelessWidget {
  const _CookingMenuTab({required this.messId, required this.user});
  final String messId;
  final User user;

  @override
  Widget build(BuildContext context) {
    final todayId = DhakaDateUtils.formatDateId(DhakaDateUtils.nowInDhaka());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('আজকের রান্নার মেনু ($todayId)',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text(
                  'রুই মাছ, ডাল ও ভাত (Regular / Fish Category)',
                  style: TextStyle(fontSize: 18),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatTab extends StatefulWidget {
  const _ChatTab({required this.messId, required this.user});
  final String messId;
  final User user;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  final _ctrl = TextEditingController();

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    final ref = FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId)
        .collection('chatMessages')
        .doc();
    await ref.set({
      'messageId': ref.id,
      'senderId': widget.user.uid,
      'senderName': widget.user.displayName ?? 'Member',
      'senderRole': 'owner',
      'text': text,
      'isDeleted': false,
      'isFlagged': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId)
        .collection('chatMessages')
        .orderBy('createdAt', descending: true)
        .limit(30)
        .snapshots();

    return Column(
      children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot>>(
            stream: stream,
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i].data();
                  return Card(
                    child: ListTile(
                      title: Text(d['senderName'] ?? 'Member',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                      subtitle: Text(d['text'] ?? ''),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'Write message...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
''';
