// lib/screens/settings_screen.dart
import 'dart:io'; // ✅ [추가] 프로필 이미지용
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http; // ✅ 서버 통신
import 'package:google_sign_in/google_sign_in.dart'; // ✅ 구글 로그아웃

import '../theme_state.dart';
import 'login_page.dart';
import 'care_target_my_page.dart';
import 'help_screen.dart'; // ✅ 도움말 화면
import 'permission_request_page.dart'; // ✅ 권한 재설정 페이지

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isConnected = false;
  bool _isLoading = true;
  int? _userRole; // 1: 보호자, 2: 대상자
  String? _connectedName;
  String _myEmail = '';
  String _myName = '사용자';
  String? _profileImagePath; // ✅ [추가] 프로필 이미지 경로

  // ✅ 서버 URL (회원가입 때 썼던 주소)
  final String _serverUrl =
      "https://endpoint-4.example.invalid";

  String _inviteCode = '로딩 중...';
  String? _connectedGuardianName;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _checkConnectionStatus();
  }

  Future<void> _loadUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      setState(() {
        _myEmail = user.email ?? '';
      });

      // ✅ [추가] 프로필 이미지 로드
      final prefs = await SharedPreferences.getInstance();
      bool isGoogleProvider = user.providerData.any(
        (userInfo) => userInfo.providerId == 'google.com',
      );
      String searchKey = isGoogleProvider
          ? 'google_${user.email}'
          : 'general_${user.uid}';
      final savedImagePath = prefs.getString('user_profile_image_$searchKey');
      if (savedImagePath != null && mounted) {
        setState(() {
          _profileImagePath = savedImagePath;
        });
      }

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (doc.exists && mounted) {
        final data = doc.data()!;
        int role = 0;
        if (data['role'] is int) {
          role = data['role'];
        } else if (data['role'] is String) {
          role = int.tryParse(data['role']) ?? 0;
        }

        setState(() {
          _userRole = role;
          _myName = data['name'] ?? '사용자';
          _inviteCode =
              data['connect_code'] ??
              data['inviteCode'] ??
              data['code'] ??
              '코드 없음';
        });

        if (role == 2 &&
            data['guardianId'] != null &&
            data['is_connected'] == true) {
          _fetchGuardianName(data['guardianId']);
        }
      }
    }
  }

  Future<void> _fetchGuardianName(String guardianId) async {
    try {
      final gDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(guardianId)
          .get();
      if (gDoc.exists && mounted) {
        setState(() {
          _connectedGuardianName = gDoc.data()?['name'] ?? '알 수 없음';
        });
      }
    } catch (e) {
      debugPrint("보호자 이름 로드 실패: $e");
    }
  }

  Future<void> _checkConnectionStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;
        _userRole = data['role'] as int?;

        if (_userRole == 1) {
          final seniorId = data['seniorId'] as String?;
          if (seniorId != null && seniorId.isNotEmpty) {
            _isConnected = true;
            final seniorDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(seniorId)
                .get();
            _connectedName = seniorDoc.data()?['name'] as String? ?? '대상자';
          }
        } else if (_userRole == 2) {
          final guardianId = data['guardianId'] as String?;
          if (guardianId != null && guardianId.isNotEmpty) {
            _isConnected = true;
            final guardianDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(guardianId)
                .get();
            _connectedName = guardianDoc.data()?['name'] as String? ?? '보호자';
          }
        }
      }
    } catch (e) {
      debugPrint('연결 상태 확인 오류: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _disconnectConnection() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('연결 해제'),
        content: Text(
          _userRole == 1
              ? '대상자와의 연결을 해제하시겠습니까?\n다시 연결하려면 연결 코드를 입력해야 합니다.'
              : '보호자와의 연결을 해제하시겠습니까?\n보호자가 더 이상 상태를 확인할 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('연결 해제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (_userRole == 1) {
        final seniorId = userDoc.data()?['seniorId'] as String?;
        if (seniorId != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(seniorId)
              .update({
                'guardianId': null,
                'guardianFcmToken': null,
                'is_connected': false,
              });
        }
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({
              'seniorId': null,
              'seniorFcmToken': null,
              'is_connected': false,
            });

        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('caremode_senior_code');
      } else if (_userRole == 2) {
        final guardianId = userDoc.data()?['guardianId'] as String?;
        if (guardianId != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(guardianId)
              .update({
                'seniorId': null,
                'seniorFcmToken': null,
                'is_connected': false,
              });
        }
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({
              'guardianId': null,
              'guardianFcmToken': null,
              'is_connected': false,
            });

        final code = userDoc.data()?['connect_code'] ?? userDoc.data()?['code'];
        if (code != null) {
          await FirebaseFirestore.instance
              .collection('connection_codes')
              .doc(code)
              .update({
                'targetId': null,
                'targetEmail': FieldValue.delete(),
                'connectedAt': FieldValue.delete(),
                'status': 'active',
              })
              .onError((error, stackTrace) => null);
        }
      }

      if (mounted) {
        setState(() {
          _isConnected = false;
          _connectedName = null;
          _connectedGuardianName = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('연결이 해제되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('연결 해제 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ✅ [추가] 권한 재설정 페이지로 이동
  void _navigateToPermissionSettings(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final role =
        prefs.getString('user_role_${user.uid}') ??
        (_userRole?.toString() ?? '2');

    // 권한 완료 플래그 제거 (다시 설정하도록)
    await prefs.remove('senior_permissions_completed');

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PermissionRequestPage(role: role),
        ),
      ).then((_) {
        _loadUserInfo();
      });
    }
  }

  // ✅ 회원탈퇴 로직 (구글/일반 분기 처리)
  void _showDeleteAccountDialog(BuildContext context, bool isDark) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 로그인 제공업체 확인 (google.com 인지 확인)
    final bool isGoogle = user.providerData.any(
      (userInfo) => userInfo.providerId == 'google.com',
    );

    final passwordController = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text(
            '회원탈퇴',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("정말 탈퇴하시겠습니까?"),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '주의: 모든 데이터(일기, 위치 기록 등)가 영구 삭제되며 복구할 수 없습니다.',
                  style: TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
              // 일반 계정일 경우에만 비밀번호 입력창 표시
              if (!isGoogle) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '비밀번호 확인',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx),
              child: const Text('취소', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: isLoading
                  ? null
                  : () async {
                      // 1. 일반 계정은 비밀번호 확인 필수
                      if (!isGoogle && passwordController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("비밀번호를 입력해주세요")),
                        );
                        return;
                      }

                      setState(() => isLoading = true);

                      try {
                        // 2. 일반 계정 재인증 (Re-authentication)
                        if (!isGoogle && user.email != null) {
                          AuthCredential credential =
                              EmailAuthProvider.credential(
                                email: user.email!,
                                password: passwordController.text.trim(),
                              );
                          await user.reauthenticateWithCredential(credential);
                        }

                        // 3. 서버에 탈퇴 요청 (Firestore, Storage, Auth 삭제)
                        final response = await http.delete(
                          Uri.parse("$_serverUrl/withdraw/${user.uid}"),
                        );

                        if (response.statusCode == 200) {
                          // 4. 로컬 데이터 정리 및 로그아웃
                          if (isGoogle) {
                            await GoogleSignIn().signOut();
                          }
                          await FirebaseAuth.instance.signOut();

                          final prefs = await SharedPreferences.getInstance();
                          await prefs.clear();

                          if (!mounted) return;
                          Navigator.pop(ctx); // 다이얼로그 닫기
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LoginPage(),
                            ),
                            (route) => false,
                          );

                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("회원탈퇴가 완료되었습니다.")),
                          );
                        } else {
                          throw Exception("서버 오류: ${response.body}");
                        }
                      } catch (e) {
                        setState(() => isLoading = false);
                        String msg = "탈퇴 실패: $e";
                        if (e.toString().contains("wrong-password")) {
                          msg = "비밀번호가 올바르지 않습니다.";
                        }
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(msg)));
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text("탈퇴"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey[400] : Colors.grey[600];

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        backgroundColor: scaffoldColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textColor),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          "설정",
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 프로필 카드
              _buildProfileCard(isDark, textColor, subTextColor),

              const SizedBox(height: 20),
              _buildConnectionInfoBox(isDark),

              // ✅ [재수정] 앱 설정 섹션 복구 (알림 설정만 유지)
              const SizedBox(height: 28),
              _buildSectionHeader("앱 설정", isDark),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  // ✅ [개선] AppColors 사용 - 네이비 다크 테마
                  color: isDark ? AppColors.darkSurface : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: isDark
                      ? []
                      : [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: Column(
                  children: [
                    // ✅ [수정] 알림 설정 -> 권한 재설정으로 변경
                    _buildSettingTile(
                      icon: Icons.security_rounded,
                      iconColor: Colors.green,
                      title: "권한 재설정",
                      subtitle: "앱 권한을 다시 설정합니다",
                      isDark: isDark,
                      showArrow: true,
                      onTap: () => _navigateToPermissionSettings(context),
                    ),
                    // ❌ 알림 설정 삭제됨
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 2. 기타 섹션
              _buildSectionHeader("기타", isDark),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  // ✅ [개선] AppColors 사용 - 네이비 다크 테마
                  color: isDark ? AppColors.darkSurface : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: isDark
                      ? []
                      : [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: Column(
                  children: [
                    if (_isConnected) ...[
                      _buildSettingTile(
                        icon: Icons.link_off_rounded,
                        iconColor: Colors.orange,
                        title: "연결 해제",
                        subtitle: _userRole == 1
                            ? "대상자와의 연결을 해제합니다"
                            : "보호자와의 연결을 해제합니다",
                        isDark: isDark,
                        titleColor: Colors.orange,
                        onTap: _disconnectConnection,
                      ),
                      const Divider(height: 1, indent: 60),
                    ],
                    _buildSettingTile(
                      icon: Icons.help_outline_rounded,
                      iconColor: Colors.purple,
                      title: "도움말",
                      subtitle: "앱 사용법 안내",
                      isDark: isDark,
                      showArrow: true,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => HelpScreen(userRole: _userRole),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 60),
                    _buildSettingTile(
                      icon: Icons.info_outline_rounded,
                      iconColor: Colors.teal,
                      title: "앱 정보",
                      subtitle: "버전 1.0.0",
                      isDark: isDark,
                      showArrow: true,
                      onTap: () => _showAboutDialog(context, isDark),
                    ),
                    const Divider(height: 1, indent: 60),
                    _buildSettingTile(
                      icon: Icons.logout_rounded,
                      iconColor: Colors.grey,
                      title: "로그아웃",
                      subtitle: "계정에서 로그아웃합니다",
                      isDark: isDark,
                      onTap: () => _showLogoutDialog(context, isDark),
                    ),
                    const Divider(height: 1, indent: 60),
                    _buildSettingTile(
                      icon: Icons.person_remove_rounded,
                      iconColor: Colors.red,
                      title: "회원탈퇴",
                      subtitle: "계정을 영구적으로 삭제합니다",
                      isDark: isDark,
                      titleColor: Colors.red,
                      // ✅ 새로 만든 탈퇴 로직 연결
                      onTap: () => _showDeleteAccountDialog(context, isDark),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              Center(
                child: Column(
                  children: [
                    Text(
                      "하루매듭 v1.0.0",
                      style: TextStyle(color: subTextColor, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Together for better care",
                      style: TextStyle(
                        color: subTextColor?.withOpacity(0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileCard(bool isDark, Color textColor, Color? subTextColor) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const CareTargetMyPage()),
        );
        // ✅ [추가] 내 정보 화면에서 돌아올 때 프로필 이미지 새로고침
        _loadUserInfo();
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [
                    const Color(0xFF5C4D7D),
                    const Color(0xFF3D3456),
                  ] // 다크모드: 보라/남색 계열
                : [Colors.green.shade400, Colors.green.shade600],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? const Color(0xFF5C4D7D).withOpacity(0.3) // 다크모드 그림자 색상
                  : Colors.green.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              // ✅ [수정] 프로필 이미지 표시
              child: CircleAvatar(
                radius: 28,
                backgroundColor: Colors.grey[200],
                backgroundImage: _profileImagePath != null
                    ? FileImage(File(_profileImagePath!))
                    : null,
                child: _profileImagePath == null
                    ? const Icon(Icons.person, size: 32, color: Colors.grey)
                    : null,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _myName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ✅ [수정] 이메일 개행 방지 - overflow 처리
                  Text(
                    _myEmail,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.8),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.grey[400] : Colors.grey[600],
        ),
      ),
    );
  }

  Widget _buildSettingTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required bool isDark,
    Widget? trailing,
    bool showArrow = false,
    Color? titleColor,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: titleColor ?? (isDark ? Colors.white : Colors.black87),
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.grey[400] : Colors.grey[600],
              ),
            )
          : null,
      trailing:
          trailing ??
          (showArrow
              ? Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: Colors.grey[400],
                )
              : null),
    );
  }

  Widget _buildConnectionInfoBox(bool isDark) {
    if (_userRole == 1) {
      return const SizedBox.shrink();
    }

    if (_userRole == 2 && _connectedGuardianName != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        decoration: BoxDecoration(
          // ✅ [개선] AppColors 사용 - 네이비 다크 테마
          color: isDark ? AppColors.darkSurface : Colors.blue.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.blue.withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          children: [
            Text(
              "현재 연결된 보호자",
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.security,
                  color: isDark ? const Color(0xFF90CAF9) : Colors.blue,
                ),
                const SizedBox(width: 8),
                Text(
                  "$_connectedGuardianName 님",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF90CAF9) : Colors.blue,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
      decoration: BoxDecoration(
        // ✅ [개선] AppColors 사용 - 네이비 다크 테마
        color: isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withOpacity(0.5), width: 1.5),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        children: [
          Text(
            "보호자에게 이 코드를 보여주세요",
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.link,
                color: isDark ? AppColors.successDark : Colors.green,
              ),
              const SizedBox(width: 8),
              Text(
                _inviteCode,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? AppColors.successDark : Colors.green,
                  letterSpacing: 2.0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature 기능은 준비 중입니다.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('정말 로그아웃 하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await GoogleSignIn().signOut(); // 구글 로그아웃
              await FirebaseAuth.instance.signOut(); // 파이어베이스 로그아웃
              if (mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                  (route) => false,
                );
              }
            },
            child: const Text('로그아웃', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.favorite, color: Colors.green),
            SizedBox(width: 8),
            Text('하루매듭'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('버전: 1.0.0'),
            SizedBox(height: 12),
            Text('하루매듭은 가족 간의 소통과 케어를 돕는 앱입니다. 부모님의 안전과 건강을 지키는 데 함께합니다. 💚'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }
}
