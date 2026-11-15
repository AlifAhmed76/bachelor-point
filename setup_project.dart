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

// ============================================================================
// 1. ROLES, COLORS, BDT PAISA FORMATTER & DHAKA TIMEZONE
// ============================================================================

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

// ============================================================================
// 2. DOMAIN CALCULATORS (40-MEAL MINIMUM, VACATION PRORATION & LEDGER)
// ============================================================================

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

// ============================================================================
// 3. GLOBAL PROVIDERS & APP BOOTSTRAP
// ============================================================================

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
    final messId = ref.watch(activeMessIdProvider);

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
        loading: () => const Scaffold(
          backgroundColor: AppColors.darkNavy,
          body: Center(
              child: CircularProgressIndicator(color: AppColors.emeraldLight)),
        ),
        error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
        data: (user) {
          if (user == null) return const AuthScreen();
          if (messId == null) return const MessSwitcherScreen();
          return MessWorkspaceShell(messId: messId, currentUser: user);
        },
      ),
    );
  }
}

// ============================================================================
// 4. AUTHENTICATION SCREEN (LOGIN / REGISTER / PASSWORD RESET)
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      if (_emailCtrl.text.trim().isEmpty) return;
                      await FirebaseAuth.instance.sendPasswordResetEmail(
                          email: _emailCtrl.text.trim());
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Password reset email sent!')),
                        );
                      }
                    },
                    child: Text(
                        isBn ? 'পাসওয়ার্ড ভুলে গেছেন?' : 'Forgot Password?'),
                  ),
                ),
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

// ============================================================================
// 5. MESS SWITCHER, CREATE MESS & JOIN BY INVITE CODE
// ============================================================================

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

  Future<void> _joinMessDialog() async {
    final codeCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Mess via Invite Code'),
        content: TextField(
          controller: codeCtrl,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Invite Code (e.g. BP-8492-XK)',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final code = codeCtrl.text.trim().toUpperCase();
              if (code.isEmpty) return;
              final user = FirebaseAuth.instance.currentUser!;
              final db = FirebaseFirestore.instance;

              final snap = await db
                  .collectionGroup('invitations')
                  .where('inviteCode', isEqualTo: code)
                  .where('status', isEqualTo: 'active')
                  .limit(1)
                  .get();

              if (snap.docs.isEmpty) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Invalid or expired invite code.')),
                  );
                }
                return;
              }

              final invDoc = snap.docs.first;
              final messRef = invDoc.reference.parent.parent!;
              final messId = messRef.id;

              final batch = db.batch();
              batch.set(messRef.collection('members').doc(user.uid), {
                'userId': user.uid,
                'displayName': user.displayName ?? user.email ?? 'Member',
                'role': invDoc.data()['targetRole'] ?? 'member',
                'membershipStatus': 'active',
                'joinedAt': FieldValue.serverTimestamp(),
                'roleAssignedBy': invDoc.data()['createdBy'],
                'roleAssignedAt': FieldValue.serverTimestamp(),
                'additionalPermissions': <String, bool>{},
              });

              batch.set(
                db.collection('users').doc(user.uid),
                {
                  'uid': user.uid,
                  'messIds': FieldValue.arrayUnion([messId]),
                  'updatedAt': FieldValue.serverTimestamp(),
                },
                SetOptions(merge: true),
              );

              await batch.commit();
              if (ctx.mounted) Navigator.pop(ctx);
              await _activateMess(messId);
            },
            child: const Text('Join Mess'),
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
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _joinMessDialog,
                    icon: const Icon(Icons.vpn_key),
                    label: const Text('Join Existing Mess with Invite Code'),
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
// 6. WORKSPACE SHELL (ROLE-AWARE: COOKING STAFF MODE VS MEMBER/ADMIN SHELL)
// ============================================================================

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
  void initState() {
    super.initState();
    final ref = FirebaseDatabase.instance
        .ref('presence/${widget.messId}/${widget.currentUser.uid}');
    ref.onDisconnect().set({
      'online': false,
      'lastActive': ServerValue.timestamp,
    });
    ref.set({
      'online': true,
      'lastActive': ServerValue.timestamp,
    });
  }

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
            messId: widget.messId,
            user: widget.currentUser,
            role: role,
          ),
          MealAndVacationTab(
            messId: widget.messId,
            user: widget.currentUser,
            role: role,
          ),
          HisabAndSettlementTab(
            messId: widget.messId,
            user: widget.currentUser,
            role: role,
          ),
          GroupChatTab(
            messId: widget.messId,
            user: widget.currentUser,
            role: role,
          ),
          ProfileAndMembersTab(
            messId: widget.messId,
            user: widget.currentUser,
            role: role,
          ),
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

// ============================================================================
// 7. TAB 1: HOME DASHBOARD & SECONDARY MODULES
// ============================================================================

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
          const SizedBox(height: 16),
          const Text(
            'Household Modules (সকল ফিচার)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.5,
            children: [
              _ActionTile(
                icon: Icons.soup_kitchen,
                title: 'Cooking Menu',
                subtitle: 'আজ ও কালকের মেনু',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DailyMenuScreen(messId: messId, user: user, role: role),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.elderly_woman,
                title: 'Cooking Staff UI',
                subtitle: 'বাবুর্চি বাংলা মোড',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CookingStaffModeView(messId: messId),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.cleaning_services,
                title: 'Cleaning Duties',
                subtitle: 'ডিউটি ও রোটেশন',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DutiesScreen(messId: messId, user: user, role: role),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.shopping_cart,
                title: 'Shopping & Stock',
                subtitle: 'বাজার লিস্ট ও ইনভেন্টরি',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ShoppingAndInventoryScreen(
                        messId: messId, user: user, role: role),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.campaign,
                title: 'Notices & Issues',
                subtitle: 'নোটিশ ও অভিযোগ',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NoticesAndComplaintsScreen(
                        messId: messId, user: user, role: role),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.luggage,
                title: 'Vacation Leave',
                subtitle: 'ছুটি ও মিল অব্যাহতি',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        VacationScreen(messId: messId, user: user, role: role),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: AppColors.emeraldPrimary, size: 28),
              const SizedBox(height: 6),
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14)),
              Text(subtitle,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 8. TAB 2: MEAL ENTRY & 40-MEAL MINIMUM SUMMARY
// ============================================================================

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
      'idempotencyKey': const Uuid().v4(),
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
    final periodId = DhakaDate.periodId(_selectedDate);
    final db = FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId);

    return Scaffold(
      appBar: AppBar(title: Text('Meals & 40-Min Summary ($periodId)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Date: ${DhakaDate.dateId(_selectedDate)}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: const Text('Change Date'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2025),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() => _selectedDate = picked);
                          }
                        },
                      ),
                    ],
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Guest Meals (গেস্ট মিল):'),
                      Row(
                        children: [
                          IconButton(
                            onPressed: _guest > 0
                                ? () => setState(() => _guest--)
                                : null,
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Text('$_guest',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          IconButton(
                            onPressed: () => setState(() => _guest++),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                    ],
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
          const SizedBox(height: 16),
          const Text(
            'Monthly Member Meal Summary (40-Meal Rule Applied)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnap>(
            stream: db.collection('members').snapshots(),
            builder: (context, memSnap) {
              return StreamBuilder<QuerySnap>(
                stream: db
                    .collection('mealEntries')
                    .where('periodId', isEqualTo: periodId)
                    .snapshots(),
                builder: (context, mealSnap) {
                  return StreamBuilder<QuerySnap>(
                    stream: db.collection('vacationRequests').snapshots(),
                    builder: (context, vacSnap) {
                      final members = memSnap.data?.docs ?? [];
                      final meals =
                          (mealSnap.data?.docs ?? []).map((d) => d.data()).toList();
                      final vacations =
                          (vacSnap.data?.docs ?? []).map((d) => d.data()).toList();

                      return Column(
                        children: members
                            .where((m) => m.data()['role'] != 'cooking_staff')
                            .map((m) {
                          final uid = m.id;
                          final name = m.data()['displayName'] ?? 'Member';
                          final res = MessCalculators.calculateMemberMeals(
                            memberId: uid,
                            periodId: periodId,
                            defaultMinMeals: 40,
                            mealDocs: meals,
                            vacationDocs: vacations,
                          );
                          return Card(
                            child: ListTile(
                              title: Text('$name',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              subtitle: Text(
                                  'Actual: ${res.actualMeals} • Approved Leave: ${res.leaveDays}d • Min Threshold: ${res.effectiveMin}'),
                              trailing: Text(
                                '${res.calculatedMeals} Meals',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: res.minApplied
                                      ? AppColors.warningAmber
                                      : AppColors.emeraldPrimary,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 9. TAB 3: HISAB, EXPENSES, DEPOSITS & LEDGER
// ============================================================================

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
    final periodId = DhakaDate.periodId(DhakaDate.now());
    final db = FirebaseFirestore.instance.collection('messes').doc(messId);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Hisab & Ledger ($periodId)'),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(text: 'Ledger'),
              Tab(text: 'Expenses'),
              Tab(text: 'Deposits'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            StreamBuilder<QuerySnap>(
              stream: db.collection('members').snapshots(),
              builder: (context, memSnap) {
                return StreamBuilder<QuerySnap>(
                  stream: db
                      .collection('mealEntries')
                      .where('periodId', isEqualTo: periodId)
                      .snapshots(),
                  builder: (context, mealSnap) {
                    return StreamBuilder<QuerySnap>(
                      stream: db
                          .collection('expenses')
                          .where('periodId', isEqualTo: periodId)
                          .snapshots(),
                      builder: (context, expSnap) {
                        return StreamBuilder<QuerySnap>(
                          stream: db
                              .collection('deposits')
                              .where('periodId', isEqualTo: periodId)
                              .snapshots(),
                          builder: (context, depSnap) {
                            final members = (memSnap.data?.docs ?? [])
                                .where(
                                    (m) => m.data()['role'] != 'cooking_staff')
                                .toList();
                            final meals = (mealSnap.data?.docs ?? [])
                                .map((d) => d.data())
                                .toList();
                            final expenses = (expSnap.data?.docs ?? [])
                                .map((d) => d.data())
                                .where((e) => e['status'] == 'verified')
                                .toList();
                            final deposits = (depSnap.data?.docs ?? [])
                                .map((d) => d.data())
                                .toList();

                            int totalFoodExpensePaisa = 0;
                            for (final e in expenses) {
                              totalFoodExpensePaisa +=
                                  (e['amountPaisa'] as num?)?.toInt() ?? 0;
                            }

                            double totalCalcMeals = 0.0;
                            final Map<String, double> memberCalcMap = {};
                            for (final m in members) {
                              final r = MessCalculators.calculateMemberMeals(
                                memberId: m.id,
                                periodId: periodId,
                                defaultMinMeals: 40,
                                mealDocs: meals,
                                vacationDocs: const [],
                              );
                              memberCalcMap[m.id] = r.calculatedMeals;
                              totalCalcMeals += r.calculatedMeals;
                            }

                            final int mealRatePaisa = totalCalcMeals > 0
                                ? (totalFoodExpensePaisa / totalCalcMeals)
                                    .round()
                                : 0;

                            return ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                Card(
                                  color: AppColors.darkNavy,
                                  child: Padding(
                                    padding: const EdgeInsets.all(18),
                                    child: Column(
                                      children: [
                                        Text(
                                          'Live Meal Rate: ${BdtFormatter.formatPaisa(mealRatePaisa)} / meal',
                                          style: const TextStyle(
                                              color: AppColors.emeraldLight,
                                              fontSize: 20,
                                              fontWeight: FontWeight.w800),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Total Food Expense: ${BdtFormatter.formatPaisa(totalFoodExpensePaisa)} • Total Calc. Meals: $totalCalcMeals',
                                          style: const TextStyle(
                                              color: Colors.white70),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ...members.map((m) {
                                  final uid = m.id;
                                  final name =
                                      m.data()['displayName'] ?? 'Member';
                                  final calcMeals = memberCalcMap[uid] ?? 40.0;
                                  final mealCostPaisa =
                                      (calcMeals * mealRatePaisa).round();

                                  int depPaisa = 0;
                                  for (final d in deposits) {
                                    if (d['memberId'] == uid) {
                                      depPaisa +=
                                          (d['amountPaisa'] as num?)?.toInt() ??
                                              0;
                                    }
                                  }

                                  final netPaisa = depPaisa - mealCostPaisa;
                                  return Card(
                                    child: ListTile(
                                      title: Text('$name',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      subtitle: Text(
                                          'Deposit: ${BdtFormatter.formatPaisa(depPaisa)} • Meal Cost ($calcMeals): ${BdtFormatter.formatPaisa(mealCostPaisa)}'),
                                      trailing: Text(
                                        BdtFormatter.formatPaisa(netPaisa),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: netPaisa < 0
                                              ? AppColors.dangerRed
                                              : AppColors.emeraldPrimary,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
            Scaffold(
              floatingActionButton: role.isManagement
                  ? FloatingActionButton.extended(
                      onPressed: () =>
                          _showAddExpenseDialog(context, db, periodId),
                      icon: const Icon(Icons.add_shopping_cart),
                      label: const Text('Add Expense'),
                    )
                  : null,
              body: StreamBuilder<QuerySnap>(
                stream: db
                    .collection('expenses')
                    .where('periodId', isEqualTo: periodId)
                    .snapshots(),
                builder: (context, snap) {
                  final docs = snap.data?.docs ?? [];
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i].data();
                      return Card(
                        child: ListTile(
                          title: Text(d['description'] ?? 'Expense'),
                          subtitle: Text(d['expenseDate'] ?? ''),
                          trailing: Text(
                            BdtFormatter.formatPaisa(
                                (d['amountPaisa'] as num?)?.toInt() ?? 0),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Scaffold(
              floatingActionButton: role.isManagement
                  ? FloatingActionButton.extended(
                      onPressed: () =>
                          _showAddDepositDialog(context, db, periodId),
                      icon: const Icon(Icons.account_balance_wallet),
                      label: const Text('Add Deposit'),
                    )
                  : null,
              body: StreamBuilder<QuerySnap>(
                stream: db
                    .collection('deposits')
                    .where('periodId', isEqualTo: periodId)
                    .snapshots(),
                builder: (context, snap) {
                  final docs = snap.data?.docs ?? [];
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i].data();
                      return Card(
                        child: ListTile(
                          title: Text(
                              'Member ID: ${d['memberId']} (${d['paymentMethod']})'),
                          subtitle: Text(d['depositDate'] ?? ''),
                          trailing: Text(
                            BdtFormatter.formatPaisa(
                                (d['amountPaisa'] as num?)?.toInt() ?? 0),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.emeraldPrimary,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddExpenseDialog(
    BuildContext context,
    DocRef db,
    String periodId,
  ) {
    final descCtrl = TextEditingController();
    final amtCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Bazar / Mess Expense'),
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
              final ref = db.collection('expenses').doc();
              await ref.set({
                'expenseId': ref.id,
                'periodId': periodId,
                'category': 'bazar',
                'isMealExpense': true,
                'description': descCtrl.text.trim(),
                'amountPaisa': paisa,
                'paidBy': user.uid,
                'expenseDate': DhakaDate.dateId(DhakaDate.now()),
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

  void _showAddDepositDialog(
    BuildContext context,
    DocRef db,
    String periodId,
  ) {
    final amtCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Record Member Deposit'),
        content: TextField(
          controller: amtCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Deposit Amount (৳)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final paisa = BdtFormatter.parseTakaToPaisa(amtCtrl.text);
              if (paisa <= 0) return;
              final ref = db.collection('deposits').doc();
              await ref.set({
                'depositId': ref.id,
                'periodId': periodId,
                'memberId': user.uid,
                'amountPaisa': paisa,
                'paymentMethod': 'cash',
                'depositDate': DhakaDate.dateId(DhakaDate.now()),
                'receivedBy': user.uid,
                'idempotencyKey': const Uuid().v4(),
                'status': 'confirmed',
                'createdAt': FieldValue.serverTimestamp(),
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save Deposit'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 10. DAILY MENU & BANGLA COOKING STAFF MODE
// ============================================================================

class DailyMenuScreen extends StatelessWidget {
  const DailyMenuScreen({
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
    final todayId = DhakaDate.dateId(DhakaDate.now());
    final db = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('dailyMenus')
        .doc(todayId);

    return Scaffold(
      appBar: AppBar(title: Text('Daily Cooking Menu ($todayId)')),
      floatingActionButton: role.isManagement
          ? FloatingActionButton.extended(
              onPressed: () => _publishDialog(context, db, todayId),
              icon: const Icon(Icons.edit),
              label: const Text('Publish Menu'),
            )
          : null,
      body: StreamBuilder<QuerySnap>(
        stream: db.collection('items').snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
                child: Text('No menu published for today yet.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i].data();
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.restaurant,
                      color: AppColors.emeraldPrimary, size: 32),
                  title: Text(
                      '${(d['mealType'] ?? 'lunch').toString().toUpperCase()} • ${d['itemNameBn'] ?? d['itemName']}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                      'Category: ${d['foodCategory']} • People: ${d['servingCount']} • Qty: ${d['quantity']} kg'),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _publishDialog(
    BuildContext context,
    DocRef menuRef,
    String todayId,
  ) {
    final nameBnCtrl = TextEditingController(text: 'রুই মাছ ভুনা, ডাল ও ভাত');
    final servingsCtrl = TextEditingController(text: '8');
    String cat = 'fish';

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Publish Menu (Fixed Image Category)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: cat,
                items: const [
                  DropdownMenuItem(
                      value: 'regular', child: Text('Regular (ডাল-ভাত-ভাজি)')),
                  DropdownMenuItem(
                      value: 'fish', child: Text('Fish (মাছ ও ভাত)')),
                  DropdownMenuItem(
                      value: 'meat', child: Text('Meat (মাংস ও ভাত)')),
                  DropdownMenuItem(
                      value: 'special', child: Text('Special (বিরিয়ানি/পোলাও)')),
                ],
                onChanged: (v) => setState(() => cat = v ?? 'regular'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameBnCtrl,
                decoration:
                    const InputDecoration(labelText: 'খাবারের নাম (বাংলা)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: servingsCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'মোট মানুষ (Headcount)'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                await menuRef.set({
                  'menuId': todayId,
                  'menuDate': todayId,
                  'status': 'published',
                  'publishedBy': user.uid,
                  'publishedAt': FieldValue.serverTimestamp(),
                  'updatedAt': FieldValue.serverTimestamp(),
                  'cookingStatus': {
                    'breakfastDone': false,
                    'lunchDone': false,
                    'dinnerDone': false,
                  },
                }, SetOptions(merge: true));

                await menuRef.collection('items').doc('lunch').set({
                  'itemId': 'lunch',
                  'mealType': 'lunch',
                  'itemName': nameBnCtrl.text.trim(),
                  'itemNameBn': nameBnCtrl.text.trim(),
                  'foodCategory': cat,
                  'imageKey': cat,
                  'quantity': 2.0,
                  'unit': 'kg',
                  'servingCount': int.tryParse(servingsCtrl.text) ?? 8,
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Publish'),
            ),
          ],
        ),
      ),
    );
  }
}

class CookingStaffModeView extends StatelessWidget {
  const CookingStaffModeView({super.key, required this.messId});
  final String messId;

  @override
  Widget build(BuildContext context) {
    final todayId = DhakaDate.dateId(DhakaDate.now());
    final menuRef = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('dailyMenus')
        .doc(todayId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('বাবুর্চি মোড — আজকের রান্না',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      ),
      body: StreamBuilder<DocSnap>(
        stream: menuRef.snapshots(),
        builder: (context, menuSnap) {
          final statusMap =
              menuSnap.data?.data()?['cookingStatus'] as JsonMap? ?? {};
          final bool lunchDone = statusMap['lunchDone'] == true;

          return StreamBuilder<QuerySnap>(
            stream: menuRef.collection('items').snapshots(),
            builder: (context, itemsSnap) {
              final docs = itemsSnap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Center(
                  child: Text(
                    'আজকের জন্য এখনো কোনো মেনু দেওয়া হয়নি।',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i].data();
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${d['itemNameBn'] ?? d['itemName']}',
                            style: const TextStyle(
                                fontSize: 26, fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'মোট মানুষ: ${d['servingCount']} জন • পরিমাণ: ${d['quantity']} কেজি',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.emeraldPrimary),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 60,
                            child: ElevatedButton.icon(
                              icon: Icon(
                                lunchDone
                                    ? Icons.check_circle
                                    : Icons.soup_kitchen,
                                size: 30,
                              ),
                              label: Text(
                                lunchDone
                                    ? 'রান্না শেষ হয়েছে ✓'
                                    : 'রান্না শেষ হলে এখানে চাপুন',
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800),
                              ),
                              onPressed: () => menuRef.update({
                                'cookingStatus': {
                                  'breakfastDone':
                                      statusMap['breakfastDone'] ?? false,
                                  'lunchDone': !lunchDone,
                                  'dinnerDone':
                                      statusMap['dinnerDone'] ?? false,
                                },
                                'updatedAt': FieldValue.serverTimestamp(),
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================================
// 11. DUTIES, SHOPPING/INVENTORY, NOTICES, VACATIONS, CHAT & ROLES
// ============================================================================

class DutiesScreen extends StatelessWidget {
  const DutiesScreen({
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
    final col = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('dutyAssignments');
    return Scaffold(
      appBar: AppBar(title: const Text('Cleaning & Household Duties')),
      floatingActionButton: role.isManagement
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ref = col.doc();
                await ref.set({
                  'assignmentId': ref.id,
                  'dutyId': 'kitchen',
                  'dutyTitle': 'Kitchen & Dining Cleaning',
                  'category': 'kitchen',
                  'assignedTo': user.uid,
                  'assignedToName': user.displayName ?? 'Member',
                  'dueDate': Timestamp.fromDate(
                      DhakaDate.now().add(const Duration(days: 1))),
                  'status': 'pending',
                  'assignedBy': user.uid,
                });
              },
              icon: const Icon(Icons.add_task),
              label: const Text('Assign Duty'),
            )
          : null,
      body: StreamBuilder<QuerySnap>(
        stream: col.snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i].data();
              return Card(
                child: ListTile(
                  title: Text(d['dutyTitle'] ?? 'Duty'),
                  subtitle: Text(
                      'Assigned: ${d['assignedToName']} • Status: ${d['status']}'),
                  trailing: d['status'] == 'pending'
                      ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              minimumSize: const Size(80, 36)),
                          onPressed: () => docs[i].reference.update({
                            'status': 'submitted',
                            'completionNote': 'Done',
                            'submittedAt': FieldValue.serverTimestamp(),
                          }),
                          child: const Text('Done'),
                        )
                      : Chip(label: Text('${d['status']}')),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ShoppingAndInventoryScreen extends StatelessWidget {
  const ShoppingAndInventoryScreen({
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
    final col = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('inventoryItems');
    return Scaffold(
      appBar: AppBar(title: const Text('Grocery Inventory & Stock')),
      floatingActionButton: role.isManagement
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ref = col.doc();
                await ref.set({
                  'itemId': ref.id,
                  'itemName': 'Miniket Rice (মিনিকেট চাল)',
                  'category': 'grain',
                  'currentQuantity': 25.0,
                  'unit': 'kg',
                  'lowStockThreshold': 5.0,
                  'updatedAt': FieldValue.serverTimestamp(),
                });
              },
              icon: const Icon(Icons.add),
              label: const Text('Add Stock Item'),
            )
          : null,
      body: StreamBuilder<QuerySnap>(
        stream: col.snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i].data();
              return Card(
                child: ListTile(
                  title: Text(d['itemName'] ?? 'Item'),
                  subtitle:
                      Text('Stock: ${d['currentQuantity']} ${d['unit']}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class NoticesAndComplaintsScreen extends StatelessWidget {
  const NoticesAndComplaintsScreen({
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
    final col = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('notices');
    return Scaffold(
      appBar: AppBar(title: const Text('Notices & Announcements')),
      floatingActionButton: role.isManagement
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ref = col.doc();
                await ref.set({
                  'noticeId': ref.id,
                  'title': 'Monthly Mess Meeting',
                  'body': 'Please clear all bazar and utility dues by the 10th.',
                  'priority': 'normal',
                  'publishedBy': user.uid,
                  'publisherName': user.displayName ?? 'Admin',
                  'createdAt': FieldValue.serverTimestamp(),
                });
              },
              icon: const Icon(Icons.campaign),
              label: const Text('Post Notice'),
            )
          : null,
      body: StreamBuilder<QuerySnap>(
        stream: col.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i].data();
              return Card(
                child: ListTile(
                  title: Text(d['title'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(d['body'] ?? ''),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class VacationScreen extends StatelessWidget {
  const VacationScreen({
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
    final col = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('vacationRequests');
    final periodId = DhakaDate.periodId(DhakaDate.now());

    return Scaffold(
      appBar: AppBar(title: const Text('Vacation & Leave Requests')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final ref = col.doc();
          final start = DhakaDate.now().add(const Duration(days: 1));
          final end = DhakaDate.now().add(const Duration(days: 7));
          await ref.set({
            'requestId': ref.id,
            'periodId': periodId,
            'overlapPeriods': [periodId],
            'memberId': user.uid,
            'memberName': user.displayName ?? 'Member',
            'leaveType': 'home',
            'startDate': DhakaDate.dateId(start),
            'endDate': DhakaDate.dateId(end),
            'totalDays': 7,
            'reason': 'Home Visit',
            'status': 'pending',
            'approvedBy': null,
            'approvedAt': null,
            'createdAt': FieldValue.serverTimestamp(),
          });
        },
        icon: const Icon(Icons.luggage),
        label: const Text('Request 7d Leave'),
      ),
      body: StreamBuilder<QuerySnap>(
        stream: col.snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i].data();
              final status = d['status'] ?? 'pending';
              return Card(
                child: ListTile(
                  title: Text('${d['memberName']} • ${d['totalDays']} Days'),
                  subtitle: Text(
                      '${d['startDate']} to ${d['endDate']} • Status: $status'),
                  trailing: (role.isAdminOrOwner && status == 'pending')
                      ? IconButton(
                          icon: const Icon(Icons.check_circle,
                              color: AppColors.emeraldPrimary),
                          onPressed: () => docs[i].reference.update({
                            'status': 'approved',
                            'approvedBy': user.uid,
                            'approvedAt': FieldValue.serverTimestamp(),
                          }),
                        )
                      : Chip(label: Text('$status')),
                ),
              );
            },
          );
        },
      ),
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
    final ref = FirebaseFirestore.instance
        .collection('messes')
        .doc(widget.messId)
        .collection('chatMessages')
        .doc();
    await ref.set({
      'messageId': ref.id,
      'senderId': widget.user.uid,
      'senderName': widget.user.displayName ?? 'Member',
      'senderRole': widget.role.value,
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

    return Scaffold(
      appBar: AppBar(title: const Text('Mess Group Chat')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnap>(
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
                        title: Text(
                            '${d['senderName']} (${d['senderRole']})',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w800)),
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
                      hintText: 'Write message to mess...',
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
      ),
    );
  }
}

class ProfileAndMembersTab extends ConsumerWidget {
  const ProfileAndMembersTab({
    super.key,
    required this.messId,
    required this.user,
    required this.role,
  });

  final String messId;
  final User user;
  final AppRole role;

  Future<void> _generateInvite(BuildContext context) async {
    final rand = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    String part(int n) =>
        List.generate(n, (_) => chars[rand.nextInt(chars.length)]).join();
    final code = 'BP-${part(4)}-${part(2)}';

    final ref = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('invitations')
        .doc();
    await ref.set({
      'invitationId': ref.id,
      'inviteCode': code,
      'targetRole': 'member',
      'createdBy': user.uid,
      'expiresAt':
          Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
      'maxUses': 10,
      'usedCount': 0,
      'status': 'active',
    });

    if (context.mounted) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mess Invite Code Generated'),
          content: SelectableText(
            code,
            style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: AppColors.emeraldPrimary),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.pop(ctx);
              },
              child: const Text('Copy & Close'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBn = ref.watch(isBanglaProvider);
    final membersCol = FirebaseFirestore.instance
        .collection('messes')
        .doc(messId)
        .collection('members');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Members, Roles & Settings'),
        actions: [
          if (role.isAdminOrOwner)
            IconButton(
              tooltip: 'Generate Invite Code',
              icon: const Icon(Icons.person_add),
              onPressed: () => _generateInvite(context),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              title: const Text('বাংলা ভাষা ব্যবহার করুন (Bangla UI)'),
              value: isBn,
              onChanged: (v) => ref.read(isBanglaProvider.notifier).state = v,
            ),
          ),
          const SizedBox(height: 12),
          const Text('Mess Members & Role Management',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnap>(
            stream: membersCol.snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              return Column(
                children: docs.map((d) {
                  final m = d.data();
                  final mRole = AppRole.fromString(m['role'] as String?);
                  return Card(
                    child: ListTile(
                      title: Text(m['displayName'] ?? 'Member',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${mRole.labelEn} • ${mRole.labelBn}'),
                      trailing: (role.isAdminOrOwner && mRole != AppRole.owner)
                          ? DropdownButton<String>(
                              value: mRole.value,
                              items: const [
                                DropdownMenuItem(
                                    value: 'co_admin',
                                    child: Text('Co-Admin')),
                                DropdownMenuItem(
                                    value: 'manager', child: Text('Manager')),
                                DropdownMenuItem(
                                    value: 'member', child: Text('Member')),
                                DropdownMenuItem(
                                    value: 'cooking_staff',
                                    child: Text('Cooking Staff')),
                              ],
                              onChanged: (newRole) {
                                if (newRole != null) {
                                  d.reference.update({'role': newRole});
                                }
                              },
                            )
                          : Chip(label: Text(mRole.labelEn)),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
''';
