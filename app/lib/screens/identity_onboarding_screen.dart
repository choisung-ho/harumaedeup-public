// lib/screens/identity_onboarding_screen.dart

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart' as record_pkg;

import '../services/identity_service.dart';
import 'home_page.dart';

class IdentityOnboardingScreen extends StatefulWidget {
  const IdentityOnboardingScreen({super.key});

  @override
  State<IdentityOnboardingScreen> createState() =>
      _IdentityOnboardingScreenState();
}

class _IdentityOnboardingScreenState extends State<IdentityOnboardingScreen> {
  // --- 음성 관련 변수 ---
  final record_pkg.AudioRecorder _recorder = record_pkg.AudioRecorder();
  String? _audioPath;
  bool _isUploadingAudio = false;
  bool _isRecordingPhrase = false;
  double _micProgress = 0;
  Timer? _micTimer;
  static const Duration _micTotal = Duration(seconds: 10);

  // --- 카메라 관련 변수 ---
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraLoading = false;
  final List<XFile> _captures = [];
  final ImagePicker _imagePicker = ImagePicker();
  bool _uploading = false;

  // --- 상태 관리 ---
  int _step = 0;
  final User? _currentUser = FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    if (_currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pop(context);
      });
    }
  }

  @override
  void dispose() {
    _micTimer?.cancel();
    _cameraController?.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _goNextStep() {
    setState(() {
      _step++;
    });
    if (_step == 2) {
      _ensureCameraReady();
    }
  }

  // ------- [2단계: 음성 녹음 로직] -------
  Future<void> _requestMicAndStart() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) return;

    final hasPermission = await _recorder.hasPermission();
    if (hasPermission) {
      Directory tempDir = await getTemporaryDirectory();

      // ✅ [수정] 확장자 .m4a 사용
      String filePath =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        // ✅ [수정] 인코더를 m4a로 설정 (중요)
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

  Future<void> _uploadAudioToServer() async {
    if (_audioPath == null || _currentUser == null) return;
    setState(() => _isUploadingAudio = true);

    try {
      final file = File(_audioPath!);
      // Service에서 경로 가져오기 (.m4a)
      final ref = IdentityService.getVoiceStorageRef(_currentUser!.uid);

      // ✅ [수정] 메타데이터 contentType을 audio/m4a로 지정
      final metadata = SettableMetadata(
        contentType: 'audio/m4a',
        customMetadata: {'owner_id': _currentUser!.uid},
      );

      await ref.putFile(file, metadata);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('목소리가 저장되었습니다.')));
        _goNextStep();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('업로드 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploadingAudio = false);
    }
  }

  // ------- [3단계: 카메라 촬영 로직] -------
  Future<void> _ensureCameraReady() async {
    if (_cameraController != null && _cameraController!.value.isInitialized)
      return;
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
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;
    try {
      final shot = await _cameraController!.takePicture();
      setState(() => _captures.add(shot));
    } catch (e) {
      debugPrint("촬영 실패: $e");
    }
  }

  Future<void> _finishRegistration() async {
    if (_captures.isEmpty || _currentUser == null) return;
    setState(() => _uploading = true);

    final result = await IdentityService.uploadFacePhotos(
      uid: _currentUser!.uid,
      photos: _captures,
      onProgress: (current, total, progress) {
        debugPrint('업로드 중: $current/$total');
      },
    );

    if (result['success'] == true) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const DiaryHomePage()),
        (route) => false,
      );
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result['error'] ?? '오류 발생')));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('본인 확인 등록')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _buildStepContent(),
        ),
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case 0:
        return _buildIntro();
      case 1:
        return _buildMic();
      case 2:
        return _buildCamera();
      default:
        return Container();
    }
  }

  Widget _buildIntro() {
    return Column(
      key: const ValueKey('Intro'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.face_retouching_natural,
          size: 100,
          color: Colors.blueAccent,
        ),
        const SizedBox(height: 30),
        const Text(
          '본인 확인 준비',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        const Text(
          '시작 전에 간단한 음성 녹음과\n얼굴 촬영으로 사용자를 확인합니다.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
        const SizedBox(height: 50),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _goNextStep,
            child: const Text('시작하기', style: TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );
  }

  Widget _buildMic() {
    return Column(
      key: const ValueKey('Mic'),
      children: [
        const SizedBox(height: 40),
        const Text(
          '목소리 등록',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text('아래 문장을 10초간 읽어주세요.', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 30),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            '"오늘도 좋은 하루 되세요"',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        const Spacer(),
        if (_isRecordingPhrase)
          LinearProgressIndicator(value: _micProgress, minHeight: 10),
        const SizedBox(height: 20),
        if (_audioPath == null && !_isRecordingPhrase)
          ElevatedButton.icon(
            onPressed: _requestMicAndStart,
            icon: const Icon(Icons.mic),
            label: const Text('녹음 시작'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          )
        else if (_audioPath != null)
          ElevatedButton.icon(
            onPressed: _isUploadingAudio ? null : _uploadAudioToServer,
            icon: _isUploadingAudio
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.cloud_upload),
            label: const Text('저장하고 다음으로'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.green,
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildCamera() {
    return Column(
      key: const ValueKey('Camera'),
      children: [
        const Text(
          '얼굴 등록',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const Text('정면과 측면 등 사진을 3장 이상 찍어주세요.'),
        const SizedBox(height: 20),
        Expanded(
          child: Container(
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
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${_captures.length}장 촬영됨',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (_captures.length < 3)
              const Text(' (3장 이상 필요)', style: TextStyle(color: Colors.red)),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _capture,
                icon: const Icon(Icons.camera_alt),
                label: const Text('촬영'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: (_captures.length >= 3 && !_uploading)
                    ? _finishRegistration
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _uploading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                    : const Text(
                        '등록 완료',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
