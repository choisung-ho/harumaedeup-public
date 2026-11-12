// lib/screens/care_target_my_page.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'my_info_edit_page.dart';
import '../theme_state.dart'; // ✅ 다크모드 지원

// ❌ [삭제됨] 로그아웃/탈퇴 관련 import 제거
// import 'login_page.dart';
// import '../services/withdrawal_service.dart';

class CareTargetMyPage extends StatefulWidget {
  const CareTargetMyPage({super.key});

  @override
  State<CareTargetMyPage> createState() => _CareTargetMyPageState();
}

class _CareTargetMyPageState extends State<CareTargetMyPage> {
  String _nameDisplay = '';
  String _idDisplay = '';
  String _phoneDisplay = '로딩 중...';
  String _birthDisplay = '로딩 중...';
  String _addressDisplay = '로딩 중...';
  String _accountStatus = '';
  String _inviteCode = '확인 중...';
  String _roleDisplay = ''; // ✅ 역할 표시 (어르신/보호자)
  int _userRole = 2; // ✅ 기본값: 어르신(2)

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

  Future<void> _loadUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // ✅ [개선] 프로필 이미지 키 먼저 설정
    bool isGoogleProvider = user.providerData.any(
      (userInfo) => userInfo.providerId == 'google.com',
    );

    setState(() {
      _idDisplay = user.email ?? user.uid;
      _isGoogleAccount = isGoogleProvider;
      _searchKey = isGoogleProvider
          ? 'google_${user.email}'
          : 'general_${user.uid}';

      if (isGoogleProvider) {
        _accountStatus = 'Google 연동됨';
      } else {
        _accountStatus = '일반 회원';
      }
    });

    // ✅ SharedPreferences에서 프로필 이미지 즉시 로드
    final prefs = await SharedPreferences.getInstance();
    final savedImagePath = prefs.getString('user_profile_image_$_searchKey');
    if (savedImagePath != null && mounted) {
      setState(() {
        _profileImagePath = savedImagePath;
      });
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (doc.exists) {
        final data = doc.data()!;

        String name = data['name'] ?? user.displayName ?? '이름 없음';
        String phone = data['phone'] ?? '정보 없음';
        String birth = data['birth'] ?? '정보 없음';

        // ✅ [수정] homeAddress 필드 직접 사용 (전체 주소 표시)
        String address = data['homeAddress'] ?? '';
        if (address.isEmpty) {
          address = "주소 정보 없음";
        }

        String code = data['inviteCode'] ?? data['code'] ?? '코드 없음';

        // ✅ [추가] 역할 정보 로드
        int role = 2; // 기본값: 어르신
        if (data['role'] is int) {
          role = data['role'];
        } else if (data['role'] is String) {
          role = int.tryParse(data['role']) ?? 2;
        }

        if (mounted) {
          setState(() {
            _nameDisplay = name;
            _idDisplay = data['email'] ?? user.email ?? 'ID 없음';
            _phoneDisplay = phone;
            _birthDisplay = birth;
            _addressDisplay = address;
            _inviteCode = code;
            _userRole = role;
            _roleDisplay = role == 1 ? '보호자' : '어르신'; // ✅ 역할에 따라 표시
          });
        }
      }
    } catch (e) {
      debugPrint("DB 로드 실패: $e");
    }
  }

  // ✅ [개선] 프로필 이미지 선택 시 올바른 키로 저장
  Future<void> _pickProfileImage() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile != null) {
        final prefs = await SharedPreferences.getInstance();
        // ✅ 올바른 키로 저장
        await prefs.setString(
          'user_profile_image_$_searchKey',
          pickedFile.path,
        );
        setState(() {
          _profileImagePath = pickedFile.path;
        });
      }
    } catch (e) {
      debugPrint('사진 선택 에러: $e');
    }
  }

  void _navigateToEdit() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MyInfoEditPage()),
    );
    if (result == true || result == null) {
      _loadUserInfo();
    }
  }

  // ✅ [삭제됨] 권한 재설정 기능은 settings_screen.dart로 이동

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
          "내 정보",
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
            // 1. 프로필 사진 섹션
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
            // ✅ [수정] 역할에 따라 동적으로 표시
            Text(
              _roleDisplay.isNotEmpty ? _roleDisplay : '어르신',
              style: TextStyle(fontSize: 14, color: subTextColor),
            ),

            const SizedBox(height: 30),

            Divider(height: 1, color: dividerColor),

            // 2. 내 정보 리스트
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
            ),
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

            // ✅ [삭제] 권한 재설정 버튼 제거 - settings_screen.dart로 이동
            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }

  // ✅ [개선] 다크모드 지원하는 정보 타일
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
          softWrap: true,
        ),
      ),
    );
  }
}
