// lib/screens/my_info_edit_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ UID 기반 조회
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_naver_map/flutter_naver_map.dart'; // NLatLng

import 'location_picker_page.dart'; // 지도 화면
import '../theme_state.dart'; // ✅ 다크모드 지원

class MyInfoEditPage extends StatefulWidget {
  const MyInfoEditPage({super.key});

  @override
  State<MyInfoEditPage> createState() => _MyInfoEditPageState();
}

class _MyInfoEditPageState extends State<MyInfoEditPage> {
  // [섹션 1] 기본 정보
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  // [섹션 2] 주소 변경 (단일 컨트롤러로 통합)
  final _addressController = TextEditingController();

  double? _newLat;
  double? _newLng;

  // [섹션 3] 비밀번호
  final _currentPwController = TextEditingController();
  final _newPwController = TextEditingController();
  final _confirmPwController = TextEditingController();

  String _docId = '';
  bool _isLoading = true;
  bool _isGoogleLogin = false;

  // 네이버 API 키 (location_picker_page.dart와 동일하게 유지)
  final String _naverClientId = const String.fromEnvironment('NAVER_CLIENT_ID');
  final String _naverClientSecret = const String.fromEnvironment('NAVER_CLIENT_SECRET');

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose(); // ✅ 하나만 해제하면 됨
    _currentPwController.dispose();
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  // 📂 1. 기존 데이터 불러오기 (✅ 개선: UID 기반 + 일반 로그인 지원)
  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    final prefs = await SharedPreferences.getInstance();

    // ✅ UID 우선, 없으면 SharedPreferences 사용
    String? currentId;
    if (user != null) {
      currentId = user.uid;
    } else {
      String? email = prefs.getString('currentEmail');
      String userPref = prefs.getString('currentUser') ?? '';
      currentId = (email != null && email.isNotEmpty) ? email : userPref;
    }

    if (currentId == null || currentId.isEmpty) return;
    setState(() => _docId = currentId!);

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentId)
          .get();
      if (doc.exists) {
        final data = doc.data()!;

        // ✅ [핵심 수정] Firebase Auth provider로 구글 로그인 여부 정확히 판단
        bool isGoogleProvider = false;
        if (user != null) {
          for (final provider in user.providerData) {
            if (provider.providerId == 'google.com') {
              isGoogleProvider = true;
              break;
            }
          }
        }

        // DB의 isGoogle 필드도 참고 (백업)
        final bool isGoogleFromDb = data['isGoogle'] ?? false;

        setState(() {
          _nameController.text = data['name'] ?? '';
          _phoneController.text = data['phone'] ?? '';

          // ✅ 기존 주소를 하나의 입력창에 불러옴
          _addressController.text = data['homeAddress'] ?? '';

          _newLat = data['homeLatitude'];
          _newLng = data['homeLongitude'];

          // ✅ [핵심 수정] 구글 로그인 판단:
          // Firebase Auth의 provider가 google.com이거나, DB에 isGoogle=true인 경우만
          _isGoogleLogin = isGoogleProvider || isGoogleFromDb;
        });

        debugPrint(
          "✅ [MyInfoEdit] isGoogleProvider=$isGoogleProvider, isGoogleFromDb=$isGoogleFromDb, _isGoogleLogin=$_isGoogleLogin",
        );
      }
    } catch (e) {
      debugPrint("정보 로드 실패: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ✅ 전화번호 형식 검증
  bool _isValidPhoneNumber(String phone) {
    // 한국 전화번호 형식 검증 (010, 011, 016, 017, 018, 019 + 7~8자리)
    final phoneRegex = RegExp(r'^01[0-9]-?[0-9]{3,4}-?[0-9]{4}$');
    // 하이픈 제거 후에도 검증
    final cleanPhone = phone.replaceAll('-', '');
    final cleanPhoneRegex = RegExp(r'^01[0-9][0-9]{7,8}$');
    return phoneRegex.hasMatch(phone) || cleanPhoneRegex.hasMatch(cleanPhone);
  }

  // 📱 2. 정보 통합 수정 (전화번호 + 주소)
  Future<void> _updateAllInfo() async {
    if (_phoneController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('전화번호를 입력해주세요.')));
      return;
    }

    // ✅ 전화번호 형식 검증 추가
    if (!_isValidPhoneNumber(_phoneController.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '올바른 전화번호 형식을 입력해주세요.\n예: 010-0000-0000 또는 010-0000-0000',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final updateData = <String, dynamic>{
        'phone': _phoneController.text.trim(),
      };

      // 주소가 있으면 함께 업데이트
      if (_addressController.text.isNotEmpty) {
        updateData['homeAddress'] = _addressController.text.trim();
        // ✅ 좌표 필드 동기화 (homeLatitude/homeLongitude + homeLat/homeLng)
        if (_newLat != null) {
          updateData['homeLatitude'] = _newLat;
          updateData['homeLat'] = _newLat; // 위치 서비스에서 사용하는 필드
        }
        if (_newLng != null) {
          updateData['homeLongitude'] = _newLng;
          updateData['homeLng'] = _newLng; // 위치 서비스에서 사용하는 필드
        }
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(_docId)
          .update(updateData);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('정보가 수정되었습니다.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("수정 실패: $e")));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🗺️ 3. 지도에서 위치 선택 후 주소 변환 (Reverse Geocoding)
  Future<void> _getAddressFromCoords(double lat, double lng) async {
    setState(() => _isLoading = true);
    try {
      // ✅ [수정] 올바른 Reverse Geocoding API URL
      final url = Uri.parse(
        "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc?coords=$lng,$lat&output=json&orders=roadaddr,addr",
      );
      final response = await http.get(
        url,
        headers: {
          "X-NCP-APIGW-API-KEY-ID": _naverClientId,
          "X-NCP-APIGW-API-KEY": _naverClientSecret,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List;

        if (results.isNotEmpty) {
          final region = results[0]['region'];
          final land = results[0]['land'];

          // 주소 조합 (시/도 + 구/군 + 동/읍/면 + 도로명 + 건물번호)
          String area1 = region['area1']['name'] ?? '';
          String area2 = region['area2']['name'] ?? '';
          String area3 = region['area3']['name'] ?? '';
          String landName = land?['name'] ?? '';
          String landNum = land?['number1'] ?? '';

          String addr = "$area1 $area2 $area3 $landName $landNum".trim();

          // ✅ [수정] 주소가 비어있으면 기본 주소 표시
          if (addr.trim().isEmpty) {
            addr = "$area1 $area2 $area3".trim();
          }

          setState(() {
            _addressController.text = addr; // ✅ 주소창에 자동 입력
            _newLat = lat;
            _newLng = lng;
          });

          debugPrint("✅ 주소 설정 완료: $addr (lat: $lat, lng: $lng)");
        } else {
          // 결과가 없으면 좌표만 저장
          setState(() {
            _addressController.text = "주소 정보 없음";
            _newLat = lat;
            _newLng = lng;
          });
        }
      } else {
        // ✅ API 실패 시 좌표 기반 주소로 대체
        debugPrint("❌ Reverse Geocoding 실패: ${response.statusCode}");
        setState(() {
          _addressController.text =
              "위치: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}";
          _newLat = lat;
          _newLng = lng;
        });
      }
    } catch (e) {
      debugPrint("주소 변환 에러: $e");
      // ✅ 에러 발생 시에도 좌표 기반 주소로 대체
      setState(() {
        _addressController.text =
            "위치: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}";
        _newLat = lat;
        _newLng = lng;
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🔍 지도 열기 버튼 동작
  void _onMapSearch() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LocationPickerPage()),
    );

    // ✅ LocationResult 타입으로 받음
    if (result != null && result is LocationResult) {
      setState(() {
        _addressController.text = result.address;
        _newLat = result.location.latitude;
        _newLng = result.location.longitude;
      });
      debugPrint(
        "✅ 지도에서 주소 선택 완료: ${result.address} (lat: ${result.location.latitude}, lng: ${result.location.longitude})",
      );
    } else if (result != null && result is NLatLng) {
      // 호환성: 기존 NLatLng 타입인 경우 reverse geocoding 수행
      await _getAddressFromCoords(result.latitude, result.longitude);
    }
  }

  // ✅ [삭제됨] _updateAddressInfo 함수 제거 - _updateAllInfo로 통합

  // 🔐 5. 비밀번호 변경 (✅ Firebase Auth 사용)
  Future<void> _updatePassword() async {
    if (_currentPwController.text.isEmpty || _newPwController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('모든 비밀번호 필드를 입력해주세요.')));
      return;
    }
    if (_newPwController.text != _confirmPwController.text) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('새 비밀번호가 불일치합니다.')));
      return;
    }
    if (_newPwController.text.length < 6) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('비밀번호는 6자 이상이어야 합니다.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.email == null) {
        throw "로그인 정보를 찾을 수 없습니다.";
      }

      // ✅ [핵심] Firebase Auth로 현재 비밀번호 확인 (재인증)
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: _currentPwController.text.trim(),
      );

      try {
        await user.reauthenticateWithCredential(credential);
        debugPrint("✅ 현재 비밀번호 확인 성공");
      } on FirebaseAuthException catch (e) {
        if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
          throw "현재 비밀번호가 일치하지 않습니다.";
        } else {
          throw "인증 실패: ${e.message}";
        }
      }

      // ✅ [핵심] Firebase Auth에서 비밀번호 변경
      await user.updatePassword(_newPwController.text.trim());
      debugPrint("✅ Firebase Auth 비밀번호 변경 성공");

      // Firestore의 pw 필드도 업데이트 (백업용)
      try {
        await FirebaseFirestore.instance.collection('users').doc(_docId).update(
          {'pw': _newPwController.text.trim()},
        );
        debugPrint("✅ Firestore pw 필드도 업데이트 완료");
      } catch (e) {
        debugPrint("⚠️ Firestore pw 업데이트 실패 (무시): $e");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 비밀번호가 변경되었습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
      _currentPwController.clear();
      _newPwController.clear();
      _confirmPwController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🔑 [추가] 비밀번호 찾기 다이얼로그 (로그인 페이지와 동일한 로직)
  void _showFindPasswordDialog() {
    final resetEmailController = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 현재 로그인된 이메일 가져오기
    final currentEmail = FirebaseAuth.instance.currentUser?.email ?? '';
    resetEmailController.text = currentEmail;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
        title: Text(
          '비밀번호 재설정',
          style: TextStyle(
            color: isDark ? AppColors.darkOnSurface : Colors.black87,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '현재 비밀번호를 모르시는 경우,\n가입하신 이메일로 재설정 링크를 보내드립니다.',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.darkOnSurfaceVariant : Colors.black54,
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: resetEmailController,
              style: TextStyle(
                color: isDark ? AppColors.darkOnSurface : Colors.black87,
              ),
              decoration: InputDecoration(
                hintText: '이메일 입력',
                hintStyle: TextStyle(
                  color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
                ),
                border: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: isDark ? AppColors.darkDivider : Colors.grey,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: isDark ? AppColors.darkDivider : Colors.grey,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: isDark
                        ? AppColors.darkPrimary
                        : const Color(0xFF81C784),
                    width: 2,
                  ),
                ),
                filled: isDark,
                fillColor: isDark ? AppColors.darkSurfaceVariant : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              '취소',
              style: TextStyle(
                color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? AppColors.darkPrimary
                  : const Color(0xFF81C784),
            ),
            onPressed: () async {
              final email = resetEmailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(
                  dialogContext,
                ).showSnackBar(const SnackBar(content: Text('이메일을 입력해주세요.')));
                return;
              }

              Navigator.pop(dialogContext);

              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: email,
                );

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '✅ $email(으)로 메일을 보냈습니다.\n스팸메일함도 꼭 확인해주세요!',
                      ),
                      backgroundColor: Colors.green,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              } on FirebaseAuthException catch (e) {
                String errorMessage = '메일 전송 실패';
                if (e.code == 'user-not-found') {
                  errorMessage = '❌ 가입되지 않은 이메일입니다.';
                } else if (e.code == 'invalid-email') {
                  errorMessage = '❌ 잘못된 이메일 형식입니다.';
                }

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(errorMessage),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('메일 전송 실패: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
            child: const Text('링크 전송', style: TextStyle(color: Colors.white)),
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
    final surfaceColor = isDark ? AppColors.darkSurface : Colors.grey[50];
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.grey[600];
    final primaryColor = const Color(0xFF81C784);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "정보 수정",
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
        ),
        backgroundColor: backgroundColor,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- 섹션 1: 정보 수정 (통합) ---
                    Text(
                      "내 정보 수정",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ✅ 이름 (읽기 전용)
                    _buildTextField(
                      "이름",
                      _nameController,
                      Icons.person_outline,
                      isDark: isDark,
                      textColor: textColor,
                      surfaceColor: surfaceColor,
                      readOnly: true, // ✅ 읽기 전용
                      hint: "이름은 수정할 수 없습니다",
                    ),
                    const SizedBox(height: 15),

                    // 전화번호
                    _buildTextField(
                      "전화번호",
                      _phoneController,
                      Icons.phone_android,
                      isDark: isDark,
                      textColor: textColor,
                      surfaceColor: surfaceColor,
                      isNumber: true,
                    ),

                    const SizedBox(height: 20),

                    // --- 집 주소 변경 ---
                    Text(
                      "집 주소",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: subTextColor,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ✅ 지도 버튼 기능을 겸하는 주소 입력창
                    GestureDetector(
                      onTap: _onMapSearch, // 터치 시 지도 열기
                      child: AbsorbPointer(
                        child: TextField(
                          controller: _addressController,
                          readOnly: true,
                          style: TextStyle(color: textColor),
                          decoration: InputDecoration(
                            hintText: "터치하여 지도에서 위치 선택",
                            hintStyle: TextStyle(color: subTextColor),
                            prefixIcon: Icon(
                              Icons.home_outlined,
                              color: subTextColor,
                            ),
                            suffixIcon: Icon(
                              Icons.map_rounded,
                              color: primaryColor,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: isDark
                                    ? AppColors.darkDivider
                                    : Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: isDark
                                    ? AppColors.darkDivider
                                    : Colors.grey.shade200,
                              ),
                            ),
                            filled: true,
                            fillColor: surfaceColor,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 25),

                    // ✅ 통합 저장 버튼
                    _buildSubmitButton(
                      "정보 저장하기",
                      primaryColor,
                      _updateAllInfo,
                      isDark: isDark,
                    ),

                    // --- 섹션 2: 비밀번호 변경 (일반 로그인만) ---
                    if (!_isGoogleLogin) ...[
                      const SizedBox(height: 40),
                      Divider(
                        thickness: 1,
                        color: isDark
                            ? AppColors.darkDivider
                            : Colors.grey.shade300,
                      ),
                      const SizedBox(height: 30),
                      Text(
                        "비밀번호 변경",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _buildTextField(
                        "현재 비밀번호",
                        _currentPwController,
                        Icons.lock_outline,
                        isDark: isDark,
                        textColor: textColor,
                        surfaceColor: surfaceColor,
                        isObscure: true,
                      ),
                      const SizedBox(height: 15),
                      _buildTextField(
                        "새 비밀번호",
                        _newPwController,
                        Icons.vpn_key_outlined,
                        isDark: isDark,
                        textColor: textColor,
                        surfaceColor: surfaceColor,
                        isObscure: true,
                      ),
                      const SizedBox(height: 15),
                      _buildTextField(
                        "비밀번호 확인",
                        _confirmPwController,
                        Icons.check_circle_outline,
                        isDark: isDark,
                        textColor: textColor,
                        surfaceColor: surfaceColor,
                        isObscure: true,
                      ),
                      const SizedBox(height: 20),
                      _buildSubmitButton(
                        "비밀번호 수정",
                        isDark
                            ? AppColors.darkSurfaceVariant
                            : Colors.grey[800]!,
                        _updatePassword,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 15),
                      // ✅ [추가] 비밀번호 찾기 버튼
                      Center(
                        child: TextButton(
                          onPressed: _showFindPasswordDialog,
                          child: Text(
                            '현재 비밀번호를 모르시나요?',
                            style: TextStyle(
                              color: isDark
                                  ? AppColors.darkPrimary
                                  : const Color(0xFF81C784),
                              fontSize: 14,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 50),
                  ],
                ),
              ),
            ),
    );
  }

  // ✅ [개선] 다크모드 지원 버튼
  Widget _buildSubmitButton(
    String label,
    Color color,
    VoidCallback onPressed, {
    bool isDark = false,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  // ✅ [개선] 다크모드 지원 + 읽기전용 옵션 추가
  Widget _buildTextField(
    String label,
    TextEditingController controller,
    IconData icon, {
    bool isObscure = false,
    bool isNumber = false,
    String? hint,
    bool isDark = false,
    Color? textColor,
    Color? surfaceColor,
    bool readOnly = false, // ✅ 읽기 전용 옵션
  }) {
    final effectiveTextColor =
        textColor ?? (isDark ? AppColors.darkOnSurface : Colors.black87);
    final effectiveSurfaceColor =
        surfaceColor ?? (isDark ? AppColors.darkSurface : Colors.grey[50]);
    final borderColor = isDark ? AppColors.darkDivider : Colors.grey.shade200;
    final hintColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.grey[600];

    return TextField(
      controller: controller,
      obscureText: isObscure,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      readOnly: readOnly, // ✅ 읽기 전용
      style: TextStyle(color: readOnly ? hintColor : effectiveTextColor),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: hintColor),
        hintText: hint,
        hintStyle: TextStyle(color: hintColor),
        prefixIcon: Icon(icon, color: hintColor),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? AppColors.darkPrimary : const Color(0xFF81C784),
          ),
        ),
        filled: true,
        fillColor: readOnly
            ? (isDark ? AppColors.darkBackground : Colors.grey[200])
            : effectiveSurfaceColor,
      ),
    );
  }
}
