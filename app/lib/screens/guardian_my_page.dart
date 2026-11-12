// lib/screens/guardian_my_page.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'my_info_edit_page.dart';
import 'connect_care_target_page.dart';
import 'login_page.dart';
import '../services/withdrawal_service.dart';
import '../theme_state.dart'; // ✅ 다크모드 지원

/// ✅ [핵심 추가] 보존해야 할 SharedPreferences 키 목록
const List<String> _keysToPreserve = [
  'recording_folder_uri',
  'recording_folder_path',
  'notification_access_granted',
  'auto_upload_service_start_time',
];

/// ✅ [핵심 추가] SAF 관련 키를 보존하면서 SharedPreferences 초기화
Future<void> _clearPrefsPreservingSafKeys(SharedPreferences prefs) async {
  final Map<String, dynamic> backup = {};
  for (final key in _keysToPreserve) {
    final value = prefs.get(key);
    if (value != null) backup[key] = value;
  }
  await prefs.clear();
  for (final entry in backup.entries) {
    if (entry.value is String)
      await prefs.setString(entry.key, entry.value);
    else if (entry.value is int)
      await prefs.setInt(entry.key, entry.value);
    else if (entry.value is bool)
      await prefs.setBool(entry.key, entry.value);
  }
}

class GuardianMyPage extends StatefulWidget {
  const GuardianMyPage({super.key});

  @override
  State<GuardianMyPage> createState() => _GuardianMyPageState();
}

class _GuardianMyPageState extends State<GuardianMyPage> {
  String _nameDisplay = '';
  String _idDisplay = '';
  String _phoneDisplay = '로딩 중...';
  String _birthDisplay = '로딩 중...';
  String _addressDisplay = '로딩 중...';
  String _accountStatus = '';

  bool _isConnected = false;
  String _targetName = '';
  String _targetId = '';

  String? _profileImagePath;
  String _searchKey = '';
  bool _isGoogleAccount = false;

  final ImagePicker _picker = ImagePicker();
  final Color _primaryColor = const Color(0xFF81C784);

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  // 👤 1. 사용자 정보 불러오기
  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    String currentUser = prefs.getString('currentUser') ?? '';
    String? currentEmail = prefs.getString('currentEmail');
    String docId = (currentEmail != null && currentEmail.isNotEmpty)
        ? currentEmail
        : currentUser;
    if (docId.isEmpty) return;

    // ✅ [개선] 프로필 키 먼저 설정
    String searchKey;
    if (currentEmail != null && currentEmail.contains('@')) {
      searchKey = 'google_$currentEmail';
    } else {
      searchKey = 'general_$docId';
    }
    _searchKey = searchKey;

    setState(() {
      _idDisplay = docId;
      if (currentEmail != null && currentEmail.contains('@')) {
        _nameDisplay = currentUser;
      } else {
        _nameDisplay = prefs.getString('user_name_$docId') ?? currentUser;
      }
      _profileImagePath = prefs.getString('user_profile_image_$_searchKey');
    });

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(docId)
          .get();
      if (doc.exists) {
        final data = doc.data()!;
        final String? serverPw = data['pw'];
        final bool isGoogle = data['isGoogle'] ?? false;

        setState(() {
          _isGoogleAccount = isGoogle;
          if (data['name'] != null) _nameDisplay = data['name'];
          _phoneDisplay = data['phone'] ?? '정보 없음';
          _birthDisplay = data['birth'] ?? '정보 없음';
          _addressDisplay = data['homeAddress'] ?? '주소 정보 없음'; // ✅ 주소 필드

          if (isGoogle || (serverPw == 'GOOGLE_LOGIN')) {
            _accountStatus = 'Google 연동됨';
            _isGoogleAccount = true;
          } else {
            _accountStatus = '일반 회원';
            _isGoogleAccount = false;
          }
        });
      }
    } catch (e) {
      print("정보 로드 실패: $e");
    }
    _checkConnectionStatus(docId);
  }

  // 🔗 2. 대상자 연결 상태 확인
  Future<void> _checkConnectionStatus(String myId) async {
    try {
      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .get();
      if (myDoc.exists) {
        final targetId = myDoc.data()?['careTargetId'];
        if (targetId != null && targetId.toString().isNotEmpty) {
          final targetDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(targetId)
              .get();
          setState(() {
            _isConnected = true;
            _targetName = targetDoc.data()?['name'] ?? '어르신';
            _targetId = targetId;
          });
        } else {
          setState(() {
            _isConnected = false;
          });
        }
      }
    } catch (e) {}
  }

  // 📸 3. 프로필 사진 선택
  Future<void> _pickProfileImage() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'user_profile_image_$_searchKey',
          pickedFile.path,
        );
        setState(() {
          _profileImagePath = pickedFile.path;
        });
      }
    } catch (e) {
      print('사진 선택 에러: $e');
    }
  }

  // 🚪 4. 로그아웃 확인 창
  void _showLogoutConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("로그아웃 하시겠습니까?"),
        content: const Text("로그아웃하면 가족의 비상 알림을 실시간으로 받을 수 없게 됩니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _logout();
            },
            child: const Text("로그아웃", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ⚠️ 5. 회원 탈퇴 확인 창 (WithdrawalService 연결)
  void _showWithdrawConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "정말로 탈퇴하시겠습니까?",
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "탈퇴하시면 모든 돌봄 기록이 삭제되며, 연결된 어르신의 정보를 더 이상 확인할 수 없습니다. 이 작업은 되돌릴 수 없습니다.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("아니오, 계속 쓸래요"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              WithdrawalService.deleteAccount(context); // ✅ 실제 탈퇴 서비스 호출
            },
            child: const Text(
              "네, 탈퇴하겠습니다",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  // 🏃 6. 실제 로그아웃 처리
  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();

    // ✅ [핵심] 자동 로그인 해제
    await prefs.setBool('isLoggedIn', false);
    await prefs.remove('currentUser');

    await _clearPrefsPreservingSafKeys(prefs); // ✅ SAF 키 보존
    await FirebaseAuth.instance.signOut();
    try {
      await GoogleSignIn().signOut();
    } catch (e) {}
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
        (route) => false,
      );
    }
  }

  // 📝 7. 수정/연결 페이지 이동
  void _navigateToEdit() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MyInfoEditPage()),
    );
    if (result == true || result == null) {
      _loadUserInfo();
    }
  }

  void _navigateToConnect() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ConnectCareTargetPage()),
    );
    if (result == true) {
      _loadUserInfo();
    }
  }

  // ✂️ 8. 연결 해제 다이얼로그
  void _disconnectTarget() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("연결 해제"),
        content: Text("$_targetName님과의 연결을 끊으시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final prefs = await SharedPreferences.getInstance();
                String currentId =
                    (prefs.getString('currentEmail') ??
                        prefs.getString('currentUser')) ??
                    '';
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(currentId)
                    .update({'careTargetId': FieldValue.delete()});
                await prefs.remove('user_care_target_id_$currentId');
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('연결이 해제되었습니다.')));
                _loadUserInfo();
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('오류가 발생했습니다.')));
              }
            },
            child: const Text("해제하기", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [개선] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.grey[600];
    final dividerColor = isDark ? AppColors.darkDivider : Colors.grey.shade200;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "마이페이지",
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        centerTitle: true,
        backgroundColor: backgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        actions: [
          TextButton(
            onPressed: _navigateToEdit,
            child: Text(
              "수정",
              style: TextStyle(
                color: _primaryColor,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            // 프로필 사진 섹션
            GestureDetector(
              onTap: _pickProfileImage,
              child: Stack(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark
                          ? AppColors.darkSurfaceVariant
                          : Colors.grey[200],
                      border: Border.all(
                        color: _primaryColor.withOpacity(0.5),
                        width: 1,
                      ),
                      image: _profileImagePath != null
                          ? DecorationImage(
                              image: FileImage(File(_profileImagePath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: _profileImagePath == null
                        ? Icon(Icons.person, size: 60, color: _primaryColor)
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _primaryColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            Text(
              _nameDisplay,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 5),
            Text("보호자님", style: TextStyle(fontSize: 14, color: subTextColor)),
            const SizedBox(height: 30),

            // 대상자 연결 상태 박스
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _isConnected
                    ? (isDark
                          ? const Color(0xFF1B3D2F)
                          : const Color(0xFFE8F5E9))
                    : (isDark ? AppColors.darkSurface : Colors.grey[50]),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isConnected
                      ? Colors.green.shade200
                      : (isDark ? AppColors.darkDivider : Colors.grey.shade300),
                ),
              ),
              child: _isConnected
                  ? Column(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: isDark ? AppColors.successDark : Colors.green,
                          size: 40,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "$_targetName님과 연결됨",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          "현재 안전하게 케어 중입니다.",
                          style: TextStyle(fontSize: 12, color: subTextColor),
                        ),
                        const SizedBox(height: 15),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: _disconnectTarget,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.redAccent),
                              foregroundColor: Colors.redAccent,
                            ),
                            child: const Text("연결 해제"),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Icon(Icons.link_off, color: subTextColor, size: 40),
                        const SizedBox(height: 10),
                        Text(
                          "연결된 대상자가 없습니다",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: subTextColor,
                          ),
                        ),
                        const SizedBox(height: 15),
                        SizedBox(
                          width: double.infinity,
                          height: 45,
                          child: ElevatedButton(
                            onPressed: _navigateToConnect,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryColor,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text(
                              "케어 대상자 연결하기",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),

            const SizedBox(height: 30),
            Divider(height: 1, color: dividerColor),

            // 내 정보 리스트 (개선된 레이아웃)
            _buildInfoTile('아이디', _idDisplay, isDark, textColor, subTextColor),
            Divider(indent: 20, endIndent: 20, height: 1, color: dividerColor),
            _buildInfoTile(
              '전화번호',
              _phoneDisplay,
              isDark,
              textColor,
              subTextColor,
            ),
            Divider(indent: 20, endIndent: 20, height: 1, color: dividerColor),
            _buildInfoTile(
              '생년월일',
              _birthDisplay,
              isDark,
              textColor,
              subTextColor,
            ),
            Divider(indent: 20, endIndent: 20, height: 1, color: dividerColor),
            _buildInfoTile(
              '우리집 주소',
              _addressDisplay,
              isDark,
              textColor,
              subTextColor,
            ), // ✅ 이제 제목 아래 주소 표시됨
            Divider(indent: 20, endIndent: 20, height: 1, color: dividerColor),

            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 30,
                vertical: 10,
              ),
              title: Text(
                '계정 연동',
                style: TextStyle(fontSize: 13, color: subTextColor),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _accountStatus,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: _primaryColor,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: dividerColor),

            const SizedBox(height: 30),

            // 하단 버튼 섹션 (되물어보기 기능 연결)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _showLogoutConfirmDialog, // ✅ 수정됨
                  child: const Text(
                    "로그아웃",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const Text("|", style: TextStyle(color: Colors.grey)),
                TextButton(
                  onPressed: _showWithdrawConfirmDialog, // ✅ 수정됨
                  child: const Text(
                    "회원 탈퇴",
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }

  // 🛠️ 주소가 길어도 잘리지 않도록 개선된 정보 타일 위젯
  // ✅ [개선] 다크모드 지원
  Widget _buildInfoTile(
    String title,
    String content,
    bool isDark,
    Color textColor,
    Color? subTextColor,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
      title: Text(title, style: TextStyle(fontSize: 13, color: subTextColor)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          content,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: textColor,
            height: 1.4,
          ),
          softWrap: true, // 줄바꿈 허용
        ),
      ),
    );
  }
}
