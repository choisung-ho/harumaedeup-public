// lib/screens/signup_page.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart' as record_pkg;
import 'dart:convert';

import 'guardian_home_page.dart';
import 'home_page.dart';
import 'location_picker_page.dart';
import '../services/identity_service.dart';
import '../theme_state.dart';

class SignUpPage extends StatefulWidget {
  final String? googleEmail;
  final String? googleName;
  final String? googleUid;

  const SignUpPage({
    super.key,
    this.googleEmail,
    this.googleName,
    this.googleUid,
  });

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  int _role = 1; // 1: 보호자, 2: 대상자

  final _nameController = TextEditingController();
  final _idController = TextEditingController();
  final _pwController = TextEditingController();
  final _pwConfirmController = TextEditingController();
  final _birthController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();

  String? _selectedGender;
  double? _homeLat;
  double? _homeLng;
  bool _isLoading = false;

  // 네이버 API 키 (location_picker_page.dart와 동일하게 유지)
  final String _naverClientId = const String.fromEnvironment('NAVER_CLIENT_ID');
  final String _naverClientSecret = const String.fromEnvironment('NAVER_CLIENT_SECRET');
  final String _serverUrl =
      "https://endpoint-4.example.invalid/";

  bool get _isGoogleSignup => widget.googleEmail != null;

  // ─── 본인 확인 등록 관련 변수 (대상자 모드 전용) ───
  bool _identityRegistered = false; // 본인 확인 등록 완료 여부
  String? _voiceFilePath; // 녹음된 음성 파일 로컬 경로
  List<XFile> _faceCaptures = []; // 촬영된 얼굴 사진 목록
  final record_pkg.AudioRecorder _recorder = record_pkg.AudioRecorder();
  bool _isRecordingPhrase = false;
  double _micProgress = 0;
  Timer? _micTimer;
  static const Duration _micTotal = Duration(seconds: 10);
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraLoading = false;
  bool _isUploadingIdentity = false;

  @override
  void initState() {
    super.initState();
    // ✅ 구글 가입이면 정보 미리 채워넣기
    if (_isGoogleSignup) {
      _idController.text = widget.googleEmail ?? "";
      _nameController.text = widget.googleName ?? "";
    }
  }

  // ✅ [추가] 이메일 형식 검증
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    return emailRegex.hasMatch(email);
  }

  // ✅ [추가] 비밀번호 강도 검증 (8자 이상, 대문자, 특수문자 포함)
  String? _validatePassword(String password) {
    if (password.length < 8) {
      return '비밀번호는 8자리 이상이어야 합니다.';
    }
    if (!password.contains(RegExp(r'[A-Z]'))) {
      return '비밀번호에 대문자를 포함해주세요.';
    }
    if (!password.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]'))) {
      return '비밀번호에 특수문자를 포함해주세요. (!@#\$%^&* 등)';
    }
    return null; // 유효함
  }

  // ✅ [추가] 생년월일 검증 (8자리 숫자, YYYYMMDD 형식)
  String? _validateBirth(String birth) {
    if (birth.length != 8) {
      return '생년월일은 8자리로 입력해주세요. (예: 19900101)';
    }
    if (!RegExp(r'^[0-9]{8}$').hasMatch(birth)) {
      return '생년월일은 숫자만 입력해주세요.';
    }
    // 유효한 날짜인지 확인
    try {
      final year = int.parse(birth.substring(0, 4));
      final month = int.parse(birth.substring(4, 6));
      final day = int.parse(birth.substring(6, 8));
      if (year < 1900 || year > DateTime.now().year) {
        return '올바른 출생연도를 입력해주세요.';
      }
      if (month < 1 || month > 12) {
        return '올바른 월(01~12)을 입력해주세요.';
      }
      if (day < 1 || day > 31) {
        return '올바른 일(01~31)을 입력해주세요.';
      }
    } catch (e) {
      return '올바른 생년월일 형식이 아닙니다.';
    }
    return null; // 유효함
  }

  // ✅ [추가] 전화번호 검증 (10~11자리 숫자)
  String? _validatePhone(String phone) {
    final cleanPhone = phone.replaceAll('-', '');
    if (!RegExp(r'^01[0-9][0-9]{7,8}$').hasMatch(cleanPhone)) {
      return '올바른 전화번호를 입력해주세요. (예: 010-0000-0000)';
    }
    return null; // 유효함
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _pwController.dispose();
    _pwConfirmController.dispose();
    _birthController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _micTimer?.cancel();
    _cameraController?.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ✅ [수정] 지도에서 위치 선택 (my_info_edit_page.dart와 동일한 로직)
  void _onMapSearch() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LocationPickerPage()),
    );

    // ✅ LocationResult 타입으로 받음
    if (result != null && result is LocationResult) {
      setState(() {
        _addressController.text = result.address;
        _homeLat = result.location.latitude;
        _homeLng = result.location.longitude;
      });
      debugPrint(
        "✅ 지도에서 주소 선택 완료: ${result.address} (lat: ${result.location.latitude}, lng: ${result.location.longitude})",
      );
    }
  }

  // ─── 본인 확인 등록 플로우 (대상자 모드 전용) ───

  /// 본인 확인 등록 전체 플로우 시작 (BottomSheet로 표시)
  void _startIdentityRegistration() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _IdentityRegistrationSheet(
        onCompleted: (String voicePath, List<XFile> faces) {
          setState(() {
            _voiceFilePath = voicePath;
            _faceCaptures = faces;
            _identityRegistered = true;
          });
          Navigator.pop(ctx);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('✅ 본인 확인 등록이 완료되었습니다.'),
              backgroundColor: Colors.green.shade700,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 회원가입 성공 후 본인확인 파일을 Firebase Storage에 업로드
  Future<void> _uploadIdentityFiles(String uid) async {
    try {
      // 1. 음성 파일 업로드
      if (_voiceFilePath != null) {
        final file = File(_voiceFilePath!);
        final ref = IdentityService.getVoiceStorageRef(uid);
        final metadata = SettableMetadata(
          contentType: 'audio/m4a',
          customMetadata: {'owner_id': uid},
        );
        await ref.putFile(file, metadata);
        debugPrint("✅ [SignUp] 음성 파일 업로드 완료");
      }

      // 2. 얼굴 사진 업로드
      if (_faceCaptures.isNotEmpty) {
        await IdentityService.uploadFacePhotos(
          uid: uid,
          photos: _faceCaptures,
          onProgress: (current, total, progress) {
            debugPrint('📸 [SignUp] 얼굴 사진 업로드 중: $current/$total');
          },
        );
        debugPrint("✅ [SignUp] 얼굴 사진 업로드 완료");
      }
    } catch (e) {
      debugPrint("⚠️ [SignUp] 본인확인 파일 업로드 실패: $e");
    }
  }

  // ✅ [수정됨] 회원가입 처리 (유효성 검사 강화)
  void _handleSignUp() async {
    final name = _nameController.text.trim();
    final id = _idController.text.trim();
    final pw = _pwController.text.trim();
    final pwConfirm = _pwConfirmController.text.trim();
    final birth = _birthController.text.trim();
    final phone = _phoneController.text.trim();
    final address = _addressController.text.trim();

    // ✅ [개선] 사용자 친화적인 유효성 검사
    // 1. 필수 항목 확인
    if (name.isEmpty) {
      _showValidationError('이름을 입력해주세요.');
      return;
    }
    if (id.isEmpty) {
      _showValidationError('이메일(아이디)을 입력해주세요.');
      return;
    }
    if (_selectedGender == null) {
      _showValidationError('성별을 선택해주세요.');
      return;
    }
    if (birth.isEmpty) {
      _showValidationError('생년월일을 입력해주세요.');
      return;
    }
    if (phone.isEmpty) {
      _showValidationError('전화번호를 입력해주세요.');
      return;
    }
    if (address.isEmpty) {
      _showValidationError('주소를 검색해주세요.');
      return;
    }

    // ✅ [추가] 대상자 모드일 때 본인 확인 등록 필수 검증
    if (_role == 2 && !_identityRegistered) {
      _showValidationError('대상자 모드는 본인 확인 등록을 완료해야 가입할 수 있습니다.');
      return;
    }

    // 2. 이메일 형식 검증 (구글 가입이 아닌 경우)
    if (!_isGoogleSignup && !_isValidEmail(id)) {
      _showValidationError('올바른 이메일 주소를 입력해주세요.\n예: user@example.invalid');
      return;
    }

    // 3. 생년월일 검증
    final birthError = _validateBirth(birth);
    if (birthError != null) {
      _showValidationError(birthError);
      return;
    }

    // 4. 전화번호 검증
    final phoneError = _validatePhone(phone);
    if (phoneError != null) {
      _showValidationError(phoneError);
      return;
    }

    // 5. 비밀번호 검증 (일반 가입만)
    if (!_isGoogleSignup) {
      if (pw.isEmpty || pwConfirm.isEmpty) {
        _showValidationError('비밀번호를 입력해주세요.');
        return;
      }
      final pwError = _validatePassword(pw);
      if (pwError != null) {
        _showValidationError(pwError);
        return;
      }
      if (pw != pwConfirm) {
        _showValidationError('비밀번호가 일치하지 않습니다.');
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      String? fcmToken = await FirebaseMessaging.instance.getToken();

      // 2. 🔥 [핵심] 구글 가입자의 경우, 여기서 파이어베이스 계정 '재생성'
      String? finalUid;

      if (_isGoogleSignup) {
        // 이전에 로그인했던 구글 세션이 남아있는지 확인
        final googleUser = GoogleSignIn().currentUser;

        if (googleUser != null) {
          final googleAuth = await googleUser.authentication;
          final credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );

          // 계정 다시 생성 (로그인)
          final userCredential = await FirebaseAuth.instance
              .signInWithCredential(credential);
          finalUid = userCredential.user?.uid;
        } else {
          // 만약 세션이 끊겼으면 조용히 다시 로그인 시도
          try {
            final newGoogleUser = await GoogleSignIn().signInSilently();
            if (newGoogleUser != null) {
              final googleAuth = await newGoogleUser.authentication;
              final credential = GoogleAuthProvider.credential(
                accessToken: googleAuth.accessToken,
                idToken: googleAuth.idToken,
              );
              final userCredential = await FirebaseAuth.instance
                  .signInWithCredential(credential);
              finalUid = userCredential.user?.uid;
            } else {
              throw "인증 정보가 만료되었습니다. 처음부터 다시 시도해주세요.";
            }
          } catch (e) {
            throw "구글 인증 정보를 찾을 수 없습니다: $e";
          }
        }
      }

      // 3. 서버 전송 데이터 준비
      final Map<String, dynamic> requestData = {
        "userId": id,
        "name": name,
        "gender": _selectedGender,
        "birth": birth,
        "phone": phone,
        "homeAddress": address, // ✅ [추가] 주소 텍스트
        "homeLat": _homeLat ?? 0.0,
        "homeLng": _homeLng ?? 0.0,
        "homeLatitude": _homeLat ?? 0.0, // ✅ [추가] 좌표 필드 동기화
        "homeLongitude": _homeLng ?? 0.0, // ✅ [추가] 좌표 필드 동기화
        "fcmToken": fcmToken,
        "role": _role,
        "guardianId": null,
        "guardianFcmToken": null,
      };

      http.Response response;

      if (_isGoogleSignup) {
        // 재생성된 UID 사용 (없으면 기존 값 사용하되, 위 로직상 finalUid가 있어야 함)
        requestData["uid"] = finalUid ?? widget.googleUid;

        response = await http.post(
          Uri.parse("$_serverUrl/google_signup"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(requestData),
        );
      } else {
        requestData["password"] = pw;
        response = await http.post(
          Uri.parse("$_serverUrl/signup"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(requestData),
        );
      }

      // 4. 결과 처리
      if (response.statusCode == 201) {
        // ✅ [핵심 수정] UID 가져와서 Firestore에 homeAddress 직접 저장
        String? createdUid;

        debugPrint("🔍 [SignUp] 회원가입 성공! homeAddress 저장 시작...");
        debugPrint("🔍 [SignUp] 입력한 주소: $address");
        debugPrint("🔍 [SignUp] 좌표: lat=$_homeLat, lng=$_homeLng");

        try {
          if (_isGoogleSignup) {
            // 구글 가입: 이미 가지고 있는 UID 사용
            final responseBody = jsonDecode(response.body);
            createdUid = responseBody['uid'] ?? finalUid ?? widget.googleUid;
            debugPrint("🔍 [SignUp] 구글가입 UID: $createdUid");
          } else {
            // ✅ [핵심] 일반 가입: Firebase Auth로 로그인해서 UID 가져오기
            debugPrint("🔍 [SignUp] 일반가입 - Firebase 로그인 시도: $id");
            try {
              final userCredential = await FirebaseAuth.instance
                  .signInWithEmailAndPassword(email: id, password: pw);
              createdUid = userCredential.user?.uid;
              debugPrint("✅ [SignUp] 일반가입 UID 획득 성공: $createdUid");

              // ✅ [최적화] Firestore 업데이트 + 본인확인 업로드를 병렬 처리
              if (createdUid != null) {
                final futures = <Future>[];

                if (address.isNotEmpty) {
                  debugPrint("🔍 [SignUp] Firestore 업데이트 시작...");
                  futures.add(
                    FirebaseFirestore.instance
                        .collection('users')
                        .doc(createdUid)
                        .set({
                          'homeAddress': address,
                          'homeLat': _homeLat ?? 0.0,
                          'homeLng': _homeLng ?? 0.0,
                          'homeLatitude': _homeLat ?? 0.0,
                          'homeLongitude': _homeLng ?? 0.0,
                        }, SetOptions(merge: true)),
                  );
                }

                if (_role == 2 && _identityRegistered) {
                  futures.add(_uploadIdentityFiles(createdUid!));
                }

                await Future.wait(futures);
                debugPrint("✅ [SignUp] Firestore + 본인확인 병렬 처리 완료");
              }

              // 바로 로그아웃 (사용자가 직접 로그인하도록)
              await FirebaseAuth.instance.signOut();
              debugPrint("✅ [SignUp] 로그아웃 완료");
            } catch (loginError) {
              debugPrint("⚠️ [SignUp] 로그인으로 UID 가져오기 실패: $loginError");
              // 서버 응답에서 시도
              try {
                final responseBody = jsonDecode(response.body);
                createdUid = responseBody['uid'];
                debugPrint("🔍 [SignUp] 서버 응답에서 UID 추출: $createdUid");
              } catch (e) {
                debugPrint("⚠️ [SignUp] 서버 응답 파싱 실패: $e");
              }
            }
          }
        } catch (e) {
          debugPrint("⚠️ [SignUp] homeAddress 저장 과정 오류: $e");
        }

        // [추가됨] 구글 가입의 경우, 가입을 위해 잠시 생성했던 파이어베이스 세션을 정리함
        if (_isGoogleSignup) {
          // ✅ [최적화] 구글 가입 Firestore + 본인확인 업로드 병렬 처리
          if (createdUid != null) {
            final futures = <Future>[];

            if (address.isNotEmpty) {
              futures.add(
                FirebaseFirestore.instance
                    .collection('users')
                    .doc(createdUid)
                    .set({
                      'homeAddress': address,
                      'homeLat': _homeLat ?? 0.0,
                      'homeLng': _homeLng ?? 0.0,
                      'homeLatitude': _homeLat ?? 0.0,
                      'homeLongitude': _homeLng ?? 0.0,
                    }, SetOptions(merge: true)),
              );
            }

            if (_role == 2 && _identityRegistered) {
              futures.add(_uploadIdentityFiles(createdUid!));
            }

            try {
              await Future.wait(futures);
              debugPrint("✅ [SignUp] 구글가입 병렬 처리 완료");
            } catch (e) {
              debugPrint("⚠️ [SignUp] 구글가입 후처리 일부 실패: $e");
            }
          }

          await FirebaseAuth.instance.signOut();
        }

        if (mounted) {
          // 사용자에게 가입 완료 메시지 표시
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('회원가입이 완료되었습니다. 로그인 해주세요.'),
              duration: Duration(seconds: 2),
            ),
          );

          // 로그인 화면으로 이동
          // Case 1: 로그인 화면에서 push로 들어온 경우 (뒤로가기)
          Navigator.pop(context);

          // Case 2: 만약 명시적으로 로그인 페이지로 보내야 한다면 아래 주석 해제 후 사용
          /*
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const LoginPage()), // LoginPage 클래스 필요
            (route) => false,
          );
          */
        }
      } else {
        final errorBody = jsonDecode(response.body);
        final errorMessage = errorBody['detail'] ?? "가입에 실패했습니다.";
        throw Exception(errorMessage);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      // ✅ [개선] 서버 오류 메시지 파싱 및 사용자 친화적 표시
      String errorMessage = e.toString();
      if (errorMessage.contains('value is not a valid email')) {
        errorMessage = '올바른 이메일 주소를 입력해주세요.';
      } else if (errorMessage.contains('already exists')) {
        errorMessage = '이미 가입된 이메일입니다.';
      } else if (errorMessage.contains('Exception:')) {
        errorMessage = errorMessage.replaceAll('Exception:', '').trim();
      }
      _showValidationError(errorMessage);
    }
  }

  // ✅ [추가] 사용자 친화적인 오류 메시지 표시
  void _showValidationError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;
    // ✅ [추가] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final cardColor = isDark ? AppColors.darkSurface : Colors.white;
    final inputFillColor = isDark ? AppColors.darkSurfaceVariant : null;

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        title: Text(
          '회원가입',
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        centerTitle: true,
        backgroundColor: scaffoldColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(30.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isGoogleSignup)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.blue.shade900.withOpacity(0.3)
                      : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark ? Colors.blue.shade700 : Colors.blue.shade200,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.g_mobiledata,
                      size: 40,
                      color: isDark ? Colors.blue.shade300 : Colors.blue,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "구글 계정으로 간편 가입 중입니다.",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "비밀번호 입력 없이 가입이 가능합니다.",
                      style: TextStyle(color: subTextColor, fontSize: 12),
                    ),
                  ],
                ),
              ),

            _buildRoleSelector(
              primaryColor,
              isDark,
              textColor,
              subTextColor,
              cardColor,
            ),
            const SizedBox(height: 30),

            _buildInput(
              "이름",
              _nameController,
              Icons.person_outline,
              isDark,
              textColor,
              inputFillColor,
            ),
            const SizedBox(height: 20),

            Text(
              "성별",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: Center(
                      child: Text(
                        "남성",
                        style: TextStyle(
                          color: _selectedGender == "Male"
                              ? (isDark ? Colors.white : primaryColor)
                              : textColor,
                        ),
                      ),
                    ),
                    selected: _selectedGender == "Male",
                    onSelected: (selected) =>
                        setState(() => _selectedGender = "Male"),
                    selectedColor: isDark
                        ? primaryColor.withOpacity(0.3)
                        : primaryColor.withOpacity(0.2),
                    backgroundColor: isDark
                        ? AppColors.darkSurfaceVariant
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ChoiceChip(
                    label: Center(
                      child: Text(
                        "여성",
                        style: TextStyle(
                          color: _selectedGender == "Female"
                              ? (isDark ? Colors.white : primaryColor)
                              : textColor,
                        ),
                      ),
                    ),
                    selected: _selectedGender == "Female",
                    onSelected: (selected) =>
                        setState(() => _selectedGender = "Female"),
                    selectedColor: isDark
                        ? primaryColor.withOpacity(0.3)
                        : primaryColor.withOpacity(0.2),
                    backgroundColor: isDark
                        ? AppColors.darkSurfaceVariant
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 아이디(이메일) 필드
            _buildInput(
              "아이디 (이메일)",
              _idController,
              Icons.badge_outlined,
              isDark,
              textColor,
              inputFillColor,
              readOnly: _isGoogleSignup,
              hint: _isGoogleSignup ? "구글 이메일이 자동 입력됩니다" : null,
            ),
            const SizedBox(height: 15),

            // 비밀번호 필드 (구글 아닐 때만)
            if (!_isGoogleSignup) ...[
              _buildInput(
                "비밀번호",
                _pwController,
                Icons.lock_outline,
                isDark,
                textColor,
                inputFillColor,
                obscure: true,
              ),
              const SizedBox(height: 15),
              _buildInput(
                "비밀번호 확인",
                _pwConfirmController,
                Icons.check_circle_outline,
                isDark,
                textColor,
                inputFillColor,
                obscure: true,
              ),
              const SizedBox(height: 15),
            ],

            _buildInput(
              "생년월일 (8자리)",
              _birthController,
              Icons.cake_outlined,
              isDark,
              textColor,
              inputFillColor,
              isNumber: true,
            ),
            const SizedBox(height: 15),
            _buildInput(
              "전화번호",
              _phoneController,
              Icons.phone_android_outlined,
              isDark,
              textColor,
              inputFillColor,
              isNumber: true,
            ),
            const SizedBox(height: 15),

            // ✅ [수정] 지도에서 집 주소 선택 (my_info_edit_page.dart와 동일한 UI)
            Text(
              "집 주소",
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: subTextColor,
              ),
            ),
            const SizedBox(height: 10),
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
                    prefixIcon: Icon(Icons.home_outlined, color: subTextColor),
                    suffixIcon: Icon(Icons.map_rounded, color: primaryColor),
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
                            : Colors.grey.shade300,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: primaryColor, width: 2),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? AppColors.darkSurfaceVariant
                        : Colors.grey[50],
                  ),
                ),
              ),
            ),

            // ✅ [추가] 대상자 모드: 본인 확인 등록 버튼
            if (_role == 2) ...[
              const SizedBox(height: 30),
              _buildIdentityRegistrationSection(
                primaryColor,
                isDark,
                textColor,
                subTextColor,
                cardColor,
              ),
            ],

            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _handleSignUp,
                style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        '가입 완료',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleSelector(
    Color primaryColor,
    bool isDark,
    Color textColor,
    Color subTextColor,
    Color cardColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppColors.darkDivider : Colors.grey.shade200,
        ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, size: 20, color: primaryColor),
              const SizedBox(width: 8),
              Text(
                '역할 선택',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildRoleOption(
                  title: '보호자',
                  subtitle: '가족 돌봄',
                  icon: Icons.security,
                  isSelected: _role == 1,
                  primaryColor: primaryColor,
                  isDark: isDark,
                  textColor: textColor,
                  subTextColor: subTextColor,
                  onTap: () => setState(() => _role = 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildRoleOption(
                  title: '대상자',
                  subtitle: '어르신',
                  icon: Icons.elderly,
                  isSelected: _role == 2,
                  primaryColor: primaryColor,
                  isDark: isDark,
                  textColor: textColor,
                  subTextColor: subTextColor,
                  onTap: () => setState(() => _role = 2),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRoleOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required Color primaryColor,
    required bool isDark,
    required Color textColor,
    required Color subTextColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor.withOpacity(isDark ? 0.3 : 0.1)
              : (isDark
                    ? AppColors.darkSurface
                    : Colors.grey[50]), // ✅ 수정: darkSurface 사용
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? primaryColor
                : (isDark ? AppColors.darkDivider : Colors.grey.shade300),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected
                  ? (isDark ? Colors.white : primaryColor) // ✅ 다크모드 선택 시 흰색
                  : (isDark ? Colors.grey[300] : Colors.grey.shade700),
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: isSelected
                    ? (isDark ? Colors.white : primaryColor) // ✅ 다크모드 선택 시 흰색
                    : (isDark ? Colors.grey[200] : textColor),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: isSelected
                    ? (isDark
                          ? Colors.white70
                          : primaryColor.withOpacity(0.7)) // ✅ 다크모드 선택 시 흰색
                    : (isDark ? Colors.grey[400] : subTextColor),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ✅ [추가] 본인 확인 등록 섹션 위젯 (대상자 모드 전용)
  Widget _buildIdentityRegistrationSection(
    Color primaryColor,
    bool isDark,
    Color textColor,
    Color subTextColor,
    Color cardColor,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _identityRegistered
            ? (isDark
                  ? Colors.green.shade900.withOpacity(0.3)
                  : Colors.green.shade50)
            : cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _identityRegistered
              ? (isDark ? Colors.green.shade700 : Colors.green.shade300)
              : (isDark ? AppColors.darkDivider : Colors.grey.shade200),
        ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _identityRegistered
                    ? Icons.check_circle
                    : Icons.face_retouching_natural,
                size: 22,
                color: _identityRegistered ? Colors.green : primaryColor,
              ),
              const SizedBox(width: 8),
              Text(
                '본인 확인 등록',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const Spacer(),
              if (_identityRegistered)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '완료',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _identityRegistered
                ? '음성 녹음과 얼굴 촬영이 완료되었습니다.'
                : '대상자 모드는 음성 녹음과 얼굴 촬영이 필요합니다.',
            style: TextStyle(color: subTextColor, fontSize: 13),
          ),
          if (_identityRegistered) ...[
            const SizedBox(height: 8),
            Text(
              '🎤 음성 녹음 완료  •  📸 얼굴 사진 ${_faceCaptures.length}장 촬영 완료',
              style: TextStyle(color: Colors.green.shade700, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _identityRegistered
                  ? null
                  : _startIdentityRegistration,
              icon: Icon(
                _identityRegistered ? Icons.check : Icons.fingerprint,
                color: _identityRegistered ? Colors.grey : Colors.white,
              ),
              label: Text(
                _identityRegistered ? '등록 완료됨' : '본인 확인 등록하기',
                style: TextStyle(
                  color: _identityRegistered ? Colors.grey : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _identityRegistered
                    ? (isDark ? Colors.grey.shade800 : Colors.grey.shade200)
                    : Colors.orange.shade700,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInput(
    String label,
    TextEditingController controller,
    IconData icon,
    bool isDark,
    Color textColor,
    Color? inputFillColor, {
    bool obscure = false,
    bool isNumber = false,
    bool readOnly = false,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      readOnly: readOnly,
      style: TextStyle(
        color: readOnly
            ? (isDark ? AppColors.darkOnSurfaceVariant : Colors.grey)
            : textColor,
      ),
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: isDark ? AppColors.darkOnSurfaceVariant : null,
        ),
        hintText: hint,
        hintStyle: TextStyle(
          color: isDark ? AppColors.darkOnSurfaceVariant : null,
        ),
        filled: readOnly || isDark,
        fillColor: readOnly
            ? (isDark
                  ? AppColors.darkSurfaceVariant.withOpacity(0.5)
                  : Colors.grey[100])
            : inputFillColor,
        prefixIcon: Icon(
          icon,
          color: isDark ? AppColors.darkOnSurfaceVariant : null,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? AppColors.darkDivider : Colors.grey.shade300,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? AppColors.darkDivider : Colors.grey.shade300,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark
                ? AppColors.darkPrimary
                : Theme.of(context).primaryColor,
            width: 2,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ✅ [추가] 본인 확인 등록 BottomSheet (음성 녹음 + 얼굴 촬영)
// ═══════════════════════════════════════════════════════════════════════════════
class _IdentityRegistrationSheet extends StatefulWidget {
  final void Function(String voicePath, List<XFile> faces) onCompleted;

  const _IdentityRegistrationSheet({required this.onCompleted});

  @override
  State<_IdentityRegistrationSheet> createState() =>
      _IdentityRegistrationSheetState();
}

class _IdentityRegistrationSheetState
    extends State<_IdentityRegistrationSheet> {
  // 0: 안내, 1: 음성 녹음, 2: 얼굴 촬영
  int _step = 0;

  // --- 음성 관련 ---
  final record_pkg.AudioRecorder _recorder = record_pkg.AudioRecorder();
  String? _audioPath;
  bool _isRecordingPhrase = false;
  double _micProgress = 0;
  Timer? _micTimer;
  static const Duration _micTotal = Duration(seconds: 5);

  // --- 카메라 관련 ---
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraLoading = false;
  final List<XFile> _captures = [];

  // 촬영 가이드 (정면, 왼쪽 측면, 오른쪽 측면)
  static const List<Map<String, dynamic>> _captureGuides = [
    {'label': '정면', 'icon': Icons.face, 'description': '카메라를 정면으로 바라봐주세요'},
    {
      'label': '왼쪽 측면',
      'icon': Icons.turn_slight_left,
      'description': '고개를 왼쪽으로 살짝 돌려주세요',
    },
    {
      'label': '오른쪽 측면',
      'icon': Icons.turn_slight_right,
      'description': '고개를 오른쪽으로 살짝 돌려주세요',
    },
  ];

  @override
  void dispose() {
    _micTimer?.cancel();
    _cameraController?.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _goNextStep() {
    setState(() => _step++);
    if (_step == 2) {
      _ensureCameraReady();
    }
  }

  // ─── 음성 녹음 로직 ───
  Future<void> _requestMicAndStart() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('마이크 권한이 필요합니다.')));
      }
      return;
    }

    final hasPermission = await _recorder.hasPermission();
    if (hasPermission) {
      Directory tempDir = await getTemporaryDirectory();
      String filePath =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        const record_pkg.RecordConfig(encoder: record_pkg.AudioEncoder.aacLc),
        path: filePath,
      );

      setState(() {
        _audioPath = filePath;
        _isRecordingPhrase = true;
        _micProgress = 0;
      });

      _startMicCountdown();
    }
  }

  void _startMicCountdown() {
    _micTimer?.cancel();
    const tick = Duration(milliseconds: 100);
    _micTimer = Timer.periodic(tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _micProgress += tick.inMilliseconds / _micTotal.inMilliseconds;
        if (_micProgress >= 1.0) {
          _micProgress = 1.0;
          _isRecordingPhrase = false;
          timer.cancel();
          _stopMicRecording();
        }
      });
    });
  }

  Future<void> _stopMicRecording() async {
    final path = await _recorder.stop();
    if (path != null) {
      setState(() => _audioPath = path);
    }
  }

  void _onVoiceDoneAndNext() {
    if (_audioPath == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('🎤 음성 녹음 완료!')));
    _goNextStep();
  }

  // ─── 카메라 촬영 로직 ───
  Future<void> _ensureCameraReady() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return;
    }
    setState(() => _cameraLoading = true);
    try {
      _cameras = await availableCameras();
      final front = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );
      _cameraController = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _cameraController!.initialize();
    } catch (e) {
      debugPrint("카메라 에러: $e");
    } finally {
      if (mounted) setState(() => _cameraLoading = false);
    }
  }

  Future<void> _capture() async {
    if (_captures.length >= 3) return; // 3장 제한
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    try {
      final shot = await _cameraController!.takePicture();
      setState(() => _captures.add(shot));
      // 3장 촬영 완료 시 자동으로 등록 완료 처리
      if (_captures.length >= 3) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _audioPath != null) {
            widget.onCompleted(_audioPath!, _captures);
          }
        });
      }
    } catch (e) {
      debugPrint("촬영 실패: $e");
    }
  }

  void _finishRegistration() {
    if (_captures.length < 3 || _audioPath == null) return;
    widget.onCompleted(_audioPath!, _captures);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // 핸들 바
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Text(
                  '본인 확인 등록',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: textColor),
                ),
              ],
            ),
          ),
          // 단계 인디케이터
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _buildStepIndicator(0, '안내', isDark),
                Expanded(
                  child: Divider(
                    color: _step >= 1 ? Colors.green : Colors.grey.shade300,
                  ),
                ),
                _buildStepIndicator(1, '음성', isDark),
                Expanded(
                  child: Divider(
                    color: _step >= 2 ? Colors.green : Colors.grey.shade300,
                  ),
                ),
                _buildStepIndicator(2, '얼굴', isDark),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 컨텐츠
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _buildStepContent(isDark, textColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(int step, String label, bool isDark) {
    final isActive = _step >= step;
    final isCurrent = _step == step;
    return Column(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: isActive ? Colors.green : Colors.grey.shade300,
          child: isCurrent
              ? const Icon(Icons.circle, size: 10, color: Colors.white)
              : isActive
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : Text(
                  '${step + 1}',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isActive ? Colors.green : Colors.grey,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildStepContent(bool isDark, Color textColor) {
    switch (_step) {
      case 0:
        return _buildIntro(textColor);
      case 1:
        return _buildMic(isDark, textColor);
      case 2:
        return _buildCamera(isDark, textColor);
      default:
        return Container();
    }
  }

  Widget _buildIntro(Color textColor) {
    return Column(
      key: const ValueKey('Intro'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.face_retouching_natural,
          size: 80,
          color: Colors.blueAccent,
        ),
        const SizedBox(height: 24),
        Text(
          '본인 확인 준비',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '간단한 음성 녹음과\n얼굴 촬영으로 본인을 확인합니다.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _goNextStep,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              '시작하기',
              style: TextStyle(fontSize: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMic(bool isDark, Color textColor) {
    return Column(
      key: const ValueKey('Mic'),
      children: [
        const SizedBox(height: 20),
        Text(
          '목소리 등록',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(height: 8),
        const Text('아래 문장을 5초간 읽어주세요.', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey.shade800 : Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '"오늘도 좋은 하루 되세요"',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ),
        const Spacer(),
        if (_isRecordingPhrase)
          Column(
            children: [
              LinearProgressIndicator(
                value: _micProgress,
                minHeight: 10,
                color: Colors.red,
              ),
              const SizedBox(height: 8),
              Text(
                '녹음 중... ${(_micProgress * 5).toStringAsFixed(1)}초',
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ),
        const SizedBox(height: 20),
        if (_audioPath == null && !_isRecordingPhrase)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _requestMicAndStart,
              icon: const Icon(Icons.mic, color: Colors.white),
              label: const Text('녹음 시작', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          )
        else if (_audioPath != null && !_isRecordingPhrase)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _onVoiceDoneAndNext,
              icon: const Icon(Icons.arrow_forward, color: Colors.white),
              label: const Text(
                '다음: 얼굴 촬영으로',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildCamera(bool isDark, Color textColor) {
    final currentStep = _captures.length;
    final isAllDone = currentStep >= 3;
    final guide = isAllDone ? null : _captureGuides[currentStep];

    return Column(
      key: const ValueKey('Camera'),
      children: [
        Text(
          '얼굴 등록',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(height: 4),
        // 촬영 진행 인디케이터
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final done = i < currentStep;
            final active = i == currentStep;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: done
                        ? Colors.green
                        : active
                        ? Colors.blueAccent
                        : Colors.grey.shade300,
                    child: done
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : Icon(
                            _captureGuides[i]['icon'] as IconData,
                            size: 18,
                            color: Colors.white,
                          ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _captureGuides[i]['label'] as String,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      color: done
                          ? Colors.green
                          : active
                          ? Colors.blueAccent
                          : Colors.grey,
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        // 카메라 프리뷰
        Expanded(
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.black,
                ),
                child: _cameraLoading
                    ? const Center(child: CircularProgressIndicator())
                    : (_cameraController != null &&
                          _cameraController!.value.isInitialized)
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CameraPreview(_cameraController!),
                      )
                    : const Center(
                        child: Text(
                          '카메라 준비 중...',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
              ),
              // 촬영 가이드 오버레이
              if (guide != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.7),
                        ],
                      ),
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          guide['icon'] as IconData,
                          color: Colors.white,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            guide['description'] as String,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // 완료 오버레이
              if (isAllDone)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 60),
                        SizedBox(height: 12),
                        Text(
                          '3장 촬영 완료!',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 촬영 상태 표시
        Text(
          isAllDone
              ? '✅ 3장 촬영 완료 — 자동으로 등록됩니다'
              : '${currentStep + 1}/3 — ${guide!['label']} 촬영',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isAllDone ? Colors.green : Colors.blueAccent,
          ),
        ),
        const SizedBox(height: 12),
        // 촬영 버튼 (3장 미만일 때만 활성)
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: isAllDone ? null : _capture,
            icon: Icon(
              isAllDone ? Icons.check : Icons.camera_alt,
              color: Colors.white,
            ),
            label: Text(
              isAllDone ? '촬영 완료' : '📸 ${guide!['label']} 촬영하기',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: isAllDone ? Colors.green : Colors.blueAccent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
