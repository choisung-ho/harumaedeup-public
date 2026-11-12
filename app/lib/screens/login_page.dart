// lib/screens/login_page.dart

import 'dart:io'; // ✅ Platform 사용을 위해 추가
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:device_info_plus/device_info_plus.dart'; // ✅ [필수] 기기 정보 패키지 추가

import 'home_page.dart'; // [환자용]
import 'guardian_home_page.dart'; // [보호자용]
import 'terms_agreement_page.dart'; // [필수] 약관 동의 페이지
import 'permission_request_page.dart'; // ✅ [추가] 권한 요청 페이지
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

// ✅ [추가됨] 서비스 import
import '../services/auto_upload_service.dart'; // ✅ [추가] 자동 업로드 서비스
import '../services/sms_listener_service.dart'; // ✅ [추가] SMS 리스너 서비스
import '../services/fcm_token_sync_service.dart'; // ✅ [추가] FCM 토큰 동기화 서비스
import '../services/permission_service.dart'; // ✅ [추가] 권한 서비스

/// ✅ [핵심 추가] 보존해야 할 SharedPreferences 키 목록
const List<String> _keysToPreserve = [
  'recording_folder_uri', // SAF 통화 녹음 폴더 URI
  'recording_folder_path', // SAF 통화 녹음 폴더 경로
  'notification_access_granted', // 알림 접근 권한
  'auto_upload_service_start_time', // 자동 업로드 서비스 시작 시간
];

/// ✅ [핵심 추가] SAF 관련 키를 보존하면서 SharedPreferences 초기화
Future<void> _clearPrefsPreservingSafKeys(SharedPreferences prefs) async {
  // 1. 보존할 값들을 먼저 백업
  final Map<String, dynamic> backup = {};
  for (final key in _keysToPreserve) {
    final value = prefs.get(key);
    if (value != null) {
      backup[key] = value;
      debugPrint("🔒 [Prefs] 보존: $key = $value");
    }
  }

  // 2. 전체 클리어
  await prefs.clear();

  // 3. 백업한 값들 복원
  for (final entry in backup.entries) {
    if (entry.value is String) {
      await prefs.setString(entry.key, entry.value);
    } else if (entry.value is int) {
      await prefs.setInt(entry.key, entry.value);
    } else if (entry.value is bool) {
      await prefs.setBool(entry.key, entry.value);
    } else if (entry.value is double) {
      await prefs.setDouble(entry.key, entry.value);
    }
    debugPrint("✅ [Prefs] 복원: ${entry.key} = ${entry.value}");
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _pwController = TextEditingController();
  bool _isObscure = true;
  bool _isAutoLogin = true; // ✅ [핵심 수정] 자동로그인 기본값 true로 변경 (백그라운드 서비스 유지용)
  bool _isLoading = false;

  // ✅ [수정됨] 로그인 후 처리 (FCM 토큰 갱신 및 상대방 동기화)
  Future<void> _initializeAfterLogin(String docId) async {
    try {
      // ✅ [변경] 권한 요청은 PermissionRequestPage에서 사용자가 버튼 클릭 시 요청
      // 여기서는 FCM 토큰만 업데이트
      await FcmTokenSyncService().updateTokenOnLogin(docId);

      debugPrint('✅ 로그인 후 FCM 토큰 업데이트 완료');
    } catch (e) {
      debugPrint("로그인 후 초기화 실패: $e");
    }
  }

  // ✅ [수정됨] 일반 로그인 로직 (UID로 문서 찾기)
  void _handleGeneralLogin() async {
    final inputId = _idController.text.trim(); // 이메일 형식 그대로 사용 (소문자 변환 X)
    final inputPw = _pwController.text.trim();

    if (inputId.isEmpty || inputPw.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('아이디와 비밀번호를 입력해주세요.')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Firebase Auth 인증 시도
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: inputId, password: inputPw);

      // ✅ [핵심 수정] 로그인 성공 후, '이메일'이 아니라 'UID'로 내 정보를 찾아야 함!
      final user = userCredential.user;
      if (user == null) throw "유저 정보를 가져올 수 없습니다.";

      // 2. Firestore에서 내 정보 가져오기 (문서 ID = UID)
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (doc.exists) {
        final prefs = await SharedPreferences.getInstance();
        await _clearPrefsPreservingSafKeys(prefs); // ✅ SAF 키 보존

        await _processLoginSuccess(
          prefs,
          user.uid, // 문서를 찾을 때 사용하는 진짜 ID (UID)
          doc.data()?['name'],
          roleFromDb: doc.data()?['role'],
        );
      } else {
        // 혹시라도 문서 ID가 UID가 아닐 경우를 대비해 이메일로 비상 검색
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .where('email', isEqualTo: inputId)
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final userDoc = querySnapshot.docs.first;
          final prefs = await SharedPreferences.getInstance();
          await _clearPrefsPreservingSafKeys(prefs); // ✅ SAF 키 보존

          await _processLoginSuccess(
            prefs,
            userDoc.id,
            userDoc.data()['name'],
            roleFromDb: userDoc.data()['role'],
          );
        } else {
          throw "회원 정보를 찾을 수 없습니다.";
        }
      }
    } on FirebaseAuthException catch (e) {
      String message = "로그인 실패";
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        message = "아이디 또는 비밀번호를 확인해주세요.";
      } else if (e.code == 'wrong-password') {
        message = "비밀번호가 틀렸습니다.";
      } else if (e.code == 'invalid-email') {
        message = "이메일 형식이 올바르지 않습니다.";
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("오류 발생: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _processLoginSuccess(
    SharedPreferences prefs,
    String docId, // UID
    String? name, {
    var roleFromDb, // int or String 호환
  }) async {
    // ✅ [핵심 수정] 자동 로그인 체크 여부에 따라 저장
    await prefs.setBool('isLoggedIn', _isAutoLogin);

    // ✅ [핵심] UID를 currentUser에 저장 (자동 로그인 시 이 값으로 역할 찾음)
    await prefs.setString('currentUser', docId);
    // 표시용 이메일 저장
    await prefs.setString('currentEmail', _idController.text.trim());
    if (name != null) await prefs.setString('userName', name);

    // ✅ [필수 추가] 백그라운드 서비스가 사용할 환자 ID 저장
    // 이 값이 있어야 앱이 꺼져도 '누구를 감시할지' 알 수 있습니다.
    await prefs.setString('current_patient_id', docId);

    // ✅ [핵심] 역할은 UID 기준으로 저장
    String realRole = roleFromDb?.toString() ?? '0';
    await prefs.setString('user_role_$docId', realRole);

    // =========================================================================
    // 🔑 [핵심 추가] 중복 로그인 방지를 위한 기기 ID 저장
    // =========================================================================
    try {
      final deviceInfo = DeviceInfoPlugin();
      String deviceId = '';

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id; // 안드로이드 고유 ID
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'unknown_ios';
      }

      // DB에 기기 ID 업데이트 (이제 이 기기가 '진짜 주인'이 됨)
      await FirebaseFirestore.instance.collection('users').doc(docId).update({
        'deviceId': deviceId,
        'lastLogin': FieldValue.serverTimestamp(),
      });
      debugPrint("📱 [Login] 기기 ID 등록 완료: $deviceId");
    } catch (e) {
      debugPrint("⚠️ 기기 ID 등록 실패: $e");
    }
    // =========================================================================

    debugPrint(
      "✅ [Login] 저장 완료: UID=$docId, role=$realRole, autoLogin=$_isAutoLogin",
    );

    await _initializeAfterLogin(docId);

    if (!mounted) return;
    _navigateByRole(realRole);
  }

  // 구글 로그인 로직 (수정됨: 신규 유저면 계정 삭제 후 이동)
  void _handleGoogleLogin() async {
    setState(() => _isLoading = true);
    try {
      // 1. 구글 인증
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 2. 파이어베이스 임시 로그인 (DB 확인용)
      final userCredential = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCredential.user;

      if (user == null) throw "구글 로그인 정보를 가져올 수 없습니다.";

      // 3. DB 조회
      final docSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final prefs = await SharedPreferences.getInstance();
      await _clearPrefsPreservingSafKeys(prefs); // ✅ SAF 키 보존

      // 4. 기존 회원인지 확인
      if (docSnapshot.exists) {
        var existingRole = docSnapshot.data()?['role']?.toString() ?? '0';

        // 역할이 없으면(0) -> 회원가입 덜 된 상태 -> 계정 삭제 후 가입 페이지로
        if (existingRole == '0') {
          await user.delete(); // 🔥 [핵심] 유령 계정 삭제

          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TermsAgreementPage(
                googleEmail: user.email,
                googleName: user.displayName,
              ),
            ),
          );
        } else {
          // 정상 회원이면 로그인 진행
          await _processLoginSuccess(
            prefs,
            user.uid,
            googleUser.displayName,
            roleFromDb: existingRole,
          );
        }
      } else {
        // 5. 신규 회원 -> 계정 삭제 후 가입 페이지로
        await user.delete(); // 🔥 [핵심] 유령 계정 삭제

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TermsAgreementPage(
              googleEmail: user.email,
              googleName: user.displayName,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // user.delete() 에러 처리 등을 위해 로그 출력
        debugPrint("구글 로그인 에러: $e");
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('구글 로그인에 실패했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ✅ [수정됨] 역할별 네비게이션 로직 (권한 확인 후 분기)
  void _navigateByRole(String role) async {
    final permissionService = PermissionService();

    // ✅ [핵심] role에 맞는 권한 페이지 표시 필요 여부 확인
    final shouldShowPermission = await permissionService
        .shouldShowPermissionPageForRole(role);

    if (shouldShowPermission) {
      // 권한 설정 필요 -> 권한 페이지로 이동
      debugPrint("📱 [Login] role=$role 권한 페이지로 이동");
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => PermissionRequestPage(role: role),
        ),
        (route) => false,
      );
      return;
    }

    // 권한 이미 설정됨 -> 홈으로 이동
    if (role == '1') {
      // 보호자 -> 홈으로 (자동 업로드 비활성화)
      debugPrint("👨‍👩‍👧 [Guardian Login] 자동 업로드 비활성화");
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const GuardianHomePage()),
        (route) => false,
      );
    } else if (role == '2') {
      // ✅ [수정] 대상자 로그인 → 바로 홈으로 이동 (본인확인은 회원가입 시 완료됨)
      debugPrint("👴 [Senior Login] 자동 업로드 서비스 초기화");
      await AutoUploadService().initialize();
      await SmsListenerService().initialize();

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const DiaryHomePage()),
        (route) => false,
      );
    } else {
      // 그 외 (약관 미동의 등)
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const TermsAgreementPage()),
      );
    }
  }

  // 🔑 [수정됨] 비밀번호 찾기 다이얼로그 (DB 필드명 'email'로 매칭)
  // 🔑 비밀번호 찾기 (DB 조회 제거 & 인증 에러 처리 강화)
  // 🔑 비밀번호 찾기 (context 충돌 해결 버전)
  void _showFindPasswordDialog() {
    final resetEmailController = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 아이디 입력창에 값이 있으면 가져오기
    if (_idController.text.isNotEmpty) {
      resetEmailController.text = _idController.text;
    }

    showDialog(
      context: context, // 여기는 부모(로그인 페이지)의 context
      builder: (dialogContext) => AlertDialog(
        // ⚠️ [수정] 이름을 dialogContext로 변경!
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
              '가입하신 이메일 주소를 입력해주세요.\n비밀번호 재설정 링크를 보내드립니다.',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.darkOnSurfaceVariant : Colors.black54,
              ),
            ),
            const SizedBox(height: 10),
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
                        : Theme.of(context).primaryColor,
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
            // 닫을 때는 dialogContext 사용
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              '취소',
              style: TextStyle(
                color: isDark
                    ? AppColors.darkOnSurfaceVariant
                    : Colors.grey[600],
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? AppColors.darkPrimary
                  : const Color(0xFF81C784),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final email = resetEmailController.text.trim();
              if (email.isEmpty) {
                // 여기는 아직 다이얼로그가 살아있으니 dialogContext 써도 됨 (혹은 context도 가능)
                ScaffoldMessenger.of(
                  dialogContext,
                ).showSnackBar(const SnackBar(content: Text('이메일을 입력해주세요.')));
                return;
              }

              // 1. 팝업 먼저 닫기 (dialogContext 사용)
              Navigator.pop(dialogContext);

              try {
                // 2. 메일 전송
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: email,
                );

                // 3. 성공 스낵바 (⚠️ 중요: 여기서는 부모의 context 사용!)
                if (mounted) {
                  // builder 변수명을 바꿨기 때문에, 여기서 'context'는 자동으로 로그인 페이지의 context가 됨
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
                String errorMessage = "메일 전송 실패";
                if (e.code == 'user-not-found') {
                  errorMessage = "❌ 가입되지 않은 이메일입니다.";
                } else if (e.code == 'invalid-email') {
                  errorMessage = "❌ 잘못된 이메일 형식입니다.";
                }

                print("비밀번호 찾기 에러: ${e.code}, ${e.message}");

                if (mounted) {
                  // 실패 스낵바도 부모 context 사용
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(errorMessage),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              } catch (e) {
                print("알 수 없는 에러: $e");
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('❌ 오류가 발생했습니다.')),
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
    final cardColor = isDark ? AppColors.darkSurface : Colors.grey[100];
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final hintColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;

    // ✅ [작업2] 부드러운 테마 전환을 위한 AnimatedContainer 래핑
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      color: backgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              // ✅ [작업2] 오른쪽 상단 테마 전환 버튼 추가
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) => RotationTransition(
                      turns: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Icon(
                      isDark ? Icons.dark_mode : Icons.light_mode,
                      key: ValueKey<bool>(isDark),
                      color: textColor,
                    ),
                  ),
                  onPressed: () => toggleTheme(),
                  tooltip: isDark ? '라이트 모드로 전환' : '다크 모드로 전환',
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Column(
                    children: [
                      const SizedBox(height: 40),
                      Image.asset(
                        'assets/icon/icon.png',
                        width: 100,
                        height: 100,
                        errorBuilder: (c, e, s) => const Icon(
                          Icons.favorite,
                          size: 80,
                          color: Color(0xFF81C784),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '하루 매듭',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF81C784),
                        ),
                      ),
                      const SizedBox(height: 40),

                      // ID/PW 입력창 - AnimatedContainer로 부드러운 전환
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: _idController,
                          style: TextStyle(color: textColor),
                          decoration: InputDecoration(
                            hintText: '아이디 (이메일)',
                            hintStyle: TextStyle(color: hintColor),
                            filled: true,
                            fillColor: Colors.transparent,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: _pwController,
                          obscureText: _isObscure,
                          style: TextStyle(color: textColor),
                          decoration: InputDecoration(
                            hintText: '비밀번호',
                            hintStyle: TextStyle(color: hintColor),
                            filled: true,
                            fillColor: Colors.transparent,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _isObscure
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: hintColor,
                              ),
                              onPressed: () =>
                                  setState(() => _isObscure = !_isObscure),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 자동 로그인 & 비밀번호 찾기
                      Row(
                        children: [
                          Checkbox(
                            value: _isAutoLogin,
                            activeColor: const Color(0xFF81C784),
                            onChanged: (v) => setState(() => _isAutoLogin = v!),
                          ),
                          Text('자동 로그인', style: TextStyle(color: textColor)),
                          const Spacer(),
                          TextButton(
                            onPressed: _showFindPasswordDialog,
                            child: Text(
                              '비밀번호 찾기',
                              style: TextStyle(
                                color: hintColor,
                                fontSize: 13,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 로그인 버튼
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _handleGeneralLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF81C784),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '로그인',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),

                      // 구글 로그인 버튼 - AnimatedContainer로 부드러운 전환
                      GestureDetector(
                        onTap: _isLoading ? null : _handleGoogleLogin,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppColors.darkSurface
                                : Colors.white,
                            border: Border.all(
                              color: isDark
                                  ? AppColors.darkDivider
                                  : Colors.grey.shade300,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.asset(
                                'assets/images/google_logo.png',
                                width: 24,
                                errorBuilder: (c, e, s) =>
                                    Icon(Icons.login, color: textColor),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '구글로 시작하기',
                                style: TextStyle(color: textColor),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 40),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '아직 계정이 없으신가요? ',
                            style: TextStyle(color: textColor),
                          ),
                          TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const TermsAgreementPage(),
                              ),
                            ),
                            child: const Text(
                              '회원가입',
                              style: TextStyle(color: Color(0xFF81C784)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ), // Center 위젯 닫기
              // ✅ [작업2] 로딩 오버레이 (Stack 내부로 이동)
              if (_isLoading)
                Container(
                  color: Colors.black26,
                  child: const Center(
                    child: CircularProgressIndicator(color: Color(0xFF81C784)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
